## Change

`gitboard spec` refuses to rewrite the spec of an item that is in
flight under another session, unless forced on the record.

Reproduced 2026-08-29 on a scratch board (merged two-state machinery,
board head f10c9b6): builder-a `take` then `take --pr 7`; then

    GITBOARD_SESSION=refiner-b gitboard spec ID new.md --base base.md
    gitboard-spec: 3Ib1Jdko's spec replaced

— a foreign session silently replaced the definition of work another
session had already built and handed to review. The `--base`
compare-and-swap only proves the writer READ the current text, not
that the item is theirs to redefine. (Original incident: sessions
f00d09f2/7b2d5794 on 3ISJKfRg, PR #1406.)

The change, in three files:

1. `_work/gitgate.tl` (198 lines now — `wc -l < _work/gitgate.tl`):
   move `base_refusal` verbatim from `_work/gitverbs.tl` (lines
   42-79 there) into gitgate beside the other gates, and add one new
   guard beside it:

       spec_refusal(it, session): string | nil

   returning a refusal exactly when `flow.is_doing(it)` and
   `(it.claim or "") ~= ""` and `it.claim ~= (session or "")` — an
   in-flight item's spec is its claim holder's to move. The refusal
   text names the holder and the override: rewriting another
   session's live build needs `--force --why`. Export both from the
   gitgate record.
2. `_work/gitverbs.tl` (494 lines now — `wc -l < _work/gitverbs.tl`,
   6 under the 500 cap, which is why `base_refusal` moves OUT):
   `cmd_spec` gains `session`, `force`, `why` parameters; it applies
   `gate.force_refusal` (as `take`/`done` do), then `gate.spec_refusal`
   unless forced, then the moved `gate.base_refusal`. A forced write
   appends `gate.forced_suffix` to the commit subject. Net line
   delta for this file must be negative.
3. `_work/gitboard.tl`: the `spec` command spec gains `--session`,
   `--force`, `--why` flags (same help text shape as `drop`'s), and
   the dispatch passes `session.resolve(...)` and the two flags.

What stays legal, deliberately: the claim HOLDER rewriting their own
item's spec at any point (spec-only rework answering a bounce is a
designed path — the verdict pair and `show`'s spec-changed-since
line make it visible), and any write to an UNCLAIMED item (todo, or
a dropped one). Only the foreign-live-claim write gains a gate.

Tests in `_work/gitspec_test.tl`: the reproduced scenario refuses
(foreign session, claim + pr standing) and the item file and sidecar
are unchanged after the refusal; the holder's own rewrite with
`--base` still lands; `--force` without `--why` refuses; with both
it lands and the commit subject carries the forced suffix. Existing
base-CAS tests keep passing unchanged except for the added
parameters at call sites.

## Non-goals

Existing verdict-line formats and refusal texts are unchanged (new
refusals only, in the standing `REFUSED: ...` shape). No new verb.
No claim check on any other verb. The reviewer field holds no spec
lock — only the build claim gates.
