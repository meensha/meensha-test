// Records one admin.html login attempt into auth_log, with the real client
// IP + a geolocation lookup — a browser can't see its own public IP, so
// admin.html now posts here instead of inserting into auth_log directly
// (see setup/add_auth_log_location.sql). Best-effort: a failed geo lookup
// still logs the attempt with location left blank.
//
// Required secrets: none. Supabase auto-provides SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY. Deploy normally (JWT verification stays ON —
// called from admin.html with the anon key, like generate-invoice-pdf).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PRIVATE_IP = /^(10\.|127\.|0\.|::1$|fc|fd|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/i;

function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0].trim();
  return req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "";
}

async function geoLocate(ip: string): Promise<string> {
  if (!ip || PRIVATE_IP.test(ip)) return "";
  try {
    const r = await fetch(`https://ipapi.co/${ip}/json/`);
    if (!r.ok) return "";
    const j = await r.json();
    if (j.error) return "";
    return [j.city, j.region, j.country_name].filter(Boolean).join(", ");
  } catch {
    return "";
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { username, success, reason, user_agent } = await req.json();
    const ip = clientIp(req);
    const location = await geoLocate(ip);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    await supabase.from("auth_log").insert({
      username: String(username || "").toLowerCase(),
      success: !!success,
      reason: reason || "",
      user_agent: String(user_agent || "").slice(0, 200),
      ip_address: ip,
      location,
    });

    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
}
