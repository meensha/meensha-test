// Reports the "Meensha TODO worker" cloud routine's progress to Shalini +
// MeenshaMonitor. The routine itself CANNOT call Telegram or this project's
// Supabase directly — its sandbox's egress proxy only allows github.com and
// a short list of package registries, confirmed by testing (see
// TODO.md/session notes 2026-09-13). So instead of the routine pushing a
// report, this function pulls: it polls GitHub's commits API for new
// commits on meensha-test2 (the routine's only repo) since the last check,
// and relays each one. This runs ~15 min after each of the routine's own
// fire times (see setup/add_todo_worker_digest_cron.sql) — long enough for
// a run to finish committing and pushing.
//
// Required secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_MONITOR_BOT_TOKEN.
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.
// No GitHub token needed — public repo, unauthenticated API calls are fine
// at this low a request rate.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const REPO = "meensha/meensha-test2";
const SETTINGS_KEY = "todo_worker_last_commit_sha";

async function sendTo(token: string, chatId: string, text: string) {
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text }),
    });
  } catch { /* best-effort — one failed send must not block the others */ }
}

Deno.serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: settingRow } = await supabase
    .from("settings").select("value").eq("key", SETTINGS_KEY).maybeSingle();
  const lastSha = settingRow?.value || null;

  const commitsRes = await fetch(
    `https://api.github.com/repos/${REPO}/commits?sha=main&per_page=20`,
    { headers: { "User-Agent": "meensha-todo-digest", Accept: "application/vnd.github+json" } },
  );
  if (!commitsRes.ok) {
    return new Response(JSON.stringify({ ok: false, error: `GitHub API ${commitsRes.status}` }), { status: 502 });
  }
  const commits = await commitsRes.json();

  // Commits come back newest-first. Take everything up to (not including)
  // the last one we already reported; if we've never checked before, only
  // report the single newest one rather than dumping full history.
  const newCommits: typeof commits = [];
  for (const c of commits) {
    if (c.sha === lastSha) break;
    newCommits.push(c);
    if (!lastSha && newCommits.length >= 1) break;
  }

  if (newCommits.length === 0) {
    return new Response(JSON.stringify({ ok: true, new_commits: 0 }), { headers: { "Content-Type": "application/json" } });
  }

  // Oldest-first for a readable chronological report.
  newCommits.reverse();
  const lines = newCommits.map((c) => {
    const subject = (c.commit?.message || "").split("\n")[0];
    const author = c.commit?.author?.name || "unknown";
    return `• ${subject} (${author})`;
  });
  const text = `🤖 TODO worker — staging (test2) activity\n\n${lines.join("\n")}\n\nOn test2, pending your review before it goes to production.`;

  const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (botToken) {
    const { data: allowedRows } = await supabase.from("telegram_allowed_users").select("chat_id").eq("active", true);
    for (const row of allowedRows ?? []) await sendTo(botToken, row.chat_id, text);
  }
  const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
  const { data: monitorRow } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
  if (monitorToken && monitorRow?.value) await sendTo(monitorToken, monitorRow.value, text);

  await supabase.from("settings").upsert({ key: SETTINGS_KEY, value: commits[0].sha }, { onConflict: "key" });

  return new Response(JSON.stringify({ ok: true, new_commits: newCommits.length }), { headers: { "Content-Type": "application/json" } });
});
