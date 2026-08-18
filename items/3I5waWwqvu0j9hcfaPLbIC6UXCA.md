## Goal

G3 — an honest type layer, no escape hatches (docs/goals.md), via the epic
"measure and drive down the as-cast count" (board item 3HyArM3A). That epic's
wave plan names this as wave 7 (S6): the gate's own `TREES` constant omits
two committed Teal trees, so casts in those trees can grow without limit
while the ratchet reports a clean floor.

## Change

In `_build/casts.tl`, add `"_eval"` and `"_fuzz"` to the `TREES < const >`
list (currently 9 entries, lines 33-36). Then regenerate the committed
floor: `bin/cosmic --make run _build/casts.tl --baseline`, and commit the
result — the two new trees' cast sites enter the ratchet at their current
count, so this slice is a one-line addition plus a baseline regen, nothing
else. No change to `_build/public_surface.tl`, `cosmic/literal.tl`, or the
gate's comparison logic.

The measured facts this rests on (2026-08-18, re-measured — the epic's own
2026-08-17 count of 14 sites is stale; three more sites landed in `_eval/`
since):

```facts
$ grep -n '"_eval"\|"_fuzz"' _build/casts.tl
$ git grep -c -- "-- cast:" -- "_eval/*.tl" "_fuzz/*.tl"
_eval/score.tl:10
_eval/score_test.tl:13
_eval/stage.tl:9
_eval/stage_test.tl:3
_fuzz/compress_fuzz_test.tl:1
_fuzz/sse_fuzz_test.tl:1
$ git grep -c -- "-- cast:" -- "_eval/*.tl" "_fuzz/*.tl" | awk -F: '{s+=$NF} END {print s+0}'
37
$ wc -l < _build/casts.tl
156
$ grep -oE '= [0-9]+' _build/casts_baseline.tl | awk '{s+=$2; n++} END {print s, n}'
418 130
```

## Non-goals

No new automated check that `TREES` covers every committed Teal tree — the
list is hand-maintained the same way it was when `_perf` and `_types` were
added, and adding such a check (if the gap recurs again) is separate future
work, not this slice.

No change to `_build/public_surface.tl` or any other gate — this slice is
`_build/casts.tl` only, matching the epic's own sizing for this wave.

No change to `_eval/*.tl` or `_fuzz/*.tl` themselves — their casts are
existing, justified sites (each already carries a `-- cast: <reason>`
comment); this slice only brings them under the gate, it does not touch
them.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/casts_test.tl` passes.
- `grep -c '"_eval"\|"_fuzz"' _build/casts.tl` is `2` (pre-change value `0`,
  recorded as a fact above).
- After running `bin/cosmic --make run _build/casts.tl --baseline`,
  `git diff --quiet _build/casts_baseline.tl` exits non-zero (the floor
  changed — it must, since it is gaining 37 previously-uncounted sites) —
  confirm with `git diff --stat _build/casts_baseline.tl` showing the new
  `_eval/*` and `_fuzz/*` entries, then commit the regenerated floor as
  part of this PR.
- `grep -c '_eval/\|_fuzz/' _build/casts_baseline.tl` is `6` (one entry per
  file with at least one cast: `_eval/score.tl`, `_eval/score_test.tl`,
  `_eval/stage.tl`, `_eval/stage_test.tl`,
  `_fuzz/compress_fuzz_test.tl`, `_fuzz/sse_fuzz_test.tl`).

## Enablement

none needed — this is a one-line addition to an existing hand-maintained
list, using the same mechanism (`bin/cosmic --make run _build/casts.tl
--baseline`) every prior tree addition to `TREES` has used. No blocker
items.
