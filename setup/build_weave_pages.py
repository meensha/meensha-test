#!/usr/bin/env python3
"""Generate the static /sarees/<slug>/ landing pages and sitemap.xml.

Run from the repo root after editing WEAVES below:
    python3 setup/build_weave_pages.py

Why static pages: the old ?shop=<term> URLs served the homepage's HTML
(same title, same canonical, same body) to every crawler, with only JS
changing them afterwards — Google kept them "Discovered, not indexed".
Each page here has its own server-rendered title/H1/canonical/copy; the
product grid is still live from Supabase via sarees/weave.js.
"""
import datetime
import html
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = "https://meensha.in"

# slug, display name, search term (same substring match as ?shop=), copy.
# Copy describes the craft tradition; per-piece material is always shown
# on the product itself, since not every listed piece is handwoven.
WEAVES = [
    ("ajrakh", "Ajrakh", "Ajrakh", "Kutch, Gujarat and Sindh", [
        "Ajrakh is a resist block-printing tradition from Kutch in Gujarat and neighbouring Sindh, practised for centuries by Khatri families in villages such as Ajrakhpur and Dhamadka.",
        "The cloth passes through a long sequence of washing, mordanting, resist-printing and dyeing, traditionally with natural indigo and madder-based reds. Because both sides are printed, the pattern shows crisply on the reverse too.",
        "Look for deep indigo and crimson grounds, geometric stars and trefoils, and the slight irregularity that only hand-carved wooden blocks leave. Hand-wash separately in cold water the first few times; natural dyes soften, they don't fade out.",
    ]),
    ("bandhani", "Bandhani", "Bandhani", "Gujarat and Rajasthan", [
        "Bandhani (from bandhan, to tie) is the tie-dye art of Gujarat and Rajasthan. Artisans pinch tiny points of cloth and bind each with thread before dyeing, so every dot in the pattern was tied by hand.",
        "Finer work means smaller dots packed closer together; a single saree can carry thousands of knots. Traditional motifs include dots (bindi), waves and the chandrakala moon.",
        "Genuine Bandhani has a faint crinkle where the knots sat and dots that are never perfectly uniform. Dry-clean or gently hand-wash in cold water, and dry in shade.",
    ]),
    ("batik", "Batik", "Batik", "Bhagalpur, Bihar and West Bengal", [
        "Batik is a wax-resist technique: molten wax is drawn or stamped onto cloth, the cloth is dyed, and the waxed areas stay undyed. Repeating the process layers colour upon colour.",
        "In India the craft is associated with Santiniketan in West Bengal and with the weaving towns of Bihar such as Bhagalpur, where it is often worked on cotton and silk.",
        "The signature of hand batik is fine veining where dye seeps through cracks in the wax. Printed imitations lack it. Wash gently in cold water with mild detergent.",
    ]),
    ("chiffon", "Chiffon", "Chiffon", "", [
        "Chiffon is a light, sheer fabric woven from tightly twisted yarns, giving it a soft, slightly rough hand and a floating drape. It is made in silk and in synthetic fibres.",
        "Chiffon sarees are easy to carry all day and pleat beautifully, which is why they suit embellishments such as gota patti, sequins and light prints.",
        "Check each listing for the exact fibre. Dry-clean embellished pieces; store folded in muslin, away from sharp jewellery that can snag the weave.",
    ]),
    ("dola-silk", "Dola Silk", "Dola", "", [
        "Dola silk is a soft, lightweight silk-blend fabric with a gentle sheen, widely used for printed, embroidered and zari-accented sarees.",
        "It drapes more fluidly than heavier silks and is comfortable for long functions, making it a favourite for festive and wedding-guest wear.",
        "Dry-clean to keep the sheen and any zari work bright; iron on low heat with a cloth between iron and saree.",
    ]),
    ("georgette", "Georgette", "Georgette", "", [
        "Georgette is a crinkled, crepe-like fabric woven from highly twisted yarns. It is heavier and more opaque than chiffon but just as flowing.",
        "In Varanasi, handloom georgette (Khaddi georgette) is woven on pit looms and is the base for many Banarasi sarees; elsewhere georgette is made in silk or synthetic fibres.",
        "Georgette resists creasing and holds pleats well. Dry-clean embellished pieces and store folded, not hung, so the fabric doesn't stretch.",
    ]),
    ("kalamkari", "Kalamkari", "Kalamkari", "Andhra Pradesh", [
        "Kalamkari means 'pen-work'. The tradition comes from Andhra Pradesh in two styles: Srikalahasti, where motifs are drawn freehand with a bamboo kalam, and Machilipatnam (Pedana), where they are block-printed.",
        "Both use natural dyes fixed with mordants through many rounds of painting, washing and sun-drying. Srikalahasti work often tells stories from the epics; Machilipatnam favours floral and Persian-influenced motifs.",
        "Hand-drawn Kalamkari shows slight variation in line weight and fine black outlines. Natural dyes mellow with washing: hand-wash in cold water, and keep out of harsh sunlight.",
    ]),
    ("katan", "Katan", "Katan", "Varanasi and Bihar", [
        "Katan is a weave built on twisted yarn. In Varanasi, Katan silk (pure silk with twisted filament threads) is the classic base for Banarasi sarees; weaving centres in Bihar work the same idea in cotton and blends.",
        "The twist gives the fabric strength and a firm, smooth drape, and holds woven motifs and borders well.",
        "Check each listing for fibre. Dry-clean silk Katan; cotton Katan can be gently hand-washed in cold water.",
    ]),
    ("khaddi-georgette", "Khaddi Georgette", "Khaddi", "Varanasi, Uttar Pradesh", [
        "Khaddi is the pit loom of Varanasi, and Khaddi georgette is the handloom georgette woven on it: a richer, heavier fabric than machine-made georgette.",
        "It is the base for many Banarasi sarees, prized for its drape and its ability to carry fine weaving, zari and hand embellishment.",
        "Handloom khaddi feels denser and has tiny irregularities in the weave. Dry-clean only, and store wrapped in muslin.",
    ]),
    ("kota-doria", "Kota Doria", "Kota", "Kota, Rajasthan", [
        "Kota Doria is woven around Kota in Rajasthan. Its signature is the khat, a small square check formed by combining cotton and silk yarns, which makes the fabric almost weightless and airy.",
        "It is among the lightest handloom sarees in India and ideal for hot weather; it carries prints such as Ajrakh and zari borders well.",
        "Hold it to the light to see the square checks. Kota Doria is protected by a Geographical Indication. Hand-wash gently or dry-clean, and starch lightly to keep its crisp fall.",
    ]),
    ("madhubani", "Madhubani", "Madhubani", "Mithila, Bihar", [
        "Madhubani (Mithila) art comes from the Mithila region of Bihar, a painting tradition historically made by women on walls and floors for festivals and weddings.",
        "Its motifs (fish, peacocks, lotuses, deities and the Kohbar wedding scene) are drawn with bold outlines and filled with bright colour or fine line-work. Today artists paint them onto tussar and other silks.",
        "Hand-painted pieces show brush texture and small variations between repeats. Dry-clean only; never wring or soak a painted saree.",
    ]),
    ("mangalgiri", "Mangalgiri", "Mangalgiri", "Mangalagiri, Andhra Pradesh", [
        "Mangalgiri handlooms come from Mangalagiri near Guntur in Andhra Pradesh. They are known for fine, crisp cotton with a plain body and a zari border, often the Nizam-style border, with no motifs woven into the body.",
        "The fabric is breathable and holds its structure, which makes it a practical everyday and office saree. Mangalagiri sarees and fabrics are protected by a Geographical Indication.",
        "Hand-wash in cold water and dry in shade; a light starch restores the crisp finish.",
    ]),
    ("modal-silk", "Modal Silk", "Modal", "", [
        "Modal is a soft semi-synthetic fibre made from wood cellulose. Modal silk sarees blend it with silk for a smooth, cool fabric with a subtle sheen.",
        "It takes dye evenly and is a popular base for Ajrakh prints, Bandhani and mirror work, giving the look of silk with easier care and lighter weight.",
        "Gentle hand-wash or dry-clean; avoid wringing, and iron on low heat.",
    ]),
    ("mothra", "Mothra", "Mothra", "Rajasthan", [
        "Mothra (also Mothda) is a Rajasthani resist-dyeing pattern related to Leheriya. Cloth is rolled, tied and dyed along two diagonals, so the crossing lines leave small undyed diamonds said to resemble moth (lentil) grains.",
        "Mothra is associated with festivals and the monsoon, and is often finished with gota patti borders.",
        "Look for crisp diagonal cross-lines and slight variation in the diamonds, a sign of hand-tying. Dry-clean or gently hand-wash in cold water.",
    ]),
    ("muga-silk", "Muga Silk", "Muga", "Assam", [
        "Muga silk comes only from Assam, spun from the cocoons of the Antheraea assamensis silkworm. Its natural golden colour needs no dye, and the silk becomes more lustrous with age.",
        "It is one of the strongest natural silks and has been worn by Assamese royalty for centuries; Muga silk is protected by a Geographical Indication. It is also used as a base for hand-painted Madhubani art.",
        "Genuine Muga has an even golden sheen that deepens after washing. Dry-clean, or hand-wash gently with mild soap, and dry in shade.",
    ]),
]

