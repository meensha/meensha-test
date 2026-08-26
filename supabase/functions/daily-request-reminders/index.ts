// Daily nag for every "Request a Saree" row still open (status new or
// contacted) — sent to the relevant region's staff bot + MeenshaMonitor,
// same broadcast helper and same Reply/Done/Not-Done buttons as the
// initial notification. Meant to be called once a day by a pg_cron job
// (see setup/add_saree_requests_cron.sql), same pattern as
// daily-health-check.
//
// Required secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_TOKEN_AU,
// TELEGRAM_MONITOR_BOT_TOKEN (all already set). Supabase auto-provides
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { broadcastRequestNotification } from "../_shared/broadcastRequest.ts";

Deno.serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: openRequests } = await supabase
    .from("requests")
    .select("*")
    .in("status", ["new", "contacted"])
    .order("created_at", { ascending: true });

  for (const r of openRequests ?? []) {
    await broadcastRequestNotification(supabase, r, "⏰ Reminder — still pending");
  }

  return new Response(JSON.stringify({ reminded: (openRequests ?? []).length }), { headers: { "Content-Type": "application/json" } });
});
