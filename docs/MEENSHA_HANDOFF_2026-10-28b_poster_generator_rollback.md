# Meensha session handoff — 2026-10-28 (pm) — Poster generator: closed as a failure

## Status: closed by the owner, marked a failure. Rollback available, not yet done.

## What this covers (this session's own work, separate from parallel sessions' commits in the same window)

- Stock Sheet (A4) finishing touches: Hindi logo, generated date/time box,
  and a real bug fix (the Safari portrait-rotation CSS trick a parallel
  session had added was also breaking Chrome's own correctly-landscape
  output — removed, replaced with a plain toast telling Safari users to
  pick Landscape themselves). **This part worked and was confirmed
  correct** — not what's being rolled back.
- Item/Label Poster Generator — new admin.html section, headline + optional
  subtext over an owner-supplied blank template, Generate → Save PNG →
  Print. **This is the part marked a failure.**

## Why the poster generator is being called a failure

Three rounds of visual tuning, each confirmed via actual full-resolution
headless-Chrome print renders (not just screenshots) before shipping, and
still wrong each time from the owner's perspective:

1. First version: text sized/positioned by estimate against the reference
   mockup — went out "too small, not like the sample."
2. Second version: made bolder/larger per that feedback — went out with
   text visibly overlapping the ornamental scrollwork, which the owner
   called a mistake, not a stylish touch, on sight ("no").
3. Third version: switched to wrap-to-multiple-lines at a fixed bold size
   instead of shrinking to force one line — verified clean (no scrollwork
   contact) on two test headlines via real print renders — before this
   could be confirmed against the owner's own eyes, the session was closed
   as a failure.

Root problem: every round was verified against *my own* visual judgment of
"does this look right," using print-PDF renders as a correctness check for
*mechanics* (does it print, is it one page, is it positioned where I
intended) — not as a substitute for the owner actually looking at it. Each
fix was shipped before getting that confirmation, so three iterations went
out instead of one. For a visual/design feature like this, the render
should have been shown to the owner before each push, not after.

## Rollback reference, if wanted

Poster generator commits, in order:
- `2a98d01` — Add Item/Label Poster Generator, remove plain event-QR button (first version)
- `32f46a5` — Make poster headline text bolder to match reference design (second version — the one with the overlap)
- `09738de` — Fix poster headline overlapping the scrollwork again (third version — wrap-first, not owner-confirmed)

To fully remove the Item/Label Poster Generator feature and go back to
before it existed: revert from `2a98d01` forward (3 commits touching only
`admin.html`'s poster-generator section + `poster_template_blank.png`).
To keep the feature but roll back just to the *first* version's visual
tuning (small-but-safe): `git revert 09738de 32f46a5`, keeping `2a98d01`.
No database migration is involved in any of these three commits — pure
`admin.html` + the one image asset, so a revert is low-risk/self-contained,
doesn't touch anything else shipped today (stock sheet, checklist system,
event-offer toggle, etc. are unaffected).

## Not touched by this doc

Everything else committed today by this or parallel sessions (stall-prep
checklist, kiosk event-offer toggle, unprefixed codes, permanent event QR,
the various Instagram-follow/registration fixes) is unrelated to the
poster generator and not part of this rollback note.
