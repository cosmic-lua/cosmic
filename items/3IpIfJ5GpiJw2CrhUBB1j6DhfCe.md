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

## Change

Run the cross-session comparison `9fcfff3f` vs `cf416d85` on
`re_match_log_line` (interleaved, order-randomized, at least 6 pairs
per session, `_perf/gate.tl selfcheck <A.json> <B.json> --only
re_match_log_line` for the noise floor) in at least two MORE sessions
genuinely separated by calendar days, not hours, per
`skills/optimize/measurement.md`'s own rule. Record each session's raw
pair table and selfcheck noise band on this item as it runs (do not
overwrite prior rounds — append). Once at least two day-separated
sessions exist:

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
