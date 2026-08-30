## Change

Follow-up to the merged decode-tolerance change: `item.decode` now
returns flagged items (`Item.decode_problems`, `item.is_flagged`) and
`store.flagged_summary(items)` formats the report line — but nothing
calls it, so a flagged stored record is read past silently and nobody
learns it needs repair (`set --title` can fix it, but only if
noticed). The change, in the board render layer (`_work/gitshow.tl`,
and `_work/gitview.tl` if bare show's sections live there — measure
with `grep -rn 'flagged_summary\|is_flagged' _work/` and read how
bare `show` assembles its sections):

1. Bare `show` prints ONE summary line (the `flagged_summary` text)
   when any listed item is flagged — positioned with the other
   board-level lines (near `lanes`/`todo`), not per item.
2. `show <id>` on a flagged item prints its `decode_problems` as
   visible problem lines beside the existing bar problems.
3. `next` is unchanged unless a one-line reuse falls out for free —
   do not redesign its output.

Tests in the existing gitshow/gitview test seams: a store fixture
with one flagged record — bare show contains the summary line; show
<id> names the problem; a clean store prints no summary line.
Mutation-verify the wiring (drop the flagged_summary call, watch the
bare-show test go red).

## Non-goals

No decode/store changes (already merged). No new verbs. No repair
automation — rendering only.
