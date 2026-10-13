// Read-only export endpoint for the nightly backup on the home server. Gated by the
// x-backup-key header (secret BACKUP_EXPORT_KEY, separate from AGENT_REPORT_KEY: this key
// can read ALL data, so it lives only in the Supabase secret, Dheeraj's Keychain and a
// root-only file on the backup host). Nothing here writes. Actions (JSON body):
//   {action:"tables"}                             list public tables
//   {action:"rows", table, offset, limit}         one page of rows as JSON
//   {action:"extras"}                             schema/policy/function/cron/bucket metadata
//   {action:"storage"}                            every stored file with a 1-hour signed URL

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  const expected = Deno.env.get("BACKUP_EXPORT_KEY");
  if (req.method !== "POST" || !expected || req.headers.get("x-backup-key") !== expected) {
    return new Response("Unauthorized", { status: 401 });
  }
  const body = await req.json().catch(() => ({}));
  const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { max: 1, prepare: false });
  try {
    if (body.action === "tables") {
      const r = await sql`select table_name as t from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1`;
      return json({ tables: r.map((x: { t: string }) => x.t) });
    }
    if (body.action === "rows") {
      const valid = await sql`select 1 from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' and table_name = ${String(body.table)}`;
      if (!valid.length) return json({ error: "unknown table" }, 400);
      const limit = Math.min(Math.max(Number(body.limit) || 1000, 1), 2000);
      const offset = Math.max(Number(body.offset) || 0, 0);
      const rows = await sql.begin("read only", (s) =>
        s`select coalesce(json_agg(x), '[]'::json) as j from (select * from ${s(String(body.table))} order by ctid limit ${limit} offset ${offset}) x`);
      return json({ rows: rows[0].j });
    }
    if (body.action === "extras") {
      const out = await sql.begin("read only", async (s) => ({
        columns: await s`select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = 'public' order by table_name, ordinal_position`,
        foreign_keys: await s`select conrelid::regclass::text as child, confrelid::regclass::text as parent from pg_constraint where contype = 'f' and connamespace = 'public'::regnamespace`,
        policies: await s`select tablename, policyname, cmd, roles::text as roles, qual, with_check from pg_policies where schemaname = 'public'`,
        functions: await s`select p.proname as name, pg_get_functiondef(p.oid) as definition from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f'`,
        cron_jobs: await s`select jobname, schedule, command, active from cron.job order by jobname`,
        storage_buckets: await s`select id, name, public, file_size_limit, allowed_mime_types from storage.buckets`,
      }));
      return json(out);
    }
    if (body.action === "storage") {
      const objs = await sql`select bucket_id, name from storage.objects order by bucket_id, name`;
      const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      const files: { bucket_id: string; name: string; url: string | null }[] = [];
      for (const o of objs as { bucket_id: string; name: string }[]) {
        const { data } = await supabase.storage.from(o.bucket_id).createSignedUrl(o.name, 3600);
        files.push({ bucket_id: o.bucket_id, name: o.name, url: data?.signedUrl ?? null });
      }
      return json({ files });
    }
    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String(e).slice(0, 300) }, 500);
  } finally {
    await sql.end();
  }
});