ESC = html.escape


def page(slug, name, term, region, paras):
    url = f"{SITE}/sarees/{slug}/"
    title = f"{name} Sarees — Buy Online | Meensha"
    desc = f"Shop {name} sarees at Meensha. " + paras[0][:110].rsplit(" ", 1)[0] + "…"
    others = "".join(
        f'<a href="../{s}/">{ESC(n)}</a>' for s, n, *_ in WEAVES if s != slug)
    ld = [
        {"@context": "https://schema.org", "@type": "CollectionPage",
         "name": f"{name} Sarees", "url": url, "description": desc,
         "isPartOf": {"@type": "WebSite", "name": "Meensha", "url": SITE + "/"}},
        {"@context": "https://schema.org", "@type": "BreadcrumbList",
         "itemListElement": [
             {"@type": "ListItem", "position": 1, "name": "Home", "item": SITE + "/"},
             {"@type": "ListItem", "position": 2, "name": "Sarees", "item": SITE + "/sarees/"},
             {"@type": "ListItem", "position": 3, "name": f"{name} Sarees", "item": url}]},
    ]
    region_html = f'<p class="wv-region">{ESC(region)}</p>' if region else ""
    body = "\n".join(f"<p>{ESC(p)}</p>" for p in paras)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{ESC(title)}</title>
