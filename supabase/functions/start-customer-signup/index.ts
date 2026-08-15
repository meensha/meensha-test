// Step 1 of signup: create/refresh an unverified customer row (WA number +
// email + name + password) and email a 6-digit verification code. Called
// from the storefront's signup form (index.html).
//
// Required secrets: none yet (email is stubbed/logged until RESEND_API_KEY
// is set — see _shared/email.ts). Supabase auto-provides SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendEmail } from "../_shared/email.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { wa, email, name, password } = await req.json();
    const waDigits = String(wa || "").replace(/\D/g, "");
    const emailNorm = String(email || "").trim().toLowerCase();
    if (waDigits.length < 8) return json({ error: "Enter a valid WhatsApp number" }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(emailNorm)) return json({ error: "Enter a valid email address" }, 400);
    if (!password || String(password).length < 6) return json({ error: "Password must be at least 6 characters" }, 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data, error } = await supabase.rpc("start_customer_signup", {
      p_wa: waDigits,
      p_email: emailNorm,
      p_name: name || null,
      p_password: password,
    });
    if (error) return json({ error: "Could not start signup" }, 500);
    if (!data.ok) {
      const msg = data.error === "wa_taken" ? "This WhatsApp number is already registered"
        : data.error === "email_taken" ? "This email is already registered"
        : "Could not start signup";
      return json({ error: msg }, 409);
    }

    // Rate-limit: at most 3 signup OTP requests per email in the last 10 minutes.
    const { count } = await supabase
      .from("customer_otp")
      .select("id", { count: "exact", head: true })
      .eq("email", emailNorm).eq("purpose", "signup")
      .gte("created_at", new Date(Date.now() - 10 * 60 * 1000).toISOString());
    if ((count || 0) >= 3) return json({ error: "Too many attempts — please wait a few minutes and try again" }, 429);

    const code = String(Math.floor(100000 + Math.random() * 900000));
    const { error: otpErr } = await supabase.rpc("create_customer_otp", {
      p_email: emailNorm, p_purpose: "signup", p_code: code,
    });
    if (otpErr) return json({ error: "Could not create verification code" }, 500);

    await sendEmail(emailNorm, "Your Meensha verification code",
      `Your verification code is ${code}. It expires in 10 minutes.`);

    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
}
