#!/usr/bin/env python3
"""Full, read-only backup of the live Meensha Supabase project (India + Australia).

What it captures: every public table (rows as JSON), schema/policies/functions/
cron/foreign-key metadata, storage bucket definitions + every stored file, edge
function list and secret NAMES (never values).

Output (under BACKUP_DIR, which Syncthing mirrors to the home server):
  <UTC stamp>/meensha-backup-<stamp>.tar.gz.gpg   AES-256, passphrase in macOS Keychain
  <UTC stamp>/MANIFEST.json                       plaintext: timestamps, counts, SHA-256 of every file
  BACKUP-LOG.jsonl                                append-only hash chain: each entry hashes the previous one

Usage:  backup_meensha.py            run a backup
        backup_meensha.py --verify   verify the hash chain + every archive checksum
Needs: supabase CLI (logged in + linked access), gpg, macOS `security`.
"""
import datetime, hashlib, json, os, secrets, socket, subprocess, sys, tarfile, tempfile, urllib.parse, urllib.request

REF = "eglanmhhcccsuhbxywua"
BACKUP_DIR = os.environ.get("MEENSHA_BACKUP_DIR", "/Users/dheerajbharti/Claude Projects/Meensha/backups/data")
KEYCHAIN_SERVICE = "meensha-backup"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = 1000


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_str(s):
    return hashlib.sha256(s.encode()).hexdigest()


def first_json(text):
    i = text.index("{")
    obj, _ = json.JSONDecoder().raw_decode(text[i:])
    return obj


def sql(query):
    out = subprocess.run(
        ["supabase", "db", "query", "--linked", "--output-format", "json", query],
        capture_output=True, text=True, timeout=300,
    )
    if "rows" not in out.stdout:
        raise RuntimeError(f"query failed: {query[:80]} :: {out.stdout[-300:]} {out.stderr[-300:]}")
    return first_json(out.stdout)["rows"]


def service_key():
    out = subprocess.run(["supabase", "projects", "api-keys", "--project-ref", REF, "-o", "json"],
                         capture_output=True, text=True, timeout=120)
    for k in json.loads(out.stdout[out.stdout.index("["):out.stdout.rindex("]") + 1]):
        if k.get("name") == "service_role":
            return k["api_key"]
    raise RuntimeError("service_role key not available")


def keychain_passphrase():
    r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"], capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    pw = secrets.token_urlsafe(32)
    subprocess.run(["security", "add-generic-password", "-a", os.environ.get("USER", "dheeraj"), "-s", KEYCHAIN_SERVICE, "-w", pw], check=True)
    print("Created a new backup passphrase in the macOS Keychain (service 'meensha-backup').")
    return pw


def verify():
    log_path = os.path.join(BACKUP_DIR, "BACKUP-LOG.jsonl")
    if not os.path.exists(log_path):
        print("No backup log yet."); return 1
    prev, ok = "GENESIS", True
    for n, line in enumerate(open(log_path), 1):
        e = json.loads(line)
        expect = sha256_str(prev + e["manifest_sha256"] + e["archive_sha256"] + e["created_utc"])
        stamp_dir = os.path.join(BACKUP_DIR, e["stamp"])
        arch = os.path.join(stamp_dir, f"meensha-backup-{e['stamp']}.tar.gz.gpg")
        man = os.path.join(stamp_dir, "MANIFEST.json")
        problems = []
        if e["prev_entry_hash"] != prev: problems.append("chain broken (prev hash mismatch)")
        if e["entry_hash"] != expect: problems.append("entry hash mismatch")
        if not os.path.exists(arch) or sha256_file(arch) != e["archive_sha256"]: problems.append("archive missing/changed")
        if not os.path.exists(man) or sha256_file(man) != e["manifest_sha256"]: problems.append("manifest missing/changed")
        print(f"#{n} {e['stamp']}  {'OK' if not problems else 'FAIL: ' + '; '.join(problems)}")
        ok &= not problems
        prev = e["entry_hash"]
    print("CHAIN VALID" if ok else "CHAIN INVALID")
    return 0 if ok else 2


