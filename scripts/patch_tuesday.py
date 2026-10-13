#!/usr/bin/env python3
"""PATCH TUESDAY — weekly security + regression check for Meensha. Runs on the home server (CT102).

Looks at Meensha the way an outsider does (no privileged credentials on the server):
  1. Site health: HTTP->HTTPS redirect, homepage, title/H1, every sitemap URL, TLS certificate expiry.
  2. Public exposure: every internal file tracked in the public repo (docs, SQL, scripts, server code)
     must NOT be downloadable from meensha.in.
  3. Secrets in the public repo + full git history (key patterns, bot tokens, service-role JWTs,
     credential tables). Reports file + kind only, never values.
  4. Database exposure with only the public anon key: which tables/views are readable anonymously,
     sensitive column names, and the purchase-cost column.
  5. Reporting endpoint is locked (agent-report must answer 401 without the key).
Writes <REPORT_DIR>/<date>/report.json + report.txt, compares with last run (new / resolved), and sends
a summary to the Telegram Monitor only (via agent-report, key in /etc/patch-tuesday.env).
Fixes are NOT applied here: this host only detects and reports. Fixes happen in an approved session.

  patch_tuesday.py              full run
  patch_tuesday.py --if-missing run only if today's report does not exist (the watchdog timer uses this)
"""
import base64, datetime, json, os, re, shutil, socket, ssl, subprocess, sys, tempfile, urllib.error, urllib.request

SITE = "https://meensha.in"
REPO = "https://github.com/meensha/meensha-test.git"
REF = "eglanmhhcccsuhbxywua"
SB = f"https://{REF}.supabase.co"
REPORT_DIR = os.environ.get("PATCH_REPORT_DIR", "/opt/patch-tuesday/reports")
ALLOWED_PUBLIC = {"docs/MEDIUM_POST_02_draft.md", "docs/ARTISANS_BLOG_DRAFT_01.md"}   # admin.html fetches these
INTERNAL_PREFIXES = ("docs/", "setup/", "supabase/", "scripts/", "chatbot/kb/", "chatbot/server/")
INTERNAL_ROOT = ("TODO.md", "RESTORE.md", "README.md", "STAGING_SEPARATION_PROPOSAL.md", "IDEA.md")
SENSITIVE_COLS = re.compile(r"(cost|password|passwd|hash|secret|token|wa$|phone|email|address|aadhaar|pan)", re.I)
SECRET_PATTERNS = {
    "telegram bot token": re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b"),
    "private key block": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "razorpay live key": re.compile(r"\brzp_live_[A-Za-z0-9]{10,}\b"),
    "resend key": re.compile(r"\bre_[A-Za-z0-9]{20,}\b"),
    "jwt": re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
    "credentials table (Username|Password)": re.compile(r"^\|?\s*Username\s*\|\s*Password", re.I | re.M),
}
findings = []


def add(sev, title, detail="", known=False):
    findings.append({"severity": sev, "title": title, "detail": detail, "known": known})


def http(url, method="GET", headers=None, data=None, timeout=20):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read() if e.fp else b"", dict(e.headers or {})
    except Exception as e:
        return 0, str(e).encode(), {}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def status_no_redirect(url):
    op = urllib.request.build_opener(NoRedirect)
    try:
        return op.open(url, timeout=20).status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def check_site():
    s = status_no_redirect("http://meensha.in")
    if s != 301:
        add("high", "HTTP does not redirect to HTTPS", f"http://meensha.in returned {s}")
    c, body, _ = http(SITE + "/")
    html = body.decode("utf-8", "ignore")
    if c != 200:
        add("high", "Homepage not reachable", f"status {c}")
    h1s = len(re.findall(r"<h1[\s>]", html))
    if h1s != 1:
        add("low", "Homepage should have exactly one H1", f"found {h1s}")
    c, body, _ = http(SITE + "/sitemap.xml")
    urls = re.findall(r"<loc>([^<]+)</loc>", body.decode("utf-8", "ignore")) if c == 200 else []
    if not urls:
        add("high", "sitemap.xml missing or empty", f"status {c}")
    bad = [u for u in urls if http(u)[0] != 200]
    if bad:
        add("medium", f"{len(bad)} sitemap URL(s) not returning 200", ", ".join(bad[:5]))
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection(("meensha.in", 443), timeout=15) as sock, ctx.wrap_socket(sock, server_hostname="meensha.in") as ss:
            exp = datetime.datetime.strptime(ss.getpeercert()["notAfter"], "%b %d %H:%M:%S %Y %Z")
        days = (exp - datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)).days
        if days < 14: add("high", "TLS certificate expires soon", f"{days} days left")
        elif days < 30: add("medium", "TLS certificate renewal due", f"{days} days left")
    except Exception as e:
        add("medium", "Could not check TLS certificate", str(e)[:120])
    return len(urls)


