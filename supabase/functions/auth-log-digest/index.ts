// Daily rolling-window digest of admin.html login activity, posted to
// MeenshaMonitor only (@meenshabot) — never Shalini's chat, per the TODO
// spec. Full unbounded history stays in admin.html's Auth Log card; this
// only reports what happened since the last time this ran (tracked in
// settings.auth_log_last_digest_at), same "since last report" shape as
// activity-summary-digest. Triggered by pg_cron — see
// setup/add_auth_log_location.sql.
//
// Required secret: TELEGRAM_MONITOR_BOT_TOKEN. Supabase auto-provides
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: settingsRow } = await supabase
    .from("settings").select("value").eq("key", "auth_log_last_digest_at").maybeSingle();
  const since = settingsRow?.value || new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const now = new Date().toISOString();

  const { data: rows } = await supabase
    .from("auth_log")
    .select("username, success, reason, ip_address, location, created_at")
    .gt("created_at", since)
    .order("created_at", { ascending: true });

  const attempts = rows ?? [];

  // Always advance the window, even when nothing happened, so the next
  // digest doesn't re-report the same quiet stretch.
  await supabase.from("settings").upsert({ key: "auth_log_last_digest_at", value: now });

  if (attempts.length === 0) {
    return new Response(JSON.stringify({ attempts: 0, sent: false }), { headers: { "Content-Type": "application/json" } });
  }

  const failed = attempts.filter((a: { success: boolean }) => !a.success);

  const lines = failed.map((a: { username: string; reason?: string; ip_address?: string; location?: string; created_at: string }) => {
    const when = (a.created_at || "").replace("T", " ").slice(11, 19);
    const where = a.location || a.ip_address || "unknown location";
    return `${when} — ${a.username || "?"} (${a.reason || "bad_password"}) from ${where}`;
  });

  const text = `📋 Meensha Admin Login Activity (last ${Math.round((Date.now() - new Date(since).getTime()) / 3600000)}h)\n\n`
    + `${attempts.length} attempt(s), ${failed.length} failed.\n`
    + (failed.length ? `\nFailed attempts:\n${lines.join("\n")}` : "");

  try {
    const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
    const { data: chatRow } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
    const chatId = chatRow?.value;
    if (monitorToken && chatId) {
      await fetch(`https://api.telegram.org/bot${monitorToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: chatId, text }),
      });
    }
  } catch { /* best-effort — window has already advanced above either way */ }

  return new Response(JSON.stringify({ attempts: attempts.length, failed: failed.length, sent: true }), { headers: { "Content-Type": "application/json" } });
});