<meta name="description" content="{ESC(desc)}">
<link rel="canonical" href="{url}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Meensha">
<meta property="og:title" content="{ESC(title)}">
<meta property="og:description" content="{ESC(desc)}">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{SITE}/og-image.jpg">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" type="image/svg+xml" href="../../logo.svg">
<link rel="preconnect" href="https://eglanmhhcccsuhbxywua.supabase.co" crossorigin>
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,400;0,600;1,400&family=Cinzel:wght@400;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="../weave.css">
<script type="application/ld+json">{json.dumps(ld, ensure_ascii=False)}</script>
</head>
<body>
<header class="wv-nav">
  <a href="../../"><img src="../../navbar_80.webp" alt="Meensha" width="52" height="52"></a>
  <nav><a href="../">All weaves</a><a href="../../about.html">About</a><a href="../../?shop={ESC(term)}">Shop</a></nav>
</header>
<main class="wv-main">
  <nav class="wv-crumbs" aria-label="Breadcrumb"><a href="../../">Home</a> › <a href="../">Sarees</a> › <span>{ESC(name)}</span></nav>
  <h1>{ESC(name)} Sarees</h1>
  {region_html}
  <section class="wv-copy">
{body}
  </section>
  <section class="wv-shop">
    <h2>{ESC(name)} pieces in stock</h2>
    <div id="wv-grid" class="wv-grid" data-term="{ESC(term)}"><p class="wv-empty">Loading…</p></div>
    <p class="wv-cta"><a href="../../?shop={ESC(term)}">Shop all {ESC(name)} on Meensha →</a></p>
  </section>
  <section class="wv-more">
    <h2>Explore other weaves</h2>
    <div class="wv-links">{others}</div>
  </section>
</main>
<footer class="wv-foot">Meensha · करघों की विरासत · <a href="https://wa.me/918709525218">WhatsApp</a> · <a href="mailto:meensha.fabrics@gmail.com">Email</a></footer>
<script src="../weave.js"></script>
</body>
</html>
"""


def index_page():
    cards = "".join(
        f'<a class="wv-card" href="{s}/"><h2>{ESC(n)}</h2><p>{ESC(p[0])}</p></a>'
        for s, n, t, r, p in WEAVES)
    url = f"{SITE}/sarees/"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Handloom &amp; Heritage Sarees by Weave | Meensha</title>
<meta name="description" content="A guide to India's saree traditions: Ajrakh, Bandhani, Kalamkari, Kota Doria, Madhubani, Muga silk and more, with pieces in stock at Meensha.">
<link rel="canonical" href="{url}">
<meta property="og:title" content="Handloom &amp; Heritage Sarees by Weave | Meensha">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{SITE}/og-image.jpg">
<link rel="icon" type="image/svg+xml" href="../logo.svg">
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,400;0,600;1,400&family=Cinzel:wght@400;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="weave.css">
</head>
<body>
<header class="wv-nav">
  <a href="../"><img src="../navbar_80.webp" alt="Meensha" width="52" height="52"></a>
  <nav><a href="../about.html">About</a><a href="../#catalogue">Shop</a></nav>
</header>
<main class="wv-main">
  <nav class="wv-crumbs" aria-label="Breadcrumb"><a href="../">Home</a> › <span>Sarees</span></nav>
  <h1>Sarees by Weave</h1>
  <p class="wv-region">India's textile traditions, and the pieces we have from each</p>
  <div class="wv-cards">{cards}</div>
</main>
<footer class="wv-foot">Meensha · करघों की विरासत · <a href="https://wa.me/918709525218">WhatsApp</a></footer>
</body>
</html>
"""


def sitemap():
    today = datetime.date.today().isoformat()
    urls = [SITE + "/", SITE + "/about.html", SITE + "/sarees/"]
    urls += [f"{SITE}/sarees/{s}/" for s, *_ in WEAVES]
    rows = "\n".join(
        f"  <url><loc>{u}</loc><lastmod>{today}</lastmod></url>" for u in urls)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
            f"{rows}\n</urlset>\n")


if __name__ == "__main__":
    out = ROOT / "sarees"
    for slug, name, term, region, paras in WEAVES:
        d = out / slug
        d.mkdir(parents=True, exist_ok=True)
        (d / "index.html").write_text(page(slug, name, term, region, paras), encoding="utf-8")
    (out / "index.html").write_text(index_page(), encoding="utf-8")
    (ROOT / "sitemap.xml").write_text(sitemap(), encoding="utf-8")
    print(f"wrote {len(WEAVES)} weave pages + sarees/index.html + sitemap.xml")