def clone_repo(full):
    d = tempfile.mkdtemp(prefix="pt-repo-")
    cmd = ["git", "clone", "-q", REPO, d] if full else ["git", "clone", "-q", "--depth", "1", REPO, d]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        add("medium", "Could not clone public repo for scanning", r.stderr[-150:])
        return None
    return d


def check_public_exposure(d):
    files = subprocess.run(["git", "-C", d, "ls-files"], capture_output=True, text=True).stdout.splitlines()
    internal = [f for f in files if (f.startswith(INTERNAL_PREFIXES) or f in INTERNAL_ROOT) and f not in ALLOWED_PUBLIC]
    exposed = []
    for f in internal:
        url = SITE + "/" + "/".join(urllib.request.quote(p) for p in f.split("/"))
        if http(url, timeout=15)[0] == 200:
            exposed.append(f)
    if exposed:
        add("critical", f"{len(exposed)} internal file(s) publicly downloadable from the website",
            ", ".join(exposed[:12]) + (" ..." if len(exposed) > 12 else ""))
    return len(internal)


def check_secrets(d):
    log = subprocess.run(["git", "-C", d, "log", "-p", "--all", "--no-color", "-U0"], capture_output=True, text=True, errors="ignore", timeout=600).stdout
    cur = None; hits = {}
    for line in log.splitlines():
        if line.startswith("+++ b/"):
            cur = line[6:]; continue
        if not line.startswith("+") or line.startswith("+++"):
            continue
        body = line[1:]
        for kind, rx in SECRET_PATTERNS.items():
            m = rx.search(body)
            if not m:
                continue
            if kind == "jwt":
                try:
                    pay = m.group(0).split(".")[1]; pay += "=" * (-len(pay) % 4)
                    role = json.loads(base64.urlsafe_b64decode(pay)).get("role")
                except Exception:
                    role = "?"
                if role == "anon":
                    continue            # the public anon key is meant to be public
                kind = f"jwt role={role}"
            hits.setdefault((kind, cur), 0); hits[(kind, cur)] += 1
    for (kind, path), n in sorted(hits.items(), key=lambda x: str(x)):
        sev = "critical" if ("service_role" in kind or "private key" in kind or "bot token" in kind or "live key" in kind) else "high"
        known = kind.startswith("credentials table")
        add(sev, f"Secret-like content in public git history: {kind}", f"{path} ({n} line(s)) — values not shown", known=known)


def anon_key():
    c, body, _ = http(SITE + "/index.html")
    for m in re.finditer(r"eyJ[A-Za-z0-9_-]{10,}\.([A-Za-z0-9_-]{10,})\.[A-Za-z0-9_-]{10,}", body.decode("utf-8", "ignore")):
        pay = m.group(1) + "=" * (-len(m.group(1)) % 4)
        try:
            if json.loads(base64.urlsafe_b64decode(pay)).get("role") == "anon":
                return m.group(0)
        except Exception:
            pass
    return None


def repo_object_names(d):
    names = set()
    if not d:
        return names
    rx = re.compile(r"create\s+(?:or\s+replace\s+)?(?:table|view)\s+(?:if\s+not\s+exists\s+)?(?:public\.)?\"?([a-z_][a-z0-9_]*)\"?", re.I)
    for sub in ("setup", "supabase/migrations"):
        base = os.path.join(d, sub)
        for root, _, fs in os.walk(base):
            for f in fs:
                if f.endswith(".sql"):
                    names.update(m.group(1) for m in rx.finditer(open(os.path.join(root, f), errors="ignore").read()))
    return names


