// Verifies a customer-entered OTP code and returns a session token on
// success. Called from the storefront login modal (index.html) after the
// customer types the code they received.
//
// Required secrets: none. Supabase auto-provides SUPABASE_URL and
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
    const { wa, code } = await req.json();
    const waDigits = String(wa || "").replace(/\D/g, "");
    const codeStr = String(code || "").trim();
    if (waDigits.length < 8 || codeStr.length !== 6) {
      return json({ error: "Enter the 6-digit code sent to your WhatsApp" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data, error } = await supabase.rpc("verify_customer_otp_code", {
      p_wa: waDigits,
      p_code: codeStr,
    });
    if (error) return json({ error: "Could not verify code" }, 500);
    if (!data) return json({ error: "Incorrect or expired code" }, 401);

    return json({ ok: true, ...data });
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
