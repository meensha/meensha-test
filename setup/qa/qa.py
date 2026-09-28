"""Meensha QA: public pages + customer flow, desktop and mobile.
Usage: qa.py <base_url> <label>   (base_url ends with /)
Writes screenshots + results.json to ./out/<label>/
"""
import json, os, sys, time
from playwright.sync_api import sync_playwright

BASE, LABEL = sys.argv[1], sys.argv[2]
OUT = os.path.join(os.path.dirname(__file__), 'out', LABEL)
os.makedirs(OUT, exist_ok=True)
SB = 'eglanmhhcccsuhbxywua.supabase.co'

VIEWPORTS = {
    'd1366': dict(viewport={'width': 1366, 'height': 900}),
    'm360': dict(viewport={'width': 360, 'height': 780}, is_mobile=True, has_touch=True, device_scale_factor=2,
                 user_agent='Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36'),
}

results = []


def watch(page, rec):
    page.on('console', lambda m: m.type == 'error' and rec['console'].append(m.text[:200]))
    page.on('pageerror', lambda e: rec['pageerrors'].append(str(e)[:200]))

    def on_resp(r):
        if SB in r.url and r.status >= 400:
            rec['sb_fail'].append(f'{r.status} {r.request.method} {r.url.split(SB)[1][:120]}')
        if SB in r.url and '/rest/v1/' in r.url:
            rec['sb_calls'].add(r.url.split('/rest/v1/')[1].split('?')[0])
    page.on('response', on_resp)


def new_rec(name, vp):
    return dict(page=name, vp=vp, console=[], pageerrors=[], sb_fail=[], sb_calls=set(), checks={}, notes=[])


def overflow(page):
    return page.evaluate('document.documentElement.scrollWidth - window.innerWidth')


def visit(ctx, vp, name, path, checks):
    rec = new_rec(name, vp)
    page = ctx.new_page()
    watch(page, rec)
    try:
        page.goto(BASE + path, wait_until='networkidle', timeout=45000)
        page.wait_for_timeout(1500)
        rec['checks']['h_overflow_px'] = overflow(page)
        for k, js in checks.items():
            try:
                rec['checks'][k] = page.evaluate(js)
            except Exception as e:
                rec['checks'][k] = f'ERR {e}'[:150]
        page.screenshot(path=f'{OUT}/{name}_{vp}.png', full_page=False)
    except Exception as e:
        rec['notes'].append(f'LOAD ERR {e}'[:200])
    page.close()
    results.append(rec)
    return rec


def customer_flow(ctx, vp, sku_id):
    rec = new_rec('customer_flow', vp)
    page = ctx.new_page()
    watch(page, rec)
    rpc = {}
    page.on('response', lambda r: '/rest/v1/rpc/' in r.url and rpc.setdefault(r.url.split('/rpc/')[1], []).append(r.status))
    c = rec['checks']
    try:
        page.goto(BASE + f'?buy={sku_id}', wait_until='networkidle', timeout=45000)
        page.wait_for_timeout(2500)
        c['cart_len_after_buy'] = page.evaluate('cart.length')
        c['cart_drawer_open'] = page.evaluate("document.getElementById('cart-drawer').classList.contains('on')")
        c['cart_items_rendered'] = page.evaluate("document.getElementById('cart-items').innerText.trim().length>0")
        unit = page.evaluate('cart[0] && cart[0].unitId')
        page.screenshot(path=f'{OUT}/flow1_cart_{vp}.png')
        # Coupon with a bogus code: RPC must answer, UI must reject politely.
        if page.locator('#cart-coupon-code').count():
            page.fill('#cart-coupon-code', 'QAFAKE123')
            if page.locator('#cart-coupon-wa').count():
                page.fill('#cart-coupon-wa', '9000000000')
            page.evaluate('typeof applyCoupon==="function" && applyCoupon()')
            page.wait_for_timeout(2000)
            c['coupon_msg'] = page.evaluate("(document.getElementById('cart-coupon-msg')||{}).innerText||''")[:100]
        # Razorpay: show contact form only; do NOT submit (would create a real payment link).
        page.evaluate('payViaRazorpay()')
        page.wait_for_timeout(500)
        c['contact_form_shown'] = page.evaluate("getComputedStyle(document.getElementById('cart-contact-form')).display!=='none'")
        page.screenshot(path=f'{OUT}/flow2_contact_{vp}.png')
        # Release the hold.
        if unit:
            page.evaluate(f"removeFromCart('{unit}')")
            page.wait_for_timeout(2000)
            c['cart_len_after_remove'] = page.evaluate('cart.length')
            st = page.evaluate(f"""fetch(`${{_SB}}/rest/v1/public_units?id=eq.{unit}&select=status`,{{headers:{{apikey:_SK,Authorization:'Bearer '+_SK}}}}).then(r=>r.json())""")
            c['unit_status_after_remove'] = st[0]['status'] if st else None
        # Customer login with bogus credentials: must fail cleanly.
        res = page.evaluate("spPostRPC('login_customer',{p_identifier:'qa-nobody@example.invalid',p_password:'wrong-pass-qa'})")
        c['bogus_login_result'] = str(res)[:120]
        # Wishlist/request form RPC reachable? (don't submit a real request)
        c['rpc_status'] = rpc
    except Exception as e:
        rec['notes'].append(f'FLOW ERR {e}'[:250])
    page.close()
    results.append(rec)