def check_anon_exposure(d=None):
    key = anon_key()
    if not key:
        add("info", "Could not locate the public anon key in index.html (skipped database exposure checks)")
        return 0
    H = {"apikey": key, "Authorization": f"Bearer {key}"}
    c, body, _ = http(SB + "/rest/v1/", headers=H)
    if c != 200:
        add("info", "Anonymous REST schema listing is closed", f"status {c}"); spec = {}
    else:
        spec = json.loads(body or b"{}")
    tables = [p.strip("/") for p in spec.get("paths", {}) if p.count("/") == 1 and p != "/"]
    if not tables:
        tables = sorted(repo_object_names(d))   # schema listing closed: probe the names the public repo declares
    readable = []
    for t in tables:
        c, body, _ = http(f"{SB}/rest/v1/{t}?select=*&limit=1", headers=H, timeout=20)
        if c == 200:
            try:
                rows = json.loads(body)
            except Exception:
                rows = []
            cols = sorted(rows[0].keys()) if rows else []
            readable.append((t, cols, bool(rows)))
    for t, cols, has_rows in readable:
        sens = [c for c in cols if SENSITIVE_COLS.search(c)]
        if sens:
            add("critical", f"Anonymous users can read sensitive-looking column(s) of '{t}'", ", ".join(sens))
        elif has_rows:
            add("info", f"'{t}' is readable anonymously ({len(cols)} columns)")
    c, body, _ = http(f"{SB}/rest/v1/settings?select=key", headers=H)
    if c == 200:
        try:
            names = [x["key"] for x in json.loads(body)]
        except Exception:
            names = []
        bad = [n for n in names if re.search(r"(key|token|secret|pass)", n, re.I)]
        if bad:
            add("critical", "Anonymous users can read secret-looking settings", ", ".join(bad))
    c, body, _ = http(f"{SB}/rest/v1/inventory_skus?select=cost&limit=1", headers=H)
    if c == 200 and body not in (b"[]", b""):
        add("critical", "Anonymous users can read purchase cost (inventory_skus.cost)", "")
    return len(tables)


def check_agent_report():
    c, _, _ = http(f"{SB}/functions/v1/agent-report", method="POST", data=b"{}", headers={"Content-Type": "application/json"})
    if c != 401:
        add("high", "agent-report endpoint is not locked", f"unauthenticated call returned {c}, expected 401")


def load_key():
    try:
        for line in open("/etc/patch-tuesday.env"):
            if line.startswith("AGENT_REPORT_KEY="):
                return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return None


def telegram(text):
    key = load_key()
    if not key:
        return False
    c, _, _ = http(f"{SB}/functions/v1/agent-report", method="POST",
                   headers={"x-agent-key": key, "Content-Type": "application/json"},
                   data=json.dumps({"monitor_only": True, "text": text[:3800]}).encode())
    return c == 200


def check_inside():
    """Read-only inside view via the key-gated patch-audit function. Returns the AI triage text."""
    key = load_key()
    if not key:
        add("info", "Inside checks skipped (no key on this host)"); return ""
    c, body, _ = http(f"{SB}/functions/v1/patch-audit", method="POST", headers={"x-agent-key": key}, timeout=150)
    if c != 200:
        add("medium", "Inside checks (patch-audit) failed to run", f"status {c}"); return ""
    d = json.loads(body)
    for t in d["rls_off"]:
        add("high" if t["anon_priv"] else "low", f"Table '{t['t']}' has row-level security OFF", "anonymous role has privileges" if t["anon_priv"] else "no anonymous privileges")
    for p in d["open_policies"]:
        writes = p["cmd"] in ("INSERT", "UPDATE", "DELETE", "ALL")
        if writes and p["t"] != "page_views":
            add("high", f"Open write policy on '{p['t']}' ({p['cmd']})", f"{p['p']} for {p['roles']}")
        else:
            add("info", f"Wide-open policy on '{p['t']}' ({p['cmd']})", f"{p['p']} for {p['roles']} (expected for public read / page-view logging)")
    add("info", f"{len(d['anon_secdef'])} SECURITY DEFINER functions are callable anonymously (review each is meant to be public)", ", ".join(x["f"] for x in d["anon_secdef"])[:300])
    for j in d["cron"]:
        if not j["active"]:
            add("medium", f"Cron job '{j['jobname']}' is inactive")
        elif j["failed_7d"]:
            add("medium", f"Cron job '{j['jobname']}' failed {j['failed_7d']}x in 7 days")
        elif j["last_status"] not in ("succeeded", None):
            add("medium", f"Cron job '{j['jobname']}' last status: {j['last_status']}")
    for b in d["buckets"]:
        if b["id"] == "invoices" and b["public"]:
            add("critical", "Storage bucket 'invoices' is PUBLIC")
    pub = [b["id"] for b in d["buckets"] if b["public"]]
    add("info", f"{len(pub)} public storage buckets", ", ".join(pub))
    if d["secret_settings"]:
        add("medium", "API keys are stored as plain rows in the settings table (protected only by row-level security)",
            ", ".join(x["key"] for x in d["secret_settings"]) + " — safer as Supabase secrets", known=True)
    if int(d["stuck_sessions"] or 0):
        add("low", f"{d['stuck_sessions']} bot conversation(s) stuck open for 45+ minutes (auto-close not working?)")
    for b in d["bots"]:
        try:
            last = datetime.datetime.fromisoformat(str(b["last_msg"]).replace("Z", "+00:00"))
            if (datetime.datetime.now(datetime.timezone.utc) - last).days > 14:
                add("info", f"Bot '{b['bot']}' has had no messages for {(datetime.datetime.now(datetime.timezone.utc) - last).days} days")
        except Exception:
            pass
    return d.get("triage", "")


