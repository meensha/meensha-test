// Daily tech-stack health digest, posted to MeenshaMonitor (@meenshabot).
// Checks the four externally-facing connections the business depends on:
// the live site, Supabase itself, Razorpay, and GitHub (source + Pages).
// Meant to be called once a day by a pg_cron job (see
// setup/add_daily_health_check_cron.sql) — not triggered by user traffic.
//
// Required secrets: TELEGRAM_MONITOR_BOT_TOKEN, RAZORPAY_KEY_ID,
// RAZORPAY_KEY_SECRET (already set for create-payment-link).
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

async function checkWebsite(): Promise<string> {
  try {
    const res = await fetch("https://meensha.in", { method: "GET" });
    return res.ok ? "✅ Website" : `⚠️ Website — HTTP ${res.status}`;
  } catch {
    return "🔴 Website — unreachable";
  }
}

async function checkSupabase(supabase: any): Promise<string> {
  try {
    const { error } = await supabase.from("settings").select("key").limit(1);
    return error ? `🔴 Supabase — ${error.message}` : "✅ Supabase";
  } catch (e) {
    return `🔴 Supabase — ${String(e)}`;
  }
}

async function checkRazorpay(): Promise<string> {
  try {
    const keyId = Deno.env.get("RAZORPAY_KEY_ID");
    const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET");
    if (!keyId || !keySecret) return "⚠️ Razorpay — no keys configured";
    const auth = "Basic " + btoa(`${keyId}:${keySecret}`);
    const res = await fetch("https://api.razorpay.com/v1/payments?count=1", { headers: { Authorization: auth } });
    return res.ok ? "✅ Razorpay" : `⚠️ Razorpay — HTTP ${res.status}`;
  } catch {
    return "🔴 Razorpay — unreachable";
  }
}

async function checkGithub(): Promise<string> {
  try {
    const res = await fetch("https://api.github.com/repos/meensha/meensha-test");
    // GitHub's unauthenticated API rate limit (60/hr) is shared across all
    // Supabase Edge Function traffic on this IP range, not just ours — a
    // 403 here is usually that, not a real outage. The website check above
    // already confirms GitHub Pages itself is serving (meensha.in IS
    // GitHub Pages), so don't alarm on this specific case.
    if (res.status === 403) return "ℹ️ GitHub API rate-limited (site itself already confirmed up above)";
    if (!res.ok) return `⚠️ GitHub — HTTP ${res.status}`;
    const data = await res.json();
    return data.has_pages ? "✅ GitHub + Pages" : "⚠️ GitHub — Pages not enabled?";
  } catch {
    return "🔴 GitHub — unreachable";
  }
}

Deno.serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const [website, supabaseStatus, razorpay, github] = await Promise.all([
    checkWebsite(), checkSupabase(supabase), checkRazorpay(), checkGithub(),
  ]);
  const lines = [website, supabaseStatus, razorpay, github];
  const anyIssue = lines.some((l) => !l.startsWith("✅") && !l.startsWith("ℹ️"));
  const text = `${anyIssue ? "⚠️ Meensha Daily Health Check" : "✅ Meensha Daily Health Check — all clear"}\n\n${lines.join("\n")}`;

  try {
    const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
    const { data: row } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").single();
    const chatId = row?.value;
    if (monitorToken && chatId) {
      await fetch(`https://api.telegram.org/bot${monitorToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: chatId, text }),
      });
    }
  } catch { /* best-effort — the check result still returns below either way */ }

  return new Response(JSON.stringify({ lines }), { headers: { "Content-Type": "application/json" } });
});
