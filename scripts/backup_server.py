#!/usr/bin/env python3
"""Nightly Meensha backup, run on the home server (CT102 `meensha-backup`... runs in meensha-monitor).

Pulls everything (all public tables for BOTH regions, schema/policy/function/cron/bucket metadata,
every stored file) through the key-gated `backup-export` function, then encrypts the archive to
Dheeraj's PUBLIC key. The private key lives only on Dheeraj's Mac, so this server cannot read its own
backups. Each run is timestamped (UTC + IST), checksummed, and chained to the previous run
(BACKUP-LOG.jsonl, same format as scripts/backup_meensha.py), so edits or deletions are detectable.

  backup_server.py            run a backup, then verify the chain, then report to the Telegram Monitor
  backup_server.py --verify   verify chain + archive checksums only

Config: /etc/meensha-backup.env  (BACKUP_EXPORT_KEY, AGENT_REPORT_KEY, GPG_RECIPIENT)
Output: /srv/meensha-backups/<UTC stamp>/{meensha-backup-<stamp>.tar.gz.gpg, MANIFEST.json}
Restore: see RESTORE.md (scripts/restore_meensha.py on Dheeraj's Mac, after fetching the folder).
"""
import datetime, hashlib, json, os, shutil, socket, subprocess, sys, tarfile, tempfile, time, urllib.error, urllib.request

SB = "https://eglanmhhcccsuhbxywua.supabase.co"
BACKUP_DIR = os.environ.get("MEENSHA_BACKUP_DIR", "/srv/meensha-backups")
LOW_DISK_BYTES = 1_500_000_000
PAGE = 1000


def load_env():
    env = {}
    for line in open("/etc/meensha-backup.env"):
        if "=" in line and not line.startswith("#"):
            k, v = line.strip().split("=", 1); env[k] = v
    return env


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def sha256_str(s):
    return hashlib.sha256(s.encode()).hexdigest()


def post(url, headers, body, timeout=120, raw=False):
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=headers,
                                         method="POST" if body is not None else "GET")
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = r.read()
                return data if raw else json.loads(data)
        except Exception as e:
            last = e; time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"request failed after retries: {url.split('?')[0][-60:]} :: {last}")


def telegram(env, text):
    try:
        req = urllib.request.Request(f"{SB}/functions/v1/agent-report", method="POST",
                                     headers={"x-agent-key": env["AGENT_REPORT_KEY"], "Content-Type": "application/json"},
                                     data=json.dumps({"monitor_only": True, "text": text[:3500]}).encode())
        urllib.request.urlopen(req, timeout=30)
    except Exception:
        pass


def verify():
    log = os.path.join(BACKUP_DIR, "BACKUP-LOG.jsonl")
    if not os.path.exists(log):
        print("no log"); return False, "no backups yet", 0
    prev, ok, n, last = "GENESIS", True, 0, ""
    for line in open(log):
        if not line.strip(): continue
        e = json.loads(line); n += 1; last = e["stamp"]
        d = os.path.join(BACKUP_DIR, e["stamp"])
        arch = os.path.join(d, f"meensha-backup-{e['stamp']}.tar.gz.gpg"); man = os.path.join(d, "MANIFEST.json")
        probs = []
        if e["prev_entry_hash"] != prev: probs.append("chain broken")
        if e["entry_hash"] != sha256_str(prev + e["manifest_sha256"] + e["archive_sha256"] + e["created_utc"]): probs.append("entry hash mismatch")
        if not os.path.exists(arch) or sha256_file(arch) != e["archive_sha256"]: probs.append("archive missing/changed")
        if not os.path.exists(man) or sha256_file(man) != e["manifest_sha256"]: probs.append("manifest missing/changed")
        print(f"#{n} {e['stamp']} {'OK' if not probs else 'FAIL: ' + '; '.join(probs)}")
        ok &= not probs; prev = e["entry_hash"]
    print("CHAIN VALID" if ok else "CHAIN INVALID")
    return ok, last, n


