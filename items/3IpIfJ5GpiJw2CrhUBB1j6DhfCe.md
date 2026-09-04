## Evidence

Board item `3IosEPKw1cMYZ7fSidzc5wUp1n9` («c5wU_p1n9») set out to get a
second, independent same-day confirmation of `pmIX_ommp`'s
(`3IopfBATkXMfl9qRpLDpmIXommp`) claimed `re_match_log_line` regression
between `9fcfff3f` and `cf416d85` (the `assert(caps is {string}, ...)`
added to `cosmic/re.tl`'s `match()`), per `skills/optimize/measurement.md`'s
rule that a release-gating regression on a single tight-loop scenario
needs cross-session reproduction before it is written into a board item
as confirmed. Four independent same-day sessions have now measured it
(all landing within roughly the same hour, not the "ideally days apart"
`measurement.md` itself asks for):

1. `pmIX_ommp` (original): 6 interleaved pairs, 5/6-6/6 same direction,
   ~+4.3% mean / +2.8% median — regression.
2. `c5wU_p1n9`'s own build agent: 6 interleaved pairs, 3/6 split, mean
   delta ~+0.01% — no stable direction.
3. `c5wU_p1n9`'s first review round (`review-c5wU_p1n9-1`): 6 fresh
   interleaved pairs, 3/3 split, deltas -3.73% to +9.49% — no stable
   direction (this round also found and fixed a real bug in the
   recorded `_perf/gate.tl selfcheck` invocation, unrelated to the
   direction question).
4. `c5wU_p1n9`'s second review round (`review-c5wU_p1n9-2`): 12 fresh
   interleaved pairs (6 before-first, 6 after-first), 10/12 (83%) same
   direction ("after slower"), mean +2.73%, median +2.18%, holding
   symmetrically in both orderings — regression, directionally
   consistent with round 1.

Two of four independent sessions read "regression, same direction as
the original", two read "no stable direction, inside noise." This is
exactly the pattern `measurement.md` documents as a live trap: "one
unchanged binary swung -38% between two sessions... measured hours
apart in the same container" — host placement is not observable or
controllable from inside a container, and the guidance explicitly
requires DAYS apart, not hours, before certifying a finding one way or
the other. None of the four sessions above are days apart from each
other. `c5wU_p1n9`'s own two-branch decision tree ("reproduces → fix",
"doesn't reproduce → dismiss as noise, close") does not have a branch
for a split verdict across replications, so neither outcome is
currently supportable from the evidence in hand.

**Session dates recorded on this item so far: 2026-09-03 (×4, items
1-4 above), 2026-09-04 (×1, item 5 below — first day-separated
session).**

