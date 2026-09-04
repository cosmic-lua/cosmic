## Evidence

`friction: 2026-09-04 work9 reconciliation tail` (item «NJCj_HQIX»)
records that `gitboard brief review <id>` always mints the same base
label (`review-<handle>-<orch8>`) regardless of how many times the
item has already been reviewed. Across six re-review rounds on two
items that pass, the orchestrator hand-suffixed `-2`, `-3`, `-4` via
`take --session` and then had to `sed -i` across the emitted brief to
keep the verdict command's embedded session string consistent with
the actual claim — up to 3 occurrences per brief, a copy-paste risk
each time.

## Change

`_work/brief.tl`'s review-kind mint logic: derive the round number as
one more than the count of prior verdicts already recorded against
the item's current `pr` (the same verdict history `verdict`/`show`
already read), and mint `review-<handle>-<orch8>-<n>` instead of the
always-round-1 `review-<handle>-<orch8>`. Round 1 keeps the existing
label shape unchanged (n=1 renders without a trailing `-1`, matching
every already-merged review label on the board).

`_work/brief_test.tl`: a fixture item with zero prior verdicts mints
the unsuffixed label; one with two prior verdicts mints `-3`.

## Non-goals

No change to the build/research/refine/decompose mint paths, and no
change to `take`'s claim logic itself — only what `brief review`
prints.
