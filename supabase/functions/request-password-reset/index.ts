// Sends a password-reset code by email. Called from the storefront's
// "Forgot password" form (index.html). Always responds ok:true whether or
// not the email is registered, so this can't be used to enumerate accounts.
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
    const { email } = await req.json();
    const emailNorm = String(email || "").trim().toLowerCase();
    if (!emailNorm) return json({ error: "Enter your email address" }, 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: exists, error } = await supabase.rpc("request_password_reset", { p_email: emailNorm });
    if (error) return json({ error: "Could not process request" }, 500);

    if (exists) {
      const { count } = await supabase
        .from("customer_otp")
        .select("id", { count: "exact", head: true })
        .eq("email", emailNorm).eq("purpose", "reset")
        .gte("created_at", new Date(Date.now() - 10 * 60 * 1000).toISOString());
      if ((count || 0) < 3) {
        const code = String(Math.floor(100000 + Math.random() * 900000));
        await supabase.rpc("create_customer_otp", { p_email: emailNorm, p_purpose: "reset", p_code: code });
        await sendEmail(emailNorm, "Reset your Meensha password",
          `Your password reset code is ${code}. It expires in 10 minutes. If you didn't request this, ignore this email.`);
      }
    }

    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
}