def run_backup(env):
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    ist = now.astimezone(datetime.timezone(datetime.timedelta(hours=5, minutes=30))).isoformat(timespec="seconds")
    os.makedirs(BACKUP_DIR, mode=0o700, exist_ok=True)
    out_dir = os.path.join(BACKUP_DIR, stamp); os.makedirs(out_dir, mode=0o700)
    work = tempfile.mkdtemp(prefix="meensha-bk-", dir=BACKUP_DIR)
    H = {"x-backup-key": env["BACKUP_EXPORT_KEY"], "Content-Type": "application/json"}
    U = f"{SB}/functions/v1/backup-export"

    def put(rel, obj):
        p = os.path.join(work, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f: json.dump(obj, f, indent=1)

    tables = post(U, H, {"action": "tables"})["tables"]
    counts = {}
    for t in tables:
        rows, off = [], 0
        while True:
            chunk = post(U, H, {"action": "rows", "table": t, "offset": off, "limit": PAGE})["rows"]
            rows += chunk
            if len(chunk) < PAGE: break
            off += PAGE
        counts[t] = len(rows); put(f"data/{t}.json", rows)
    ex = post(U, H, {"action": "extras"})
    for k, v in ex.items(): put(f"extras/{k}.json", v)
    files = post(U, H, {"action": "storage"}, timeout=300)["files"]
    put("extras/storage_objects.json", [{"bucket_id": f["bucket_id"], "name": f["name"]} for f in files])
    missing = []
    for f in files:
        dest = os.path.join(work, "storage", f["bucket_id"], f["name"]); os.makedirs(os.path.dirname(dest), exist_ok=True)
        try:
            with open(dest, "wb") as fh: fh.write(post(f["url"], {}, None, raw=True))
        except Exception as e:
            missing.append(f"{f['bucket_id']}/{f['name']}")
    payload = {}
    for dp, _, fs in os.walk(work):
        for fn in fs:
            p = os.path.join(dp, fn); payload[os.path.relpath(p, work)] = sha256_file(p)
    tar_plain = os.path.join(BACKUP_DIR, f".tmp-{stamp}.tar.gz")
    with tarfile.open(tar_plain, "w:gz") as t: t.add(work, arcname="meensha-backup")
    arch = os.path.join(out_dir, f"meensha-backup-{stamp}.tar.gz.gpg")
    subprocess.run(["gpg", "--batch", "--yes", "--trust-model", "always", "-r", env["GPG_RECIPIENT"], "--encrypt", "-o", arch, tar_plain],
                   check=True, capture_output=True)
    os.remove(tar_plain); shutil.rmtree(work, ignore_errors=True)
    manifest = {"project_ref": "eglanmhhcccsuhbxywua", "created_utc": now.isoformat(timespec="seconds"), "created_ist": ist,
                "host": socket.gethostname(), "source": "backup_server.py via backup-export", "encryption": f"gpg public key {env['GPG_RECIPIENT'][-16:]}",
                "table_row_counts": counts, "storage_file_count": len(files), "storage_files_missing": missing,
                "payload_file_sha256": payload, "archive_file": os.path.basename(arch), "archive_sha256": sha256_file(arch)}
    mp = os.path.join(out_dir, "MANIFEST.json")
    with open(mp, "w") as f: json.dump(manifest, f, indent=1)
    log = os.path.join(BACKUP_DIR, "BACKUP-LOG.jsonl"); prev = "GENESIS"
    if os.path.exists(log):
        ls = [l for l in open(log) if l.strip()]
        if ls: prev = json.loads(ls[-1])["entry_hash"]
    ms, as_ = sha256_file(mp), manifest["archive_sha256"]
    entry = {"stamp": stamp, "created_utc": manifest["created_utc"], "created_ist": ist, "manifest_sha256": ms, "archive_sha256": as_,
             "prev_entry_hash": prev, "entry_hash": sha256_str(prev + ms + as_ + manifest["created_utc"]),
             "tables": len(counts), "rows": sum(counts.values()), "storage_files": len(files), "size_bytes": os.path.getsize(arch)}
    with open(log, "a") as f: f.write(json.dumps(entry) + "\n")
    for dp, _, fs in os.walk(BACKUP_DIR):
        os.chmod(dp, 0o700)
        for fn in fs: os.chmod(os.path.join(dp, fn), 0o600)
    return entry, missing


def main():
    if "--verify" in sys.argv:
        sys.exit(0 if verify()[0] else 2)
    env = load_env()
    try:
        entry, missing = run_backup(env)
        ok, last, n = verify()
        free = shutil.disk_usage(BACKUP_DIR).free
        msg = [f"BACKUP OK (home server) {entry['created_ist']}", f"{entry['tables']} tables, {entry['rows']} rows, {entry['storage_files']} files, {entry['size_bytes'] // 1024 // 1024} MB, encrypted",
               f"hash-chain: {'VALID' if ok else 'INVALID'} ({n} backups), entry {entry['entry_hash'][:12]}"]
        if missing: msg.append(f"WARNING: {len(missing)} stored file(s) could not be downloaded")
        if free < LOW_DISK_BYTES: msg.append(f"WARNING: only {free // 1024 // 1024} MB free on the backup disk")
        if not ok: msg.append("WARNING: hash chain check failed — a past backup may have been altered or lost")
        telegram(env, "\n".join(msg)); print("\n".join(msg))
    except Exception as e:
        telegram(env, f"BACKUP FAILED (home server): {str(e)[:300]}")
        print("FAILED:", e); sys.exit(1)


if __name__ == "__main__":
    main()
