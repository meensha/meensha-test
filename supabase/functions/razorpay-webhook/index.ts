// Receives Razorpay's `payment_link.paid` webhook. Verifies the signature,
// marks the matching `orders` row paid, converts the reserved inventory units
// to sold, and inserts a matching `sales` row so the order flows into the
// existing Sales Register / Daily Payment Summary / P&L exactly like a
// manually-recorded sale.
//
// Required secret: RAZORPAY_WEBHOOK_SECRET (from the webhook's setup page in
// the Razorpay Dashboard — different from the API key secret).
// Configure this function's URL as the webhook endpoint in Razorpay, event:
// payment_link.paid

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const rawBody = await req.text();
  const signature = req.headers.get("x-razorpay-signature") || "";
  const webhookSecret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET")!;

  const valid = await verifySignature(rawBody, signature, webhookSecret);
  if (!valid) {
    return new Response("Invalid signature", { status: 401 });
  }

  const payload = JSON.parse(rawBody);
  if (payload.event !== "payment_link.paid") {
    // Acknowledge other events without acting on them.
    return new Response("ok", { status: 200 });
  }

  const linkEntity = payload.payload?.payment_link?.entity;
  const paymentEntity = payload.payload?.payment?.entity;
  const referenceId = linkEntity?.reference_id;
  if (!referenceId) {
    return new Response("Missing reference_id", { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: order, error: orderErr } = await supabase
    .from("orders")
    .select("*")
    .eq("id", referenceId)
    .single();
  if (orderErr || !order) {
    return new Response("Order not found", { status: 404 });
  }
  if (order.status === "paid") {
    // Already processed (Razorpay may retry webhooks) — idempotent no-op.
    return new Response("ok", { status: 200 });
  }

  await supabase
    .from("orders")
    .update({ status: "paid", updated_at: new Date().toISOString() })
    .eq("id", referenceId);

  // Next invoice number, same counter admin.html's saveSale() uses.
  const { data: ctrRows } = await supabase
    .from("settings")
    .select("value")
    .eq("key", "inv_counter")
    .single();
  const nextCtr = (parseInt(ctrRows?.value || "1000") || 1000) + 1;
  await supabase
    .from("settings")
    .update({ value: String(nextCtr) })
    .eq("key", "inv_counter");
  const inv = "MSH-" + nextCtr;

  const razorpayFee = Math.round(order.total * 0.02);
  const { data: saleRows, error: saleErr } = await supabase
    .from("sales")
    .insert({
      inv,
      date: new Date().toISOString().slice(0, 10),
      customer: order.customer,
      items: order.items,
      total: order.total,
      paid: order.total,
      balance: 0,
      pay_mode: "Razorpay",
      razorpay_fee: razorpayFee,
      notes: "Online order via storefront cart",
      delivery_mode: "offline",
      shipping_status: "na",
      created_by: "storefront",
      source: "storefront",
    })
    .select()
    .single();

  if (!saleErr && saleRows) {
    for (const unitId of order.unit_ids || []) {
      await supabase.rpc("claim_unit", {
        p_unit_id: unitId,
        p_sale_id: saleRows.id,
      });
    }
  }

  if (order.coupon?.code && order.coupon?.wa) {
    await supabase.rpc("consume_coupon", {
      p_code: order.coupon.code,
      p_wa: order.coupon.wa,
    });
  }

  return new Response("ok", { status: 200 });
});

async function verifySignature(
  body: string,
  signature: string,
  secret: string,
): Promise<boolean> {
  if (!signature || !secret) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuf = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(body),
  );
  const expected = Array.from(new Uint8Array(sigBuf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  // Constant-time-ish comparison
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return diff === 0;
}
