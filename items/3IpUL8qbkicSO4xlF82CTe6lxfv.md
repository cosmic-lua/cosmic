## Evidence

`gitboard next` at 18:2xZ on 2026-09-03 offered «1j6D_hfCe» ("perf:
re_match_log_line cf416d85 vs 9fcfff3f needs day-separated (not
same-hour) re-measurement — 4 same-day sessions split 2-2 on
direction") as the head pull. Its spec's own method requires a
measurement on a different day from the four it cites (all
2026-09-03), so any session pulling it today either bounces or
violates the spec; the orchestrator skipped it by hand and moved to
the second choice. Items exist whose readiness is a calendar fact
(day-separated perf runs, "after the next release", a pin that ships
daily at 06:00), and the only tool today is prose the puller must
read, or a block on an item that does not exist.

## Change

`_work/store.tl` (item fields): an optional `not_before` field, an
RFC3339 date. `gitboard set ID --not-before DATE` writes it (and
`--not-before ""` clears it); `show ID` prints it. `next`, `take` (a
pull) and the pullable count in `show` treat an item with `not_before`
in the future as not pullable, rendering `[held until DATE]` in the
list; the bar itself is unchanged. Refine-time guidance in `help
bar`: one sentence — a Change whose earliest valid start is a date
records it as `not_before`, never as prose.

`_work/store_test.tl`, `action_test.tl`: a held item is not offered
until the date passes; `show` prints the marker.

## Non-goals

No automatic derivation from spec prose; the refiner sets the date.
