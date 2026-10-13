// Patch Tuesday's inside view. Runs a FIXED set of read-only catalog queries (no
// arbitrary SQL, no data rows, names/counts/booleans only) and asks the project's
// existing AI provider (settings.openrouter_key / gemini_key via callLLM) for a
// plain-language triage. Gated by the x-agent-key header (secret AGENT_REPORT_KEY),
// so the home server needs only that one limited key, never a database credential.
// Detect-only: nothing here writes, deploys or fixes anything.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";
import { callLLM } from "../_shared/askGemini.ts";

Deno.serve(async (req: Request) => {
  const expected = Deno.env.get("AGENT_REPORT_KEY");
  if (req.method !== "POST" || !expected || req.headers.get("x-agent-key") !== expected) {
    return new Response("Unauthorized", { status: 401 });
  }

  const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 1, prepare: false });
  // deno-lint-ignore no-explicit-any
  const out: Record<string, any> = {};
  try {
    await sql.begin("read only", async (s) => {
      out.rls_off = await s`select c.relname as t, has_table_privilege('anon', c.oid, 'select,insert,update,delete') as anon_priv
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity order by 1`;
      out.open_policies = await s`select tablename as t, policyname as p, cmd, roles::text as roles
        from pg_policies where schemaname = 'public' and (qual = 'true' or with_check = 'true') order by 1, 2`;
      out.anon_secdef = await s`select p.proname as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.prosecdef and has_function_privilege('anon', p.oid, 'execute') order by 1`;
      out.cron = await s`select j.jobname, j.active,
          (select status from cron.job_run_details d where d.jobid = j.jobid order by start_time desc limit 1) as last_status,
          (select max(start_time) from cron.job_run_details d where d.jobid = j.jobid) as last_run,
          (select count(*) from cron.job_run_details d where d.jobid = j.jobid and status = 'failed' and start_time > now() - interval '7 days')::int as failed_7d
        from cron.job j order by 1`;
      out.bots = await s`select bot, max(created_at) as last_msg from bot_message_log group by bot`;
      out.buckets = await s`select id, public from storage.buckets order by 1`;
      out.secret_settings = await s`select key from settings where key ~* '(key|token|secret|password)' and length(value) > 0 order by 1`;
      out.stuck_sessions = (await s`select (select count(*) from telegram_sessions where state <> 'idle' and updated_at < now() - interval '45 minutes')
        + (select count(*) from telegram_sessions_au where state <> 'idle' and updated_at < now() - interval '45 minutes') as n`)[0].n as number;
      out.stuck_sessions = Number(out.stuck_sessions);
    });
  } catch (e) {
    await sql.end();
    return new Response(JSON.stringify({ error: String(e).slice(0, 300) }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
  await sql.end();

  try {
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const summary = JSON.stringify({
      tables_without_rls: out.rls_off, permissive_policies: out.open_policies,
      anon_callable_security_definer_functions: out.anon_secdef.map((x: { f: string }) => x.f),
      cron: out.cron, buckets: out.buckets, api_keys_stored_in_settings: out.secret_settings.map((x: { key: string }) => x.key),
      stuck_sessions: out.stuck_sessions,
    });
    out.triage = (await callLLM(supabase,
      `You are a careful security reviewer for a small saree e-commerce business on Supabase. Below is a read-only inventory (names only, no data). Context, ALREADY INTENDED BY DESIGN, do not flag these: product/QR/review/request photo buckets are public so the website can show them; the invoices bucket must stay private; page_views allows anonymous INSERT only (visit counting); instagram_posts and popups are public-read; login, signup, password-reset, coupon and event-registration functions are intentionally callable by anonymous visitors; row-level security protects the tables. Only report REAL, specific risks visible in the inventory (a table with RLS off and anon privileges, a write policy open to anon on a sensitive table, a failing or inactive cron job, API keys stored as plain table rows, a private bucket that is public). Write at most 4 short plain-text bullets, highest priority first, each with one concrete fix. If nothing notable, reply exactly: Nothing notable beyond the known items. Do not invent facts.\n\n${summary}`)).slice(0, 1800);
  } catch {
    out.triage = "";
  }
  return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json" } });
});
