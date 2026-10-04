# Curation Notes — read before adding any new document to this knowledge base

This knowledge base (`chatbot/kb/`) exists so an internal "how does this work" chatbot can
answer plain-language questions about Meensha's site and bots, scoped by who's asking
(`admin` = Dheeraj / super_admin, `owner` = Shalini & Meenakshi, `sales` = kiosk/POS staff).
It is a curated, human-reviewed copy of a few dozen project docs plus some newly-authored
system-map content — never a raw dump of the repo's `docs/` folder or the codebase itself.

## The one rule that matters most

**Explain the *why/what* of a security-relevant topic. Never the *exact mechanism*.**

Good (any tier, including `admin`):
> "Admin sessions expire and are checked on every request — an expired or invalid session
> gets sent back to the login screen, not silently treated as logged in."

Not good, even at `admin` tier:
- The literal password-hashing/token-hashing code.
- Literal RLS (Row-Level Security) policy SQL.
- The literal webhook-signature or shared-secret comparison code.
- Any real credential, API key, password, or token — even an old/rotated one, even in an
  example.
- Internal-network hostnames or IP addresses (self-hosted services, LAN addresses).
- Real customer or staff email addresses, phone numbers, or other personal data.

This boundary applies at **every tier, including `admin`**. Dheeraj having the fullest
access tier doesn't mean the chatbot should ever hand back literal exploitable mechanism
detail — if someone's session (or the escalation path to an external AI) were ever
compromised, the curated KB should not itself be the leak. "Shape of the system" is the
target altitude everywhere: what talks to what, in what order, what the user-visible
behavior is — not the literal code that enforces it.

## Practical checklist when adding or editing a KB doc

1. **Read the whole source document yourself** before copying anything in. Don't assume a
   doc is safe because an earlier version was, or because it looks similar to one already
   curated.
2. **Grep-check your own addition** before considering it done — see the red-flag list
   below. This is the same check that gets run across the whole `chatbot/kb/` directory
   before any deploy; do it on your new file too, not just at the end.
3. **Never copy a file known to contain live credentials** — `meensha_bots_creds.md`,
   `meensha-monitor-credentials.md`, `.gitea-credentials` — not even temporarily, not even
   to redact afterward. If useful non-sensitive content exists in a file like this, rewrite
   it fresh rather than copying and stripping.
4. **Default role placement to narrow.** Most "how the system works" content belongs in
   `admin/` and `owner/`. Only add something to `sales/` if it's directly relevant to
   day-to-day sales/kiosk work (e.g. how to apply a coupon during a kiosk sale) — add more
   to `sales/` later if something's missing, rather than over-including upfront.
5. **New system-map/architecture content (diagrams, flow docs) is `admin/`-only** unless a
   specific flow is also genuinely useful at `owner/sales` tier, in which case copy a
   trimmed version rather than moving the admin one.

## Red-flag grep list (run before every deploy, not just once)

Run this across the entire `chatbot/kb/` directory before any addition is considered done:

- `password`
- `BEGIN RSA` (or any PEM private-key header)
- `sk-` (API key prefix pattern)
- `token_hash`
- IP-address-looking patterns, e.g. `192\.168\.`, `10\.0\.`, or any other private/internal
  address
- Real email addresses (`@gmail.com`, `@meensha...`, etc.) that aren't obviously a generic
  placeholder like `you@example.com`

Anything that matches needs to be resolved — removed, redacted/genericized, or (rarely)
confirmed as a genuine false positive (a placeholder, not a real value) — before the
document is considered safe to serve.

## Why this matters

The chatbot's whole design assumes the curated KB is the trusted, reviewed boundary: local
answers come only from this folder, and even the optional "ask an external AI" escalation
path only ever gets a question plus an already-curated snippet, never raw files. If a
secret or literal security mechanism ends up in `chatbot/kb/`, that assumption breaks for
everyone who can see that tier — including, if it's ever sent to the external-AI escalation
path, in a form that leaves Dheeraj's own infrastructure. Curate accordingly.
