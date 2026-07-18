// Telegram bot for Shalini — stage 2 (Kiosk mode / record a sale).
// See TELEGRAM_BOT_BUILD_PLAN.md for the full state machine spec.
// Enter inventory + Godown check are stages 3-4, not built yet — their
// buttons currently just reply "coming soon".
//
// Required secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN")!;
const TG_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

// deno-lint-ignore no-explicit-any
type SB = any;
// deno-lint-ignore no-explicit-any
type SessionData = Record<string, any>;

// Attached to every checkout-sequence prompt from "customer name" through
// "amount received" — lets Shalini go back to add more items without
// losing the cart or having to cancel and restart.
const BACK_ROW = [{ text: "◀ Add more items", callback_data: "kiosk:backtoitems" }];
// Attached everywhere in Kiosk mode — bails out of the whole sale from any
// point, no confirmation needed for this one since nothing's been saved to
// the database yet at any step before the final "Confirm" tap.
const CANCEL_ROW = [{ text: "✕ Cancel sale", callback_data: "kiosk:cancelall" }];
// Godown check has nothing pending to lose (every reconciliation step is
// read-only until a discrepancy note is actually submitted), so "cancel"
// here just means "exit back to the top menu."
const GODOWN_EXIT_ROW = [{ text: "✕ Exit", callback_data: "godown:exit" }];

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const secret = req.headers.get("X-Telegram-Bot-Api-Secret-Token");
  if (secret !== Deno.env.get("TELEGRAM_WEBHOOK_SECRET")) {
    return new Response("Forbidden", { status: 403 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const update = await req.json();
  const msg = update.message ?? update.callback_query?.message;
  const chatId = msg?.chat?.id;
  if (!chatId) {
    return new Response("ok", { status: 200 });
  }

  // service_role bypasses RLS, so this direct table read is fine here even
  // though telegram_allowed_users has no anon/authenticated policies —
  // admin.html (anon key) manages this table only through RPCs instead.
  const { data: allowedRows } = await supabase
    .from("telegram_allowed_users")
    .select("chat_id")
    .eq("active", true);
  const allowlist = (allowedRows ?? []).map((r: { chat_id: string }) => r.chat_id);

  if (!allowlist.length) {
    await tgSend(chatId, `Not authorized yet. Ask Rachnakar to approve chat_id: ${chatId}`);
    return new Response("ok", { status: 200 });
  }
  if (!allowlist.includes(String(chatId))) {
    return new Response("ok", { status: 200 });
  }

  const { data: session } = await supabase
    .from("telegram_sessions")
    .select("*")
    .eq("chat_id", chatId)
    .single();
  const state: string = session?.state ?? "idle";
  const data: SessionData = session?.data ?? {};

  const text: string | undefined = update.message?.text;
  const callbackData: string | undefined = update.callback_query?.data;
  const photo: { file_id: string }[] | undefined = update.message?.photo;

  if (text === "/start") {
    await showTopMenu(chatId);
    await saveSession(supabase, chatId, "idle", {});
  } else if (callbackData?.startsWith("kiosk:")) {
    await handleKiosk(supabase, chatId, state, data, callbackData);
  } else if (callbackData?.startsWith("inv:")) {
    await tgSend(chatId, "Enter inventory mode isn't built yet — coming soon.");
  } else if (callbackData?.startsWith("godown:")) {
    await handleGodown(supabase, chatId, state, data, callbackData);
  } else if (photo?.length && state === "godown_discrepancy_note") {
    await handleGodownPhoto(supabase, chatId, data, photo);
  } else if (text && state.startsWith("godown_")) {
    await handleGodownText(supabase, chatId, state, data, text);
  } else if (text) {
    await handleTextInput(supabase, chatId, state, data, text);
  }

  if (update.callback_query) {
    await fetch(`${TG_API}/answerCallbackQuery`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ callback_query_id: update.callback_query.id }),
    });
  }

  return new Response("ok", { status: 200 });
});