def invoice_checks(ctx, vp):
    rec = visit(ctx, vp, 'invoice_wrongwa', 'invoice.html?inv=MSH-1040&wa=9000000000',
                {'shows_not_found': "document.body.innerText.includes('Invoice not found')"})
    return rec


def admin_checks(ctx, vp):
    rec = new_rec('admin_login_screen', vp)
    page = ctx.new_page()
    watch(page, rec)
    try:
        page.goto(BASE + 'admin.html', wait_until='networkidle', timeout=45000)
        page.wait_for_timeout(1500)
        rec['checks']['h_overflow_px'] = overflow(page)
        rec['checks']['login_form_visible'] = page.evaluate("!!document.querySelector('input[type=password]') && document.querySelector('input[type=password]').offsetParent!==null")
        # Bogus login must be rejected, not crash.
        r = page.evaluate("fetch(`${SB}/rest/v1/rpc/login`,{method:'POST',headers:HDR(),body:JSON.stringify({p_username:'qa_nobody',p_password:'x'})}).then(async r=>r.status+' '+(await r.text()).slice(0,80))")
        rec['checks']['bogus_admin_login'] = r
        # Forgot password with unknown user: RPC returns null, nothing filed.
        r = page.evaluate("fetch(`${SB}/rest/v1/rpc/staff_forgot_password`,{method:'POST',headers:HDR(),body:JSON.stringify({p_username:'qa_nobody_'+Date.now(),p_note:'qa'})}).then(async r=>r.status+' '+(await r.text()).slice(0,80))")
        rec['checks']['forgot_pw_unknown'] = r
        r = page.evaluate("fetch(`${SB}/rest/v1/rpc/has_admin_session`,{method:'POST',headers:AHDR(),body:'{}'}).then(async r=>r.status+' '+(await r.text()))")
        rec['checks']['has_admin_session_anon'] = r
        page.screenshot(path=f'{OUT}/admin_login_{vp}.png')
    except Exception as e:
        rec['notes'].append(f'ADMIN ERR {e}'[:200])
    page.close()
    results.append(rec)


GRID = "document.querySelectorAll('#sp-grid .sp-card, #sp-grid > *').length"
WVGRID = "document.querySelectorAll('#wv-grid > *').length"

with sync_playwright() as p:
    b = p.chromium.launch()
    sku_id = None
    for vp, opts in VIEWPORTS.items():
        ctx = b.new_context(**opts)
        r = visit(ctx, vp, 'home', '', {
            'skus_loaded': 'spSkus.length', 'units_loaded': 'spUnits.length',
            'skus_have_no_cost': "spSkus.every(s=>!('cost' in s))",
            'available_skus': 'spSkus.filter(s=>s.avail>0).length',
            'h1_count': "document.querySelectorAll('h1').length",
            'ticker_or_settings': "typeof waIn!=='undefined' ? !!waIn : 'n/a'",
        })
        visit(ctx, vp, 'shop_search', '?shop=Kalamkari', {
            'shop_visible': "getComputedStyle(document.getElementById('shop-page')).display!=='none'",
            'grid_items': GRID, 'title': 'document.title', 'canonical': "document.querySelector('link[rel=canonical]').href"})
        visit(ctx, vp, 'sarees_index', 'sarees/', {'links': "document.querySelectorAll('a[href*=\"/sarees/\"]').length"})
        visit(ctx, vp, 'weave_kalamkari', 'sarees/kalamkari/', {'grid_items': WVGRID, 'h1': "document.querySelector('h1').innerText"})
        visit(ctx, vp, 'weave_ajrakh', 'sarees/ajrakh/', {'grid_items': WVGRID})
        if sku_id is None:
            pg = ctx.new_page(); pg.goto(BASE, wait_until='networkidle', timeout=45000); pg.wait_for_timeout(1500)
            sku_id = pg.evaluate('(spSkus.find(s=>s.avail>0)||{}).id'); pg.close()
        visit(ctx, vp, 'product', f'product.html?id={sku_id}', {
            'name_shown': "document.getElementById('pd-root').innerText.length>50",
            'has_product_schema': "[...document.querySelectorAll('script[type=\"application/ld+json\"]')].some(s=>s.textContent.includes('\"Product\"'))",
            'add_to_cart_link': "!!document.querySelector('a[href*=\"buy=\"]')"})
        visit(ctx, vp, 'about', 'about.html', {'len': 'document.body.innerText.length'})
        visit(ctx, vp, 'register', 'register.html', {'len': 'document.body.innerText.length'})
        visit(ctx, vp, 'event_photos', 'event-photos.html', {'len': 'document.body.innerText.length'})
        invoice_checks(ctx, vp)
        admin_checks(ctx, vp)
        customer_flow(ctx, vp, sku_id)
        ctx.close()
    b.close()

for r in results:
    r['sb_calls'] = sorted(r['sb_calls'])
json.dump(results, open(f'{OUT}/results.json', 'w'), indent=1, default=str)
print(json.dumps(results, indent=1, default=str))
