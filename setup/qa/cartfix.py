"""Mobile cart regression check: expiry nudge hidden while the drawer is open,
coupon row inside the drawer. Usage: cartfix.py <base_url> <label>"""
import os, sys
from playwright.sync_api import sync_playwright
BASE=sys.argv[1]; OUT=os.path.join(os.path.dirname(os.path.abspath(__file__)),'out','cartfix_'+sys.argv[2])
os.makedirs(OUT,exist_ok=True)
VPS={'m360':dict(viewport={'width':360,'height':780},is_mobile=True,has_touch=True,device_scale_factor=2),
     'm390':dict(viewport={'width':390,'height':844},is_mobile=True,has_touch=True,device_scale_factor=2),
     'd1366':dict(viewport={'width':1366,'height':900})}
NOTICE="getComputedStyle(document.getElementById('cart-expiry-notice')).opacity"
EDGES="""(()=>{const d=document.getElementById('cart-drawer').getBoundingClientRect();
 return ['cart-coupon-code','cart-coupon-wa'].map(id=>{const r=document.getElementById(id).getBoundingClientRect();
 return {id,inside:r.left>=d.left-1&&r.right<=d.right+1,top:Math.round(r.top),w:Math.round(r.width)}})})()"""
with sync_playwright() as p:
    b=p.chromium.launch()
    for vp,o in VPS.items():
        pg=b.new_page(**o); errs=[]; pg.on('pageerror',lambda e:errs.append(str(e)))
        pg.goto(BASE+'index.html',wait_until='networkidle'); pg.wait_for_timeout(1500)
        sku=pg.evaluate('(spSkus.find(s=>s.avail>0)||{}).id')
        pg.goto(BASE+'index.html?buy='+sku,wait_until='networkidle'); pg.wait_for_timeout(2500)
        r={'cart':pg.evaluate('cart.length'),'notice_while_open':pg.evaluate(NOTICE),'coupon':pg.evaluate(EDGES)}
        pg.screenshot(path=f'{OUT}/open_{vp}.png')
        pg.evaluate('closeCart()'); pg.wait_for_timeout(1500)
        r['notice_after_close']=pg.evaluate(NOTICE); pg.screenshot(path=f'{OUT}/closed_{vp}.png')
        pg.wait_for_timeout(11000); r['notice_after_11s']=pg.evaluate(NOTICE)
        u=pg.evaluate('cart[0]&&cart[0].unitId')
        if u: pg.evaluate(f"removeFromCart('{u}')"); pg.wait_for_timeout(1500)
        r['released']=pg.evaluate('cart.length')==0; r['errors']=errs
        print(vp,r); pg.close()
    b.close()