// ═══════════════════════════════════════════════
// TELEGRAM HELPERS
// ═══════════════════════════════════════════════
async function tgSend(chatId: number, text: string, replyMarkup?: unknown) {
  await fetch(`${TG_API}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, reply_markup: replyMarkup }),
  });
}

async function saveSession(supabase: SB, chatId: number, state: string, data: SessionData) {
  await supabase.from("telegram_sessions").upsert({
    chat_id: chatId,
    state,
    data,
    updated_at: new Date().toISOString(),
  });
}

async function showTopMenu(chatId: number) {
  await tgSend(chatId, "What would you like to do?", {
    inline_keyboard: [
      [{ text: "🛍️ Kiosk mode", callback_data: "kiosk:start" }],
      [{ text: "➕ Enter inventory", callback_data: "inv:start" }],
      [{ text: "📦 Godown check", callback_data: "godown:start" }],
    ],
  });
}

// ═══════════════════════════════════════════════
// KIOSK MODE (record a sale) — mirrors admin.html's saveSale()
// ═══════════════════════════════════════════════
async function handleKiosk(
  supabase: SB,
  chatId: number,
  state: string,
  data: SessionData,
  callbackData: string,
) {
  if (callbackData === "kiosk:start") {
    data = { cart: [], page: 0 };
    await showItemPicker(supabase, chatId, data);
    await saveSession(supabase, chatId, "kiosk_pick_item", data);
    return;
  }

  // Available from any point in checkout up through the amount step —
  // keeps the cart and anything already entered, just goes back to add
  // more items. Re-reaching checkout afterward simply re-asks customer
  // info/discount/payment fresh (cheap to re-enter, far simpler and safer
  // than trying to selectively skip already-filled fields).
  if (callbackData === "kiosk:backtoitems") {
    data.page = 0;
    await showItemPicker(supabase, chatId, data);
    await saveSession(supabase, chatId, "kiosk_pick_item", data);
    return;
  }

  if (callbackData === "kiosk:cancelall") {
    await tgSend(chatId, "Sale cancelled — nothing was saved.");
    await showTopMenu(chatId);
    await saveSession(supabase, chatId, "idle", {});
    return;
  }

  if (state === "kiosk_pick_item") {
    if (callbackData.startsWith("kiosk:page:")) {
      data.page = parseInt(callbackData.split(":")[2]);
      await showItemPicker(supabase, chatId, data);
      await saveSession(supabase, chatId, "kiosk_pick_item", data);
      return;
    }
    if (callbackData.startsWith("kiosk:item:")) {
      const skuId = callbackData.split(":")[2];
      await showUnitPicker(supabase, chatId, skuId, data);
      await saveSession(supabase, chatId, "kiosk_pick_unit", data);
      return;
    }
  }

  if (state === "kiosk_pick_unit" && callbackData.startsWith("kiosk:unit:")) {
    const unitId = callbackData.split(":")[2];
    const { data: unit } = await supabase
      .from("inventory_units")
      .select("unit_code, sku_id, inventory_skus(name, sale_price, display_variant)")
      .eq("id", unitId)
      .single();
    if (!unit) {
      await tgSend(chatId, "That piece is no longer available — pick another.");
      await showItemPicker(supabase, chatId, data);
      await saveSession(supabase, chatId, "kiosk_pick_item", data);
      return;
    }
    const sku = unit.inventory_skus;
    data.cart.push({
      unit_id: unitId,
      unit_code: unit.unit_code,
      sku_id: unit.sku_id,
      name: sku.name,
      variant: sku.display_variant,
      price: sku.sale_price,
    });
    const cartLines = data.cart
      .map((c: { name: string; price: number }) => `• ${c.name} — ₹${c.price}`)
      .join("\n");
    const cartTotal = data.cart.reduce((a: number, c: { price: number }) => a + c.price, 0);
    await tgSend(chatId, `Cart so far:\n\n${cartLines}\n\nSubtotal: ₹${cartTotal}`, {
      inline_keyboard: [
        [{ text: "➕ Add another item", callback_data: "kiosk:more" }],
        [{ text: "✅ Done, checkout", callback_data: "kiosk:checkout" }],
        CANCEL_ROW,
      ],
    });
    await saveSession(supabase, chatId, "kiosk_cart_review", data);
    return;
  }

  if (state === "kiosk_cart_review") {
    if (callbackData === "kiosk:more") {
      data.page = 0;
      await showItemPicker(supabase, chatId, data);
      await saveSession(supabase, chatId, "kiosk_pick_item", data);
      return;
    }
    if (callbackData === "kiosk:checkout") {
      await tgSend(chatId, "Customer name?", { inline_keyboard: [BACK_ROW, CANCEL_ROW] });
      await saveSession(supabase, chatId, "kiosk_customer_name", data);
      return;
    }
  }

  if (state === "kiosk_discount_pick") {
    if (callbackData === "kiosk:discount:none") {
      data.discount = 0;
      await askPaymentMode(supabase, chatId, data);
      return;
    }
    if (callbackData === "kiosk:discount:custom") {
      const subtotal = data.cart.reduce((a: number, c: { price: number }) => a + c.price, 0);
      await tgSend(chatId, `Reply with a ₹ discount amount, or 0 if none. (Subtotal: ₹${subtotal})`, { inline_keyboard: [BACK_ROW, CANCEL_ROW] });
      await saveSession(supabase, chatId, "kiosk_discount_custom", data);
      return;
    }
    if (callbackData === "kiosk:discount:entercode") {
      await tgSend(chatId, "Type the customer's code (e.g. MSH-A3F92):", { inline_keyboard: [BACK_ROW, CANCEL_ROW] });
      await saveSession(supabase, chatId, "kiosk_discount_code_entry", data);
      return;
    }
    if (callbackData.startsWith("kiosk:coupon:")) {
      const couponId = callbackData.split(":")[2];
      const { data: coupon } = await supabase
        .from("coupons")
        .select("*")
        .eq("id", couponId)
        .single();
      if (!validateCoupon(coupon)) {
        await tgSend(chatId, "That coupon isn't available anymore — pick another option.");
        await showDiscountPicker(supabase, chatId, data);
        return;
      }
      await pickDiscountItem(supabase, chatId, data, coupon);
      return;
    }
  }

  if (state === "kiosk_payment_mode" && callbackData.startsWith("kiosk:pay:")) {
    const modeMap: Record<string, string> = { cash: "Cash", upi: "UPI Direct", razorpay: "Razorpay" };
    data.pay_mode = modeMap[callbackData.split(":")[2]];
    const total = orderTotal(data);
    await tgSend(chatId, `Amount received — ₹${total}?`, {
      inline_keyboard: [
        [{ text: `✅ Yes, ₹${total} in full`, callback_data: "kiosk:amount:full" }],
        BACK_ROW,
        CANCEL_ROW,
      ],
    });
    await tgSend(chatId, "Or reply with the actual amount if different.");
    await saveSession(supabase, chatId, "kiosk_amount", data);
    return;
  }

  if (state === "kiosk_amount" && callbackData === "kiosk:amount:full") {
    data.amount = orderTotal(data);
    await showConfirmation(supabase, chatId, data);
    return;
  }

  if (state === "kiosk_confirm") {
    if (callbackData === "kiosk:confirm") {
      await finalizeSale(supabase, chatId, data);
      await saveSession(supabase, chatId, "idle", {});
      return;
    }
    if (callbackData === "kiosk:cancel") {
      await tgSend(chatId, "Sale cancelled.");
      await showTopMenu(chatId);
      await saveSession(supabase, chatId, "idle", {});
      return;
    }
  }
}

async function showItemPicker(supabase: SB, chatId: number, data: SessionData) {
  const { data: skus } = await supabase
    .from("inventory_skus")
    .select("id, name, mrp, sale_price, display_variant, au_available");
  const { data: units } = await supabase
    .from("inventory_units")
    .select("id, sku_id")
    .eq("status", "available");

  // Units already sitting in the cart aren't actually sold yet (DB status
  // only flips on finalize), but they must not be offered again — otherwise
  // the same physical piece could be picked twice into one sale.
  const inCartUnitIds = new Set((data.cart ?? []).map((c: { unit_id: string }) => c.unit_id));

  const availCount: Record<string, number> = {};
  (units ?? []).forEach((u: { sku_id: string; id: string }) => {
    if (inCartUnitIds.has(u.id)) return;
    availCount[u.sku_id] = (availCount[u.sku_id] ?? 0) + 1;
  });
  const inStock = (skus ?? []).filter((s: { id: string }) => (availCount[s.id] ?? 0) > 0);

  const pageSize = 8;
  const page = data.page ?? 0;
  const pageItems = inStock.slice(page * pageSize, (page + 1) * pageSize);

  const buttons = pageItems.map(
    (s: { id: string; name: string; mrp: number; sale_price: number; au_available: boolean }) => {
      const auTag = s.au_available ? "🇦🇺 " : "";
      const mrpTxt = s.mrp && s.mrp !== s.sale_price ? `MRP ₹${s.mrp} → ` : "";
      return [{
        text: `${auTag}${s.name} (${availCount[s.id]} left) — ${mrpTxt}₹${s.sale_price}`,
        callback_data: `kiosk:item:${s.id}`,
      }];
    },
  );
  const navRow = [];
  if (page > 0) navRow.push({ text: "◀ Prev", callback_data: `kiosk:page:${page - 1}` });
  if ((page + 1) * pageSize < inStock.length) {
    navRow.push({ text: "Next ▶", callback_data: `kiosk:page:${page + 1}` });
  }
  if (navRow.length) buttons.push(navRow);
  buttons.push(CANCEL_ROW);

  let header = inStock.length ? "Pick an item:" : "Nothing in stock right now.";
  if (data.cart?.length) {
    const cartLines = data.cart
      .map((c: { name: string; price: number }) => `• ${c.name} — ₹${c.price}`)
      .join("\n");
    header = `In cart so far:\n${cartLines}\n\n${header}`;
  }

  await tgSend(chatId, header, { inline_keyboard: buttons });
}

async function showUnitPicker(supabase: SB, chatId: number, skuId: string, data: SessionData) {
  const { data: units } = await supabase
    .from("inventory_units")
    .select("id, unit_code")
    .eq("sku_id", skuId)
    .eq("status", "available");
  const inCartUnitIds = new Set((data.cart ?? []).map((c: { unit_id: string }) => c.unit_id));
  const buttons = (units ?? [])
    .filter((u: { id: string }) => !inCartUnitIds.has(u.id))
    .map((u: { id: string; unit_code: string }) => [
      { text: u.unit_code, callback_data: `kiosk:unit:${u.id}` },
    ]);
  buttons.push(BACK_ROW);
  buttons.push(CANCEL_ROW);
  await tgSend(chatId, "Pick the specific piece:", { inline_keyboard: buttons });
}

async function handleTextInput(
  supabase: SB,
  chatId: number,
  state: string,
  data: SessionData,
  text: string,
) {
  if (state === "kiosk_customer_name") {
    data.customer_name = text.trim();
    await tgSend(chatId, "WhatsApp number?", { inline_keyboard: [BACK_ROW, CANCEL_ROW] });
    await saveSession(supabase, chatId, "kiosk_customer_wa", data);
    return;
  }

  if (state === "kiosk_customer_wa") {
    data.customer_wa = text.trim();
    await showDiscountPicker(supabase, chatId, data);
    return;
  }

  if (state === "kiosk_discount_custom") {
    const subtotal = data.cart.reduce((a: number, c: { price: number }) => a + c.price, 0);
    const parsed = parseFloat(text);
    data.discount = isNaN(parsed) ? 0 : Math.max(0, Math.min(parsed, subtotal));
    await askPaymentMode(supabase, chatId, data);
    return;
  }

  if (state === "kiosk_discount_code_entry") {
    const code = text.trim().toUpperCase();
    const { data: coupon } = await supabase
      .from("coupons")
      .select("*")
      .ilike("code", code)
      .maybeSingle();
    if (!validateCoupon(coupon)) {
      await tgSend(chatId, "Code not found, already used, expired, or not active.");
      await showDiscountPicker(supabase, chatId, data);
      return;
    }
    await pickDiscountItem(supabase, chatId, data, coupon);
    return;
  }

  if (state === "kiosk_amount") {
    const total = orderTotal(data);
    const parsed = parseFloat(text);
    data.amount = isNaN(parsed) ? total : parsed;
    await showConfirmation(supabase, chatId, data);
    return;
  }

  // No active flow expecting text input — just show the menu.
  await showTopMenu(chatId);
}

// A coupon discount applies to exactly one item in the cart, not the whole
// order — matches how the discount is meant to be understood on the invoice
// (e.g. "5% off one item"), not a blanket order-wide reduction.
// deno-lint-ignore no-explicit-any
function validateCoupon(coupon: any): boolean {
  if (!coupon || !coupon.active || coupon.used) return false;
  if (!["india", "all"].includes(coupon.region)) return false;
  const today = new Date().toISOString().slice(0, 10);
  if (coupon.valid_from && coupon.valid_from > today) return false;
  if (coupon.valid_until && coupon.valid_until < today) return false;
  return true;
}

// Auto-applies to the highest-priced item in the cart — no extra question.
// A percent-off coupon gives the biggest rupee value against the pricier
// item, and this removes an interactive step (and a bug surface) entirely.
// deno-lint-ignore no-explicit-any
async function pickDiscountItem(supabase: SB, chatId: number, data: SessionData, coupon: any) {
  const target = data.cart.reduce(
    (max: { price: number }, c: { price: number }) => (c.price > max.price ? c : max),
    data.cart[0],
  );
  applyCouponToItem(data, coupon, target);
  await tgSend(chatId, `🎟️ Applied ${coupon.code} to ${target.name} — -₹${data.discount}`);
  await askPaymentMode(supabase, chatId, data);
}

// deno-lint-ignore no-explicit-any
function applyCouponToItem(data: SessionData, coupon: any, item: { price: number; unit_id: string }) {
  const discount = coupon.discount_type === "percent"
    ? Math.round(item.price * (coupon.discount_value / 100))
    : coupon.discount_value;
  data.discount = Math.max(0, Math.min(discount, item.price));
  data.discountUnitId = item.unit_id;
  data.appliedCoupon = { code: coupon.code, wa: coupon.customer_wa };
}

function orderTotal(data: SessionData): number {
  const subtotal = data.cart.reduce((a: number, c: { price: number }) => a + c.price, 0);
  return Math.max(0, subtotal - (data.discount ?? 0));
}

// Telegram inline-keyboard buttons have no color/styling options at all —
// this is a hard platform limit, not something codeable around. Coupon
// options are visually set apart with a 🎟️ prefix instead.
//
// The button list only shows generic, admin-created coupons (seasonal
// offers etc.) — individual codes like stall-registration coupons can
// number in the dozens/hundreds and would make the list unusable, so
// those go through "Enter a code" instead, where the customer reads out
// their specific code and Shalini types it in directly.
async function showDiscountPicker(supabase: SB, chatId: number, data: SessionData) {
  const today = new Date().toISOString().slice(0, 10);
  const { data: coupons } = await supabase
    .from("coupons")
    .select("id, code, discount_type, discount_value, region, valid_from, valid_until")
    .eq("active", true)
    .eq("used", false)
    .eq("source", "admin")
    .in("region", ["india", "all"]);

  const validCoupons = (coupons ?? []).filter(
    (c: { valid_from: string | null; valid_until: string | null }) =>
      (!c.valid_from || c.valid_from <= today) && (!c.valid_until || c.valid_until >= today),
  );

  const buttons = validCoupons.map(
    (c: { id: string; code: string; discount_type: string; discount_value: number }) => {
      const label = c.discount_type === "percent" ? `${c.discount_value}% off` : `₹${c.discount_value} off`;
      return [{ text: `🎟️ ${c.code} — ${label}`, callback_data: `kiosk:coupon:${c.id}` }];
    },
  );
  buttons.push([{ text: "🔑 Enter a code", callback_data: "kiosk:discount:entercode" }]);
  buttons.push([{ text: "✏️ Custom discount amount", callback_data: "kiosk:discount:custom" }]);
  buttons.push([{ text: "➡️ No discount", callback_data: "kiosk:discount:none" }]);
  buttons.push(BACK_ROW);
  buttons.push(CANCEL_ROW);

  await tgSend(chatId, "Any discount for this sale?", { inline_keyboard: buttons });
  await saveSession(supabase, chatId, "kiosk_discount_pick", data);
}

async function askPaymentMode(supabase: SB, chatId: number, data: SessionData) {
  await tgSend(chatId, "Payment mode?", {
    inline_keyboard: [
      [{ text: "💵 Cash", callback_data: "kiosk:pay:cash" }],
      [{ text: "📲 UPI Direct", callback_data: "kiosk:pay:upi" }],
      [{ text: "💳 Razorpay", callback_data: "kiosk:pay:razorpay" }],
      BACK_ROW,
      CANCEL_ROW,
    ],
  });
  await saveSession(supabase, chatId, "kiosk_payment_mode", data);
}

// Shows the discount inline against the specific item it applies to,
// rather than as a separate order-wide line — matches how the coupon is
// actually applied (one item, not the whole cart).
function formatCartLines(data: SessionData): string {
  return data.cart
    .map((c: { unit_id: string; name: string; variant?: string; unit_code: string; price: number }) => {
      const base = `• ${c.name}${c.variant ? " (" + c.variant + ")" : ""} — ₹${c.price}`;
      if (data.discountUnitId === c.unit_id && data.discount) {
        return `${base}\n   ↳ -₹${data.discount} (${data.appliedCoupon?.code ?? "coupon"})`;
      }
      return base;
    })
    .join("\n");
}

async function showConfirmation(supabase: SB, chatId: number, data: SessionData) {
  const subtotal = data.cart.reduce((a: number, c: { price: number }) => a + c.price, 0);
  const total = orderTotal(data);
  const lines = formatCartLines(data);
  await tgSend(
    chatId,
    `Confirm sale?\n\n${lines}\n\nCustomer: ${data.customer_name} (${data.customer_wa})\nPayment: ${data.pay_mode}\nSubtotal: ₹${subtotal}\nTotal: ₹${total}\nReceived: ₹${data.amount}`,
    {
      inline_keyboard: [
        [{ text: "✅ Confirm", callback_data: "kiosk:confirm" }],
        [{ text: "✕ Cancel", callback_data: "kiosk:cancel" }],
      ],
    },
  );
  await saveSession(supabase, chatId, "kiosk_confirm", data);
}

async function finalizeSale(supabase: SB, chatId: number, data: SessionData) {
  const total = orderTotal(data);
  const paid = data.amount ?? total;

  const { data: ctrRow } = await supabase
    .from("settings")
    .select("value")
    .eq("key", "inv_counter")
    .single();
  const nextCtr = (parseInt(ctrRow?.value ?? "1000") || 1000) + 1;
  await supabase.from("settings").update({ value: String(nextCtr) }).eq("key", "inv_counter");
  const inv = "MSH-" + nextCtr;

  const { data: saleRow } = await supabase
    .from("sales")
    .insert({
      inv,
      date: new Date().toISOString().slice(0, 10),
      customer: { name: data.customer_name, wa: data.customer_wa },
      items: data.cart.map((c: { unit_id: string; name: string; variant?: string; unit_code: string; price: number }) => ({
        name: c.name,
        variant: c.variant || "",
        sku_code: c.unit_code,
        price: c.price,
        discount: data.discountUnitId === c.unit_id ? data.discount : 0,
      })),
      total,
      paid,
      balance: total - paid,
      pay_mode: data.pay_mode,
      delivery_mode: "offline",
      shipping_status: "na",
      created_by: "telegram_bot",
      source: "telegram",
    })
    .select()
    .single();

  if (saleRow) {
    for (const item of data.cart) {
      await supabase.rpc("claim_unit", { p_unit_id: item.unit_id, p_sale_id: saleRow.id });
    }
  }

  if (data.appliedCoupon) {
    await supabase.rpc("consume_coupon", {
      p_code: data.appliedCoupon.code,
      p_wa: data.appliedCoupon.wa,
    });
  }

  const lines = formatCartLines(data);
  const waDigits = String(data.customer_wa ?? "").replace(/\D/g, "");
  const waMsg = encodeURIComponent(
    `Hi ${data.customer_name}! Your Meensha order:\n\n${lines}\n\nTotal: ₹${total}\nPaid: ₹${paid}\n\nInvoice: ${inv}`,
  );
  const waLink = waDigits ? `https://wa.me/${waDigits}?text=${waMsg}` : null;

  await tgSend(
    chatId,
    `✅ Sale recorded — ${inv}\n\n${lines}\n\nTotal: ₹${total}\nPaid: ₹${paid}\nBalance: ₹${total - paid}` +
      (waLink ? `\n\nTap to send invoice: ${waLink}` : ""),
  );
  await showTopMenu(chatId);
}

// ═══════════════════════════════════════════════
// GODOWN CHECK (stock audit) — EOD reconciliation + ad-hoc spot check.
// Both paths converge on the same match/discrepancy step, then log any
// discrepancy to vendor_issues (same table/fields admin.html's Vendor
// Issues tab uses) so it shows up there for follow-up. Scope note: the
// "offer to return a damaged piece to the seller" extension from the
// original plan needs the not-yet-built purchase_returns/returned_to_vendor
// schema (that's part of the still-unbuilt Enter Inventory stage) — this
// just logs the issue for now, same as manually logging one in admin.html.
// ═══════════════════════════════════════════════
type GodownItem = { sku_id: string; name: string; au: boolean; avail: number; soldToday?: number };

async function handleGodown(
  supabase: SB,
  chatId: number,
  state: string,
  data: SessionData,
  callbackData: string,
) {
  if (callbackData === "godown:exit") {
    await tgSend(chatId, "Exited godown check.");
    await showTopMenu(chatId);
    await saveSession(supabase, chatId, "idle", {});
    return;
  }

  if (callbackData === "godown:start") {
    data = {};
    await tgSend(chatId, "📦 Godown check — what do you want to do?", {
      inline_keyboard: [
        [{ text: "📊 End-of-day reconciliation", callback_data: "godown:eod" }],
        [{ text: "🔍 Spot check an item", callback_data: "godown:spot" }],
        GODOWN_EXIT_ROW,
      ],
    });
    await saveSession(supabase, chatId, "godown_menu", data);
    return;
  }

  if (callbackData === "godown:eod") {
    await startGodownEod(supabase, chatId, data);
    return;
  }

  if (callbackData === "godown:spot") {
    await tgSend(chatId, "Type an item name to search:", { inline_keyboard: [GODOWN_EXIT_ROW] });
    await saveSession(supabase, chatId, "godown_spot_search", data);
    return;
  }

  if (callbackData.startsWith("godown:spotpick:")) {
    const skuId = callbackData.split(":")[2];
    const { data: sku } = await supabase
      .from("inventory_skus")
      .select("id, name, au_available")
      .eq("id", skuId)
      .single();
    const { data: units } = await supabase
      .from("inventory_units")
      .select("id")
      .eq("sku_id", skuId)
      .eq("status", "available");
    data.spotItem = { sku_id: sku.id, name: sku.name, au: sku.au_available, avail: (units ?? []).length };
    await showGodownItem(supabase, chatId, data, data.spotItem);
    await saveSession(supabase, chatId, "godown_spot_item", data);
    return;
  }

  if ((state === "godown_eod_item" || state === "godown_spot_item") && callbackData === "godown:match") {
    await advanceGodown(supabase, chatId, state, data);
    return;
  }

  if ((state === "godown_eod_item" || state === "godown_spot_item") && callbackData === "godown:discrepancy") {
    data.discFromState = state;
    data.discItem = state === "godown_eod_item" ? data.eodList[data.eodIdx] : data.spotItem;
    await tgSend(chatId, "What kind of discrepancy?", {
      inline_keyboard: [
        [{ text: "📉 Missing", callback_data: "godown:disc:missing" }],
        [{ text: "🔨 Damaged", callback_data: "godown:disc:damage" }],
        [{ text: "📈 Extra", callback_data: "godown:disc:extra" }],
        GODOWN_EXIT_ROW,
      ],
    });
    await saveSession(supabase, chatId, "godown_discrepancy_type", data);
    return;
  }

  if (state === "godown_discrepancy_type" && callbackData.startsWith("godown:disc:")) {
    const typeMap: Record<string, string> = { missing: "shortage", damage: "damage", extra: "other" };
    data.discType = typeMap[callbackData.split(":")[2]] ?? "other";
    data.selectedUnitIds = [];
    // "Extra" means ground stock the system doesn't know about at all —
    // there's no existing unit record to tie it to, so skip straight to
    // the note. Missing/Damaged are both about a specific physical piece,
    // so offer to pick which one(s) first.
    if (data.discType === "other") {
      await promptGodownNote(chatId);
      await saveSession(supabase, chatId, "godown_discrepancy_note", data);
    } else {
      await showGodownUnitPicker(supabase, chatId, data);
    }
    return;
  }

  if (state === "godown_unit_pick" && callbackData.startsWith("godown:unitpick:")) {
    const val = callbackData.split(":")[2];
    if (val === "done") {
      await promptGodownNote(chatId);
      await saveSession(supabase, chatId, "godown_discrepancy_note", data);
      return;
    }
    const selected: string[] = data.selectedUnitIds ?? [];
    data.selectedUnitIds = selected.includes(val) ? selected.filter((x: string) => x !== val) : [...selected, val];
    await showGodownUnitPicker(supabase, chatId, data);
    return;
  }

  if (state === "godown_discrepancy_note" && (callbackData === "godown:disc:skip" || callbackData === "godown:disc:notedone")) {
    await finalizeGodownDiscrepancy(supabase, chatId, data, "");
    return;
  }
}

async function promptGodownNote(chatId: number) {
  await tgSend(chatId, "Add a note, attach a photo, or tap Skip:", {
    inline_keyboard: [[{ text: "⏭ Skip", callback_data: "godown:disc:skip" }], GODOWN_EXIT_ROW],
  });
}

async function showGodownUnitPicker(supabase: SB, chatId: number, data: SessionData) {
  const item: GodownItem = data.discItem;
  const { data: units } = await supabase
    .from("inventory_units")
    .select("id, unit_code")
    .eq("sku_id", item.sku_id)
    .eq("status", "available");
  const selected: string[] = data.selectedUnitIds ?? [];
  const buttons = (units ?? []).map((u: { id: string; unit_code: string }) => [{
    text: `${selected.includes(u.id) ? "✅ " : ""}${u.unit_code}`,
    callback_data: `godown:unitpick:${u.id}`,
  }]);
  buttons.push([{ text: `➡️ Done (${selected.length} selected)`, callback_data: "godown:unitpick:done" }]);
  buttons.push(GODOWN_EXIT_ROW);
  await tgSend(chatId, `Which piece(s) of "${item.name}" is this about? (optional — tap Done to skip)`, { inline_keyboard: buttons });
  await saveSession(supabase, chatId, "godown_unit_pick", data);
}

async function handleGodownPhoto(supabase: SB, chatId: number, data: SessionData, photoSizes: { file_id: string }[]) {
  const largest = photoSizes[photoSizes.length - 1];
  const url = await uploadTelegramPhoto(largest.file_id);
  if (!url) {
    await tgSend(chatId, "Couldn't save that photo — try again, or type a note / tap Skip.");
    return;
  }
  data.discPhotoUrl = url;
  await tgSend(chatId, "📷 Photo attached. Add a text note too, or tap Done to save.", {
    inline_keyboard: [[{ text: "✅ Done", callback_data: "godown:disc:notedone" }], GODOWN_EXIT_ROW],
  });
  await saveSession(supabase, chatId, "godown_discrepancy_note", data);
}

// Mirrors the download-then-reupload pattern from the Enter Inventory plan's
// photo handling (not yet built there, but the pattern is simple enough to
// use here now): resolve Telegram's file_id to a real URL, fetch the bytes,
// re-upload to the same item-photos bucket admin.html already uses.
async function uploadTelegramPhoto(fileId: string): Promise<string | null> {
  const fileRes = await fetch(`${TG_API}/getFile?file_id=${fileId}`);
  const fileJson = await fileRes.json();
  const filePath = fileJson?.result?.file_path;
  if (!filePath) return null;
  const imgRes = await fetch(`https://api.telegram.org/file/bot${BOT_TOKEN}/${filePath}`);
  const imgBuf = await imgRes.arrayBuffer();
  const objectName = `${Date.now()}-godown-telegram.jpg`;
  const uploadRes = await fetch(
    `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/item-photos/${objectName}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
        "Content-Type": "image/jpeg",
      },
      body: imgBuf,
    },
  );
  if (!uploadRes.ok) return null;
  return `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/item-photos/${objectName}`;
}

// Shared by the Skip button, the "Done" button after a photo, and typed
// text (handleGodownText) — the one place that actually writes the
// vendor_issues row, whichever way the note step was completed.
async function finalizeGodownDiscrepancy(supabase: SB, chatId: number, data: SessionData, note: string) {
  const item: GodownItem = data.discItem;
  const selectedUnitIds: string[] = data.selectedUnitIds ?? [];

  const { data: unitRow } = await supabase
    .from("inventory_units")
    .select("vendor_code")
    .eq("sku_id", item.sku_id)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  const vendorCode: string | null = unitRow?.vendor_code ?? null;
  let vendorUuid: string | null = null;
  if (vendorCode) {
    const { data: vRow } = await supabase.from("vendors").select("id").eq("vendor_id", vendorCode).maybeSingle();
    vendorUuid = vRow?.id ?? null;
  }

  const cleanNote = note.trim();
  const photoLine = data.discPhotoUrl ? `\nPhoto: ${data.discPhotoUrl}` : "";
  const source = data.discFromState === "godown_eod_item" ? "EOD reconciliation" : "spot check";
  const description = `${cleanNote || "(no note)"}${photoLine} — found during ${source} via Telegram bot`;

  if (vendorUuid) {
    await supabase.from("vendor_issues").insert({
      vendor_uuid: vendorUuid,
      vendor_code: vendorCode,
      sku_id: item.sku_id,
      batch: null,
      unit_ids: selectedUnitIds,
      issue_date: new Date().toISOString().slice(0, 10),
      issue_type: data.discType ?? "other",
      description,
      status: "open",
      created_by: "telegram_bot",
    });
    const pieceNote = selectedUnitIds.length ? ` (${selectedUnitIds.length} piece${selectedUnitIds.length > 1 ? "s" : ""})` : "";
    await tgSend(chatId, `⚠️ Logged: ${item.name}${pieceNote} — added to Vendor Issues for follow-up.`);
  } else {
    await tgSend(chatId, `⚠️ Couldn't resolve a vendor for ${item.name} — please log this one manually in admin.html's Vendor Issues.`);
  }

  // Damaged pieces: flip their status so they stop showing as sellable —
  // "damaged" is already a valid inventory_units status, no schema change
  // needed. Missing pieces aren't touched — there's no "missing" status,
  // and guessing wrong (it could just be misplaced) is worse than leaving
  // it as a logged issue only.
  if (data.discType === "damage" && selectedUnitIds.length) {
    await supabase.from("inventory_units").update({ status: "damaged", updated_at: new Date().toISOString() }).in("id", selectedUnitIds);
  }

  data.discPhotoUrl = undefined;
  data.selectedUnitIds = undefined;
  await advanceGodown(supabase, chatId, data.discFromState, data);
}

async function handleGodownText(supabase: SB, chatId: number, state: string, data: SessionData, text: string) {
  if (state === "godown_spot_search") {
    const q = text.trim();
    const { data: skus } = await supabase
      .from("inventory_skus")
      .select("id, name, au_available")
      .ilike("name", `%${q}%`);
    if (!skus?.length) {
      await tgSend(chatId, "No items matched that name — try again, or Exit.", { inline_keyboard: [GODOWN_EXIT_ROW] });
      return;
    }
    const { data: units } = await supabase.from("inventory_units").select("sku_id").eq("status", "available");
    const availCount: Record<string, number> = {};
    (units ?? []).forEach((u: { sku_id: string }) => {
      availCount[u.sku_id] = (availCount[u.sku_id] ?? 0) + 1;
    });
    const buttons = skus.map((s: { id: string; name: string; au_available: boolean }) => [{
      text: `${s.au_available ? "🇦🇺 " : ""}${s.name} (${availCount[s.id] ?? 0} in stock)`,
      callback_data: `godown:spotpick:${s.id}`,
    }]);
    buttons.push(GODOWN_EXIT_ROW);
    await tgSend(chatId, "Matching items:", { inline_keyboard: buttons });
    return;
  }

  if (state === "godown_discrepancy_note") {
    await finalizeGodownDiscrepancy(supabase, chatId, data, text.trim());
    return;
  }
}

async function startGodownEod(supabase: SB, chatId: number, data: SessionData) {
  const today = new Date().toISOString().slice(0, 10);
  const { data: todaySales } = await supabase.from("sales").select("items").eq("date", today);

  // sales.items[].sku_code is actually the physical unit_code (see
  // finalizeSale above), not a stable SKU identifier — group by product
  // name instead, which is what's actually stable per SKU.
  const nameCounts: Record<string, number> = {};
  (todaySales ?? []).forEach((s: { items: { name: string }[] }) => {
    (s.items ?? []).forEach((it: { name: string }) => {
      nameCounts[it.name] = (nameCounts[it.name] ?? 0) + 1;
    });
  });
  const soldNames = Object.keys(nameCounts);
  if (!soldNames.length) {
    await tgSend(chatId, "No sales recorded today — nothing to reconcile yet.");
    await showTopMenu(chatId);
    await saveSession(supabase, chatId, "idle", {});
    return;
  }

  const { data: skus } = await supabase.from("inventory_skus").select("id, name, au_available").in("name", soldNames);
  const { data: units } = await supabase.from("inventory_units").select("sku_id").eq("status", "available");
  const availCount: Record<string, number> = {};
  (units ?? []).forEach((u: { sku_id: string }) => {
    availCount[u.sku_id] = (availCount[u.sku_id] ?? 0) + 1;
  });

  data.eodList = (skus ?? []).map((s: { id: string; name: string; au_available: boolean }) => ({
    sku_id: s.id,
    name: s.name,
    au: s.au_available,
    soldToday: nameCounts[s.name] ?? 0,
    avail: availCount[s.id] ?? 0,
  }));
  data.eodIdx = 0;
  await showGodownItem(supabase, chatId, data, data.eodList[0]);
  await saveSession(supabase, chatId, "godown_eod_item", data);
}

async function showGodownItem(supabase: SB, chatId: number, data: SessionData, item: GodownItem) {
  const auTag = item.au ? "🇦🇺 " : "";
  const soldLine = item.soldToday !== undefined ? `Sold today: ${item.soldToday}\n` : "";
  await tgSend(
    chatId,
    `${auTag}${item.name}\n${soldLine}Expected in stock: ${item.avail}\n\nDoes the physical count match?`,
    {
      inline_keyboard: [
        [{ text: "✅ Matches", callback_data: "godown:match" }],
        [{ text: "⚠️ Discrepancy", callback_data: "godown:discrepancy" }],
        GODOWN_EXIT_ROW,
      ],
    },
  );
}

// Shared "what happens after this item is resolved" step for both the EOD
// list-walk and the spot-check single-item flow — matched or logged, either
// way this decides whether to show the next EOD item or re-prompt spot search.
async function advanceGodown(supabase: SB, chatId: number, fromState: string, data: SessionData) {
  if (fromState === "godown_eod_item") {
    data.eodIdx = (data.eodIdx ?? 0) + 1;
    const list = data.eodList ?? [];
    if (data.eodIdx >= list.length) {
      await tgSend(chatId, "✅ End-of-day reconciliation complete.");
      await showTopMenu(chatId);
      await saveSession(supabase, chatId, "idle", {});
      return;
    }
    await showGodownItem(supabase, chatId, data, list[data.eodIdx]);
    await saveSession(supabase, chatId, "godown_eod_item", data);
    return;
  }
  await tgSend(chatId, "Type another item name to search, or Exit.", { inline_keyboard: [GODOWN_EXIT_ROW] });
  await saveSession(supabase, chatId, "godown_spot_search", data);
}
