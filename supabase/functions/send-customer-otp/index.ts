// Generates and "sends" a 6-digit OTP to a customer's WhatsApp number.
// Called from the storefront login modal (index.html) when a customer
// enters their WhatsApp number.
//
// OTP delivery is currently STUBBED — no WhatsApp/SMS provider is wired up
// yet, so the code is only logged (visible via `supabase functions logs
// send-customer-otp`), never actually sent. Swap the STUB block below for a
// real provider call (e.g. MSG91) once an API key is available; the rest of
// the flow (hashing, expiry, rate limiting) is already real.
//
// Required secrets: none yet. Supabase auto-provides SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY.

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
    const { wa } = await req.json();
    const waDigits = String(wa || "").replace(/\D/g, "");
    if (waDigits.length < 8) {
      return json({ error: "Enter a valid WhatsApp number" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Rate-limit: at most 3 OTP requests per number in the last 10 minutes.
    const { count } = await supabase
      .from("customer_otp")
      .select("id", { count: "exact", head: true })
      .eq("wa", waDigits)
      .gte("created_at", new Date(Date.now() - 10 * 60 * 1000).toISOString());
    if ((count || 0) >= 3) {
      return json({ error: "Too many attempts — please wait a few minutes and try again" }, 429);
    }

    const code = String(Math.floor(100000 + Math.random() * 900000));

    const { error: rpcErr } = await supabase.rpc("create_customer_otp", {
      p_wa: waDigits,
      p_code: code,
    });
    if (rpcErr) return json({ error: "Could not create OTP" }, 500);

    // ── STUB: no OTP provider wired up yet ──
    // Real send goes here once a provider (e.g. MSG91) API key is available.
    console.log(`[STUB] OTP for ${waDigits}: ${code}`);

    return json({ ok: true });
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