5. **Day-separated session 1 of the required ≥2 (2026-09-04, this
   item's research slice).** Gate check: `date -u +%F` → `2026-09-04`,
   which does not appear among the four recorded 2026-09-03 sessions,
   so the `## Change` gate below was satisfied and this session
   recorded a genuinely day-separated measurement — one calendar day
   after all four same-hour sessions in items 1-4.

   Built `9fcfff3f` and `cf416d85` as two separate local git worktrees
   off the same clone (pins identical between the two commits — no
   pin drift to control for). Binary hashes: `9fcfff3f` →
   `f67e7b16c6831f280f0590ce79b45cee1344d8fece0d2760090fca4d452c2e9f`;
   `cf416d85` →
   `cbfd6712f56c616b62c30f594feed5d8ab5b1101c0980af92d4244f5c06a20bb`
   (both rebuilt once and reconfirmed byte-stable at that hash before
   measuring). CPU family 6 / model 85 / stepping 7 — the same class
   `measurement.md`'s own recorded evidence used — 4 vCPUs.

   12 interleaved, order-randomized pairs (`run.lua --only
   re_match_log_line` on each binary back-to-back per pair; the
   old/new order per pair was generated before running, not chosen
   post hoc — 6 old-first, 6 new-first):

   | pair | old (9fcfff3f) ns/op (spread) | new (cf416d85) ns/op (spread) | delta |
   |---|---|---|---|
   | 1 | 4299.16 (±7.6%) | 4199.79 (±3.0%) | -2.31% |
   | 2 | 4452.41 (±26.1%) | 4296.37 (±8.2%) | -3.50% |
   | 3 | 4090.29 (±1.9%) | 4224.39 (±6.2%) | +3.28% |
   | 4 | 4144.40 (±8.6%) | 4224.80 (±4.8%) | +1.94% |
   | 5 | 4189.56 (±4.0%) | 4239.49 (±1.7%) | +1.19% |
   | 6 | 4190.89 (±23.0%) | 4201.99 (±3.3%) | +0.26% |
   | 7 | 4203.63 (±2.1%) | 4835.75 (±13.8%) | +15.04% |
   | 8 | 4401.07 (±19.4%) | 5371.61 (±5.0%) | +22.05% |
   | 9 | 5399.83 (±56.4%) | 4720.10 (±30.3%) | -12.59% |
   | 10 | 4844.23 (±12.0%) | 5465.51 (±21.6%) | +12.83% |
   | 11 | 5413.64 (±18.7%) | 4448.67 (±5.7%) | -17.82% |
   | 12 | 4838.78 (±18.8%) | 4950.10 (±11.3%) | +2.30% |

   8/12 (67%) pairs read "new slower" (regression direction); mean
   delta +1.89%, median +1.57%; pooled (mean of all 12 old readings vs
   mean of all 12 new readings) delta +1.30%, pooled median delta
   +0.51%.

   selfcheck A/A noise floor, three runs spread across the session
   (`gate.tl selfcheck --only re_match_log_line`, both sides the SAME
   binary): +3.0% (±13.6% spread, cf416d85, early) → -10.0% (±22.2%
   spread, 9fcfff3f, early) → +5.1% (±17.1% spread, cf416d85, late).
   An UNCHANGED binary swung from -10% to +5% against itself within
   this one session, with spread up to 22%; the absolute level also
   drifted from ~4.2-4.4µs early in the session to ~5.8-6.1µs late in
   the session on the identical binary — the within-session,
   same-binary drift `measurement.md` already documents as
   uncontrollable from interleaving alone.

   Direct demonstration that the raw pair deltas above are
   noise-dominated, not signal: running the formal `gate.tl compare`
   (with `--baseline-bin`, so it can re-measure the baseline on a
   flag) on pair 8 — the largest raw delta, +22.1%, initially flagged
   `regression` — triggered its full retry/tiebreak path: the retry
   re-measured both sides, the two `9fcfff3f` (baseline) readings then
   disagreed past the bar (4.40µs → 6.45µs, a same-binary ~50% swing
   inside about 3 minutes), so `gate.tl` drew a third baseline sample
   and judged against the median; the verdict flipped from
   `regression` to `ok` at +4.6%. Excluding pairs 7 and 8 — the two
   whose noise origin this directly demonstrates — from the pooled
   mean drops it to +0.08%, indistinguishable from zero.

   **Verdict of this session alone: no stable direction distinguishable
   from the demonstrated noise floor — reads like sessions 2 and 3, not
   sessions 1 and 4.** This is session 1 of the ≥2 day-separated
   sessions the `## Change` gate requires; the verdict logic there does
   not yet apply on one day-separated session alone. At least one more
   session, on a calendar day distinct from both 2026-09-03 and
   2026-09-04, is still needed before `c5wU_p1n9` / `pmIX_ommp`
   (`3IopfBATkXMfl9qRpLDpmIXommp`) / `3IonN6KwrW1QezqdCBs0pa6japm` can
   be resolved per this item's own decision tree.

   Raw JSON results and worktree build logs from this session were
   written to an ephemeral scratchpad, not to this item; the table and
   selfcheck figures above are the complete extracted record.

## Change

Ready when: today is not a day any recorded session ran on. Every
session in Evidence, and every one appended below, records its date;
the puller runs

    date -u +%F

first and proceeds only if that date appears nowhere in this spec's
session records (2026-09-03 ×4, 2026-09-04 ×1 so far — see the
"Session dates recorded" line above Evidence item 5 for the running
tally). A match means this session cannot add a day-separated
measurement — drop the claim bare (the item is fine as written) and
let the next day's session take it.

Run the cross-session comparison `9fcfff3f` vs `cf416d85` on
`re_match_log_line` (interleaved, order-randomized, at least 6 pairs
per session, `_perf/gate.tl selfcheck <A.json> <B.json> --only
re_match_log_line` for the noise floor) in at least two MORE sessions
genuinely separated by calendar days, not hours, per
`skills/optimize/measurement.md`'s own rule. Record each session's raw
pair table and selfcheck noise band on this item as it runs (do not
overwrite prior rounds — append). One of the required ≥2 day-separated
sessions is now recorded (Evidence item 5, 2026-09-04); at least one
more, on yet another calendar day, is still needed before the verdict
logic below applies.

Once at least two day-separated sessions exist:

- if the day-separated sessions agree with each other on direction:
  that is the verdict (real regression → evaluate a fix at the one
  narrowing site in `cosmic/re.tl`'s `match()`; no stable direction →
  dismiss as noise) — resolve `c5wU_p1n9` accordingly and mark
  `pmIX_ommp` (`3IopfBATkXMfl9qRpLDpmIXommp`) and
  `3IonN6KwrW1QezqdCBs0pa6japm`'s CI flag per that verdict.
- if they still disagree: this scenario's noise floor is wider than a
  handful of sessions can resolve cheaply; escalate to the goal owner
  for a decision on whether to invest in the low-risk mitigation
  regardless of statistical certainty — proving the `caps is {string}`
  invariant statically (removing the runtime check entirely) is cheap,
  scoped to one site, and resolves the ambiguity for free if it works,
  independent of whether the perf effect is real.

## Non-goals

Not re-litigating whether cross-session, day-separated reproduction is
the right bar — `measurement.md` already settled that; this item exists
because the bar was not actually met for `c5wU_p1n9`'s original
same-day rounds, not because the bar itself is in question. Not
touching `cosmic/re.tl` or any other narrowing site directly — that is
`c5wU_p1n9`'s own `## Change` step 2, gated on this item's outcome.
