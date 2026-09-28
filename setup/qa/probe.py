"""List every table/view exposed to the anon key and whether anon can read it.
Uses limit=0 + count=exact, so only row counts are fetched, never row data."""
import json, os, re, sys, urllib.request

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'index.html')
SB = 'https://eglanmhhcccsuhbxywua.supabase.co'
KEY = re.search(r"_SK='([^']+)'", open(SRC).read()).group(1)
H = {'apikey': KEY, 'Authorization': 'Bearer ' + KEY}


def req(url, headers=None):
    r = urllib.request.Request(url, headers={**H, **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


# anon can't read the OpenAPI schema, so the list comes from the repo's CREATE TABLEs.
paths = '''admin_sessions app_secrets auth_log bot_activity_log bot_message_log bot_notes coupons customer_otp
customer_sessions customers email_reset_tokens event_photo_submissions instagram_posts inventory
inventory_returns_pending inventory_skus inventory_units orders overheads page_views password_reset_requests
popups purchases recovery_codes requests reviews sales sales_return_log settings sku_vendor_batches
stock_intake_drafts telegram_allowed_users telegram_allowed_users_au telegram_sessions telegram_sessions_au
user_credentials users vendor_audit_log vendor_edit_requests vendor_issues vendors voucher_events
public_skus public_units'''.split()
readable = {}
for t in paths:
    st, hd, _ = req(f'{SB}/rest/v1/{t}?limit=0', {'Prefer': 'count=exact'})
    cr = hd.get('Content-Range') or hd.get('content-range') or ''
    n = cr.split('/')[-1] if st < 300 else None
    readable[t] = n
    print(f'{t:32} status={st} rows_visible_to_anon={n}')
st, _, b = req(f'{SB}/rest/v1/inventory_skus?select=cost&limit=1')
print('\ninventory_skus.cost readable:', st < 300 and b not in (b'[]',), f'(status {st})')
