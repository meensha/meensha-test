#!/usr/bin/env python3
"""Restore Meensha data from an encrypted backup made by backup_meensha.py.

SAFE BY DEFAULT: without --apply it only decrypts, verifies and prints what it WOULD do.
It never deletes anything. Rows are inserted with ON CONFLICT DO NOTHING, so restoring into
a healthy database changes nothing; it fills gaps / rebuilds an empty database. To repair a
damaged table, empty that table by hand first, then restore it.

  restore_meensha.py --list                          list backups (timestamp, rows, chain check)
  restore_meensha.py --stamp 20261013T132116Z --region all          dry run, everything
  restore_meensha.py --stamp <stamp> --region india                 dry run, India only
  restore_meensha.py --stamp <stamp> --region australia --apply     really restore Australia
  restore_meensha.py --stamp <stamp> --region all --apply --storage also restore stored files

Regions: tables with a `region` column are filtered by it ('india' / 'australia'); tables whose
name ends in _au belong to australia; every other table (inventory, settings, ...) is SHARED and
is restored only with --region all.
Target project = the one linked in the supabase CLI (`supabase link --project-ref <ref>`); pass the same
--ref for the storage step. To restore into a NEW project, link that project first. Needs: supabase CLI logged in, gpg, macOS `security` (passphrase in Keychain).
"""
import argparse, json, os, subprocess, sys, tarfile, tempfile, urllib.parse, urllib.request

BACKUP_DIR = os.environ.get("MEENSHA_BACKUP_DIR", "/Users/dheerajbharti/Claude Projects/Meensha/backups/data")
KEYCHAIN_SERVICE = "meensha-backup"
CHUNK = 200


def passphrase():
    r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("Backup passphrase not found in the Keychain (service 'meensha-backup').")
    return r.stdout.strip()


def sql(ref, query):
    # Always targets the project currently linked in the supabase CLI: run
    # `supabase link --project-ref <ref>` for the target project first.
    out = subprocess.run(["supabase", "db", "query", "--linked", query], capture_output=True, text=True, timeout=300)
    if '"rows"' not in out.stdout:
        raise RuntimeError(out.stdout[-400:] + out.stderr[-400:])
    return out.stdout


def topo(tables, fks):
    deps = {t: set() for t in tables}
    for f in fks:
        c, p = f["child"].replace("public.", "").strip('"'), f["parent"].replace("public.", "").strip('"')
        if c in deps and p in deps and c != p:
            deps[c].add(p)
    order, done = [], set()
    while len(order) < len(tables):
        ready = [t for t in tables if t not in done and deps[t] <= done]
        if not ready:               # cycle: append the rest as-is
            ready = [t for t in tables if t not in done]
        for t in sorted(ready):
            order.append(t); done.add(t)
    return order


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--stamp")
    ap.add_argument("--region", choices=["india", "australia", "all"], default="all")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--storage", action="store_true")
    ap.add_argument("--ref", default="eglanmhhcccsuhbxywua")
    a = ap.parse_args()

    log = os.path.join(BACKUP_DIR, "BACKUP-LOG.jsonl")
    if a.list or not a.stamp:
        subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "backup_meensha.py"), "--verify"])
        return
    d = os.path.join(BACKUP_DIR, a.stamp)
    arch = os.path.join(d, f"meensha-backup-{a.stamp}.tar.gz.gpg")
    man = json.load(open(os.path.join(d, "MANIFEST.json")))
    import hashlib
    h = hashlib.sha256(open(arch, "rb").read()).hexdigest()
    if h != man["archive_sha256"]:
        sys.exit("ABORT: archive checksum does not match the manifest — backup was altered or corrupted.")
    print(f"Backup {a.stamp} ({man['created_ist']}): checksum OK")

    work = tempfile.mkdtemp(prefix="meensha-restore-")
    tarpath = os.path.join(work, "b.tar.gz")
    subprocess.run(["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase-fd", "0", "-d", "-o", tarpath, arch],
                   input=passphrase().encode(), check=True, capture_output=True)
    with tarfile.open(tarpath) as t:
        t.extractall(work)
    root = os.path.join(work, "meensha-backup")

    # verify every payload file against the manifest hashes
    for rel, want in man["payload_file_sha256"].items():
        got = hashlib.sha256(open(os.path.join(root, rel), "rb").read()).hexdigest()
        if got != want:
            sys.exit(f"ABORT: {rel} does not match its recorded hash.")
    print("All payload files match the manifest.")

    cols = json.load(open(os.path.join(root, "extras/columns.json")))
    fks = json.load(open(os.path.join(root, "extras/foreign_keys.json")))
    tables = [f[:-5] for f in os.listdir(os.path.join(root, "data"))]
    has_region = {c["table_name"] for c in cols if c["column_name"] == "region"}

    def pick(t, rows):
        if a.region == "all":
            return rows
        if t.endswith("_au"):
            return rows if a.region == "australia" else []
        if t in has_region:
            return [r for r in rows if r.get("region") == a.region]
        return []                      # shared table: only with --region all

    plan = []
    for t in topo(tables, fks):
        rows = pick(t, json.load(open(os.path.join(root, "data", f"{t}.json"))))
        if rows:
            plan.append((t, rows))
    print(f"\nPlan ({a.region}): " + ", ".join(f"{t}:{len(r)}" for t, r in plan))
    if not a.apply:
        print("\nDRY RUN — nothing written. Re-run with --apply to restore.")
        return

    for t, rows in plan:
        for i in range(0, len(rows), CHUNK):
            tag = "mrs" + os.urandom(4).hex()
            payload = json.dumps(rows[i:i + CHUNK])
            q = f'insert into public."{t}" select * from json_populate_recordset(null::public."{t}", ${tag}${payload}${tag}$::json) on conflict do nothing'
            sql(None, q)
        print(f"  restored {t}: {len(rows)} rows offered")

    if a.storage:
        o = subprocess.run(["supabase", "projects", "api-keys", "--project-ref", a.ref, "-o", "json"], capture_output=True, text=True).stdout
        key = [k["api_key"] for k in json.loads(o[o.index("["):o.rindex("]") + 1]) if k["name"] == "service_role"][0]
        for b in json.load(open(os.path.join(root, "extras/storage_buckets.json"))):
            req = urllib.request.Request(f"https://{a.ref}.supabase.co/storage/v1/bucket", method="POST",
                                         data=json.dumps({"id": b["id"], "name": b["name"], "public": b["public"]}).encode(),
                                         headers={"Authorization": f"Bearer {key}", "apikey": key, "Content-Type": "application/json"})
            try: urllib.request.urlopen(req, timeout=60)
            except Exception: pass     # already exists
        n = 0
        for o_ in json.load(open(os.path.join(root, "extras/storage_objects.json"))):
            p = os.path.join(root, "storage", o_["bucket_id"], o_["name"])
            if not os.path.exists(p): continue
            req = urllib.request.Request(f"https://{a.ref}.supabase.co/storage/v1/object/{o_['bucket_id']}/{urllib.parse.quote(o_['name'], safe='/')}",
                                         method="POST", data=open(p, "rb").read(),
                                         headers={"Authorization": f"Bearer {key}", "apikey": key, "x-upsert": "true"})
            urllib.request.urlopen(req, timeout=120); n += 1
        print(f"  restored {n} stored files")
    print("\nRESTORE COMPLETE. Now run the verification checklist in RESTORE.md (section 9).")


if __name__ == "__main__":
    main()
