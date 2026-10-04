// Creates a Razorpay Payment Link for the exact cart total and records a
// pending `orders` row. Called from the storefront cart (index.html) when the
// customer clicks "Pay via Razorpay". Holds the Razorpay secret key
// server-side — never expose it to the browser.
//
// Required secrets (set via `supabase secrets set` or the Dashboard):
//   RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  try {
    const { items, customer, unit_ids, currency, coupon, source, telegram_chat_id } = await req.json();

    if (!Array.isArray(unit_ids) || !unit_ids.length) {
      return json({ error: "Cart is empty" }, 400);
    }
    if (!customer?.name || !customer?.wa) {
      return json({ error: "Name and WhatsApp number are required" }, 400);
    }
    if (currency && currency !== "INR") {
      return json({ error: "Razorpay checkout is India-only" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Defensive re-check: every unit must still be available or already
    // reserved (by this same customer's earlier Add to Cart) — never sold.
    // Also pulls each unit's real sku_id so the price can be recomputed
    // server-side below — the client-submitted `total` is never trusted
    // (a customer could edit it in devtools before this call; stock was
    // already re-checked here but price wasn't, until this fix).
    const { data: units, error: unitsErr } = await supabase
      .from("inventory_units")
      .select("id,status,sku_id")
      .in("id", unit_ids);
    if (unitsErr) return json({ error: "Could not verify stock" }, 500);
    const unavailable = (units || []).filter(
      (u: { id: string; status: string }) => u.status === "sold",
    );
    if (unavailable.length) {
      return json(
        { error: "One or more items were just sold — please refresh your cart." },
        409,
      );
    }

    const skuIds = [...new Set((units || []).map((u: { sku_id: string }) => u.sku_id))];
    const { data: skus, error: skusErr } = await supabase
      .from("inventory_skus")
      .select("id,name,sale_price")
      .in("id", skuIds);
    if (skusErr) return json({ error: "Could not verify prices" }, 500);
    const skuById = new Map((skus || []).map((s: { id: string; name: string; sale_price: number }) => [s.id, s]));

    // Server-truth cart: one line per unit, price from inventory_skus, never
    // from the client. `items` (client-sent) is used only for the Razorpay
    // description text below — cosmetic, not security-relevant.
    const serverItems = (units || []).map((u: { id: string; sku_id: string }) => {
      const sku = skuById.get(u.sku_id) as { name: string; sale_price: number } | undefined;
      return { unit_id: u.id, name: sku?.name || "", price: sku?.sale_price || 0 };
    });
    const subtotal = serverItems.reduce((a, it) => a + it.price, 0);

    // Re-validate the coupon server-side (same RPC the storefront itself
    // calls) rather than trusting a client-reported discount_type/value —
    // mirrors couponDiscountBase() in index.html exactly.
    let discount = 0;
    if (coupon?.code) {
      const { data: cRes } = await supabase.rpc("validate_coupon", {
        p_code: coupon.code,
        p_wa: coupon.wa || null,
        p_region: "india",
      });
      if (cRes?.valid) {
        const filter = cRes.category_filter as string | null;
        const discountBase = filter
          ? serverItems.filter((it) => it.name.toLowerCase().includes(filter.toLowerCase())).reduce((a, it) => a + it.price, 0)
          : subtotal;
        discount = cRes.discount_type === "percent"
          ? discountBase * (Number(cRes.discount_value) / 100)
          : Number(cRes.discount_value);
        discount = Math.min(discount, discountBase);
      }
    }

    const total = Math.round((subtotal - discount) * 100) / 100;
    if (!total || total <= 0) {
      return json({ error: "Invalid total" }, 400);
    }

    const orderId = crypto.randomUUID();
    const keyId = Deno.env.get("RAZORPAY_KEY_ID")!;
    const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET")!;
    const auth = "Basic " + btoa(`${keyId}:${keySecret}`);

    const waDigits = String(customer.wa).replace(/\D/g, "");
    const description = (items || [])
      .map((it: { name: string }) => it.name)
      .join(", ")
      .slice(0, 250) || "Meensha order";

    const rzpRes = await fetch("https://api.razorpay.com/v1/payment_links", {
      method: "POST",
      headers: { Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({
        amount: Math.round(total * 100), // paise
        currency: "INR",
        description,
        reference_id: orderId,
        customer: {
          name: customer.name,
          contact: waDigits,
        },
        notify: { sms: false, email: false },
        notes: { unit_ids: unit_ids.join(",") },
      }),
    });
    const rzpData = await rzpRes.json();
    if (!rzpRes.ok) {
      return json(
        { error: rzpData?.error?.description || "Razorpay error" },
        502,
      );
    }

    const { error: insErr } = await supabase.from("orders").insert({
      id: orderId,
      customer,
      items,
      total,
      currency: "INR",
      unit_ids,
      razorpay_payment_link_id: rzpData.id,
      razorpay_short_url: rzpData.short_url,
      status: "created",
      coupon: coupon || null,
      source: source || "storefront",
      telegram_chat_id: telegram_chat_id || null,
    });
    if (insErr) return json({ error: "Could not save order" }, 500);

    return json({ short_url: rzpData.short_url, order_id: orderId });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}
