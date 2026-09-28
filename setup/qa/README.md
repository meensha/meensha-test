# QA scripts

Playwright checks used for the 2026-09-28 table lock and mobile cart fixes.
They run against a live site. The customer flow adds one item to the cart
and removes it again. It stops at the Razorpay contact form, so it never
creates a payment link or an order.

Playwright comes from the claude-seo toolkit's venv:

```
PY=~/.claude/skills/seo/.venv/bin/python
export PLAYWRIGHT_BROWSERS_PATH=~/.claude/skills/seo/ms-playwright
```

| Script | What it checks | Run |
|---|---|---|
| `qa.py` | All public pages plus the customer flow, desktop 1366 and mobile 360: console errors, failed Supabase calls, horizontal overflow, cart hold and release, coupon, customer login, invoice mismatch, admin login screen. Screenshots and `results.json` go to `out/<label>/`. | `$PY qa.py https://meensha.in/ prod` |
| `cartfix.py` | The mobile cart: no expiry nudge while the drawer is open, and the coupon fields stay inside the drawer at 360, 390 and 1366. | `$PY cartfix.py https://meensha.github.io/meensha-test2/ staging` |
| `probe.py` | For each table and view: can the anon key read it? It uses `limit=0` with a row count, so no row data is ever fetched. Only `instagram_posts`, `popups`, `settings`, `reviews` and `public_skus`/`public_units` should come back non-zero. | `python3 probe.py` |

Staging and production share one Supabase project, so the cart hold made by
`qa.py`/`cartfix.py` lands in the live database either way (it's released
at the end of each run).

When you add a table, add its name to the list in `probe.py`.
