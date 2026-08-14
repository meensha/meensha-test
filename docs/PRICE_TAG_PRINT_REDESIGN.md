# Price Tag Printing — Redesign (design-only, build after the stall)

## Context
Current `printTags()` (admin.html, Inventory tab) is a one-click bulk action: select SKU checkboxes → immediately opens a print window with one tag per *available* unit, no review step, no history, no way to print a partial quantity. Works, but has real gaps the user hit while actually using it day-to-day:

1. No record of which tags were printed, how many, or when — no way to tell if a batch was already printed or needs a reprint.
2. No quantity control — always prints one tag per available unit; can't choose to print fewer (e.g. reprint 2 out of 8 available).
3. No page/batch awareness — user has to manually figure out how many 16-tag sheets a print run needs, or whether the last sheet is mostly wasted blank space.
4. Printing happens immediately on click — no chance to review/adjust before committing paper.

## Approved design

**Trigger:** clicking "🏷️ Print Tags" no longer prints immediately — it opens a **dedicated Print Tags page** (separate view, not a same-page action).

### Item selection screen
- List of all in-stock SKUs, each with a **checkbox + quantity input**.
- Quantity **defaults to the item's current available count**, editable down (confirmed default behavior) — e.g. 5 available → prefills 5, user can reduce to 2.
- Directly under each item (or on selection/expand), show its **print history: last 3 print records**, most recent first — e.g.:
  ```
  Printed: 2026-07-18 (qty 6)
  Printed: 2026-07-15 (qty 3)
  Printed: 2026-07-10 (qty 10)
  ```
  This is what lets the user judge "have I already printed for this restock" without leaving the screen.

### Confirmation step
- After selecting items/quantities and clicking a "Print" action, **don't print yet** — show a summary:
  - Total tag count across all selected items.
  - Auto-grouped into **batches of 16** (matching the physical 2×8 sheet layout already built).
  - Explicit page math, e.g.: *"58 tags → 4 pages (last page: 6/16 used). Print?"*
- Only on confirming this does it proceed to the actual print window (reusing the existing `printTags()` HTML/CSS generation logic, just fed the user's chosen qty-per-item instead of "all available units").

### Which physical units get printed (needs a default, not yet confirmed with user)
When qty selected < available count for a SKU, some subset of that SKU's physical units must be chosen for the tags. Proposed default: **oldest batch/unit first (FIFO)** — matches normal inventory practice (print for stock that's been sitting longest). **Flag this specific point to the user before building** — it wasn't explicitly specified.

### Print history persistence (new, needed)
No existing table tracks this. Needs a new table, e.g. `tag_print_log`:
```sql
CREATE TABLE IF NOT EXISTS tag_print_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku_id      uuid NOT NULL REFERENCES inventory_skus(id) ON DELETE CASCADE,
  unit_ids    jsonb NOT NULL DEFAULT '[]'::jsonb,  -- which specific units were printed
  qty         integer NOT NULL,
  printed_by  text,
  printed_at  timestamptz DEFAULT now()
);
```
Written once per SKU per confirmed print run (not per physical tag) — the "last 3" view queries this table `WHERE sku_id = ? ORDER BY printed_at DESC LIMIT 3`.

## Not yet decided — confirm before building
1. FIFO unit selection assumption above (or should it be user-pickable which specific units, like Godown mode's unit multi-select?).
2. Does reprinting the same unit reset/append its print history, or is there a "don't reprint the same unit twice" warning?
3. Is the Print Tags page a new top-level tab, or a full-screen modal reached from the Inventory tab's existing button?

## Files this touches when built
- New SQL migration: `meensha-test/setup/add_tag_print_log.sql`
- `admin.html`: new Print Tags screen/view, quantity-aware `printTags()` rewrite, batch/page-math confirmation dialog, print-history query+display per item.