def main():
    today = datetime.date.today().isoformat()
    out = os.path.join(REPORT_DIR, today)
    if "--if-missing" in sys.argv and os.path.exists(os.path.join(out, "report.json")):
        print("today's report exists; nothing to do"); return
    os.makedirs(out, exist_ok=True)
    n_urls = check_site()
    d_shallow = clone_repo(False)
    n_internal = check_public_exposure(d_shallow) if d_shallow else 0
    d_full = clone_repo(True)
    if d_full: check_secrets(d_full)
    n_tables = check_anon_exposure(d_shallow)
    check_agent_report()
    triage = check_inside()
    for d in (d_shallow, d_full):
        if d: shutil.rmtree(d, ignore_errors=True)

    prev = None
    for name in sorted(os.listdir(REPORT_DIR), reverse=True):
        p = os.path.join(REPORT_DIR, name, "report.json")
        if name < today and os.path.exists(p):
            prev = json.load(open(p)); break
    key = lambda f: (f["severity"], f["title"], f["detail"])
    prev_keys = {key(f) for f in prev["findings"]} if prev else set()
    cur_keys = {key(f) for f in findings}
    new = [f for f in findings if key(f) not in prev_keys] if prev else []
    resolved = [f for f in (prev["findings"] if prev else []) if key(f) not in cur_keys]
    order = ["critical", "high", "medium", "low", "info"]
    findings.sort(key=lambda f: order.index(f["severity"]))
    counts = {s: sum(1 for f in findings if f["severity"] == s) for s in order}
    report = {"date": today, "host": socket.gethostname(), "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
              "scope": {"sitemap_urls": n_urls, "internal_files_probed": n_internal, "anon_tables_probed": n_tables},
              "counts": counts, "triage": triage, "findings": findings, "new_since_last": len(new), "resolved_since_last": len(resolved)}
    json.dump(report, open(os.path.join(out, "report.json"), "w"), indent=1)

    lines = [f"PATCH TUESDAY {today} (home server)", f"critical {counts['critical']} | high {counts['high']} | medium {counts['medium']} | low {counts['low']} | info {counts['info']}"]
    if prev: lines.append(f"since last run: {len(new)} new, {len(resolved)} resolved")
    for f in findings:
        if f["severity"] in ("critical", "high", "medium", "low"):
            lines.append(f"- [{f['severity'].upper()}]{' (known, open)' if f['known'] else ''} {f['title']}" + (f": {f['detail']}" if f["detail"] else ""))
    if counts["critical"] + counts["high"] + counts["medium"] + counts["low"] == 0:
        lines.append("All clear: site, public exposure, repo secrets, anonymous database access and report endpoint checks passed.")
    if triage:
        lines.append("AI triage (unverified suggestion):\n" + triage)
    lines.append(f"Scope: {n_urls} sitemap URLs, {n_internal} internal files probed, {n_tables} DB objects probed anonymously. Detect-and-report only; fixes need approval.")
    text = "\n".join(lines)
    open(os.path.join(out, "report.txt"), "w").write(text + "\n")
    print(text)
    print("telegram:", "sent" if telegram(text) else "NOT sent (check /etc/patch-tuesday.env)")


if __name__ == "__main__":
    main()
