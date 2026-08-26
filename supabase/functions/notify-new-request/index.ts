// Called by the storefront right after submit_saree_request succeeds
// (fire-and-forget from index.html, same pattern as create-payment-link).
// Broadcasts the new request to the right region's staff bot + Monitor.
//
// Required secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_TOKEN_AU,
// TELEGRAM_MONITOR_BOT_TOKEN (all already set for the existing bots).
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { broadcastRequestNotification } from "../_shared/broadcastRequest.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { id } = await req.json();
    if (!id) return json({ error: "Missing id" }, 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: reqRow } = await supabase.from("requests").select("*").eq("id", id).maybeSingle();
    if (!reqRow) return json({ error: "Request not found" }, 404);

    await broadcastRequestNotification(supabase, reqRow, "New saree request");
    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
}