def main():
    if "--verify" in sys.argv:
        sys.exit(verify())
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    ist = now.astimezone(datetime.timezone(datetime.timedelta(hours=5, minutes=30))).isoformat(timespec="seconds")
    os.makedirs(BACKUP_DIR, mode=0o700, exist_ok=True)
    out_dir = os.path.join(BACKUP_DIR, stamp)
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    work = tempfile.mkdtemp(prefix="meensha-bk-")
    os.makedirs(os.path.join(work, "data")); os.makedirs(os.path.join(work, "extras")); os.makedirs(os.path.join(work, "storage"))

    def put(rel, obj):
        p = os.path.join(work, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f: json.dump(obj, f, indent=1, default=str)

    # --- tables
    tables = [r["table_name"] for r in sql("select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1")]
    counts = {}
    for t in tables:
        rows, off = [], 0
        while True:
            r = sql(f'select coalesce(json_agg(x), \'[]\'::json) as j from (select * from public."{t}" order by ctid limit {PAGE} offset {off}) x')
            chunk = r[0]["j"]
            if isinstance(chunk, str): chunk = json.loads(chunk)
            rows += chunk
            if len(chunk) < PAGE: break
            off += PAGE
        counts[t] = len(rows)
        put(f"data/{t}.json", rows)
        print(f"  table {t}: {len(rows)} rows")

    # --- schema / config metadata (everything needed to rebuild structure)
    put("extras/columns.json", sql("select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema='public' order by table_name, ordinal_position"))
    put("extras/foreign_keys.json", sql("select conrelid::regclass::text as child, confrelid::regclass::text as parent from pg_constraint where contype='f' and connamespace='public'::regnamespace"))
    put("extras/policies.json", sql("select tablename, policyname, cmd, roles, qual, with_check from pg_policies where schemaname='public'"))
    put("extras/functions.json", sql("select p.proname as name, pg_get_functiondef(p.oid) as definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f'"))
    put("extras/cron_jobs.json", sql("select jobname, schedule, command, active from cron.job order by jobname"))
    put("extras/storage_buckets.json", sql("select id, name, public, file_size_limit, allowed_mime_types from storage.buckets"))
    objs = sql("select bucket_id, name from storage.objects order by bucket_id, name")
    put("extras/storage_objects.json", objs)
    for cmd, rel in ((["supabase", "functions", "list", "--project-ref", REF, "-o", "json"], "extras/edge_functions.json"),
                     (["supabase", "secrets", "list", "--project-ref", REF, "-o", "json"], "extras/secret_names.json")):
        try:
            o = subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout
            data = json.loads(o[o.index("["):o.rindex("]") + 1])
            if rel.endswith("secret_names.json"):
                data = [{"name": d.get("name")} for d in data]   # names only, never values or digests
            put(rel, data)
        except Exception as e:
            put(rel, {"error": str(e)})

    # --- storage files
    key = service_key()
    for o in objs:
        url = f"https://{REF}.supabase.co/storage/v1/object/{o['bucket_id']}/{urllib.parse.quote(o['name'], safe='/')}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}", "apikey": key})
        dest = os.path.join(work, "storage", o["bucket_id"], o["name"])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as f: f.write(resp.read())
        except Exception as e:
            print(f"  WARN storage {o['bucket_id']}/{o['name']}: {e}")
    print(f"  storage: {len(objs)} files")

    # --- manifest (plaintext, no PII: names, counts, hashes)
    files = {}
    for dp, _, fs in os.walk(work):
        for fn in fs:
            p = os.path.join(dp, fn); files[os.path.relpath(p, work)] = sha256_file(p)
    try:
        git_head = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    except Exception:
        git_head = ""
    arch_plain = os.path.join(work, "..", f"meensha-backup-{stamp}.tar.gz")
    arch_plain = os.path.normpath(arch_plain)
    with tarfile.open(arch_plain, "w:gz") as tar: tar.add(work, arcname="meensha-backup")
    arch_enc = os.path.join(out_dir, f"meensha-backup-{stamp}.tar.gz.gpg")
    pw = keychain_passphrase()
    subprocess.run(["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase-fd", "0", "--symmetric",
                    "--cipher-algo", "AES256", "-o", arch_enc, arch_plain], input=pw.encode(), check=True, capture_output=True)
    os.remove(arch_plain)
    manifest = {
        "project_ref": REF, "created_utc": now.isoformat(timespec="seconds"), "created_ist": ist,
        "host": socket.gethostname(), "repo_git_head": git_head, "table_row_counts": counts,
        "storage_file_count": len(objs), "payload_file_sha256": files,
        "archive_file": os.path.basename(arch_enc), "archive_sha256": sha256_file(arch_enc),
        "script": "scripts/backup_meensha.py", "restore": "scripts/restore_meensha.py (see RESTORE.md)",
    }
    man_path = os.path.join(out_dir, "MANIFEST.json")
    with open(man_path, "w") as f: json.dump(manifest, f, indent=1)

    # --- append-only hash chain
    log_path = os.path.join(BACKUP_DIR, "BACKUP-LOG.jsonl")
    prev = "GENESIS"
    if os.path.exists(log_path):
        last = [l for l in open(log_path) if l.strip()][-1]
        prev = json.loads(last)["entry_hash"]
    man_sha, arch_sha = sha256_file(man_path), manifest["archive_sha256"]
    entry = {"stamp": stamp, "created_utc": manifest["created_utc"], "created_ist": ist, "manifest_sha256": man_sha,
             "archive_sha256": arch_sha, "prev_entry_hash": prev,
             "entry_hash": sha256_str(prev + man_sha + arch_sha + manifest["created_utc"]),
             "tables": len(counts), "rows": sum(counts.values()), "storage_files": len(objs)}
    with open(log_path, "a") as f: f.write(json.dumps(entry) + "\n")

    # permissions: owner-only
    for dp, ds, fs in os.walk(BACKUP_DIR):
        os.chmod(dp, 0o700)
        for fn in fs: os.chmod(os.path.join(dp, fn), 0o600)
    import shutil; shutil.rmtree(work, ignore_errors=True)
    print(f"\nBACKUP OK  {stamp} (IST {ist})\n  {len(counts)} tables, {sum(counts.values())} rows, {len(objs)} files\n  {arch_enc}\n  chain entry {entry['entry_hash'][:16]}…")


if __name__ == "__main__":
    main()
