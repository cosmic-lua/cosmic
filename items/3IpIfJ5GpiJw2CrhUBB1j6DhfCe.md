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
session, corrected in place below by a `request-changes` review round;
still the same single day-separated session, not a second one).**

5. **Day-separated session 1 of the required ≥2 (2026-09-04, this
   item's research slice). CORRECTED — the original version of this
   item recorded binary hashes that do not reproduce; see "Correction"
   below before the restated measurement.**

   Gate check: `date -u +%F` → `2026-09-04`, which does not appear
   among the four recorded 2026-09-03 sessions, so the `## Change` gate
   below was satisfied and this session recorded a genuinely
   day-separated measurement — one calendar day after all four
   same-hour sessions in items 1-4.

   **Correction (this round).** A `request-changes` review
   (`review-1j6D_hfCe-1`) rebuilt both commits from a fresh clone via
   the trust root, twice each for stability, and got hashes that did
   not match this item's originally-recorded values for either commit
   — and did match a cross-verified value independently recorded the
   day before on `c5wU_p1n9` (`show 3IosEPKw1cMYZ7fSidzc5wUp1n9`,
   `bin_sha 71f1030609723add8...` / `bin_sha 9bcfcd29dde5d382...`).
   This research slice has no access to the original session's raw
   JSON or build logs (recorded as written to an ephemeral scratchpad,
   not to this item, so nothing on disk to audit) and so cannot
   determine whether the original hash strings were a transcription
   error over a correctly-measured run or a genuine wrong-binary
   measurement. Per the review's instructions, this round therefore
   redid the rebuild-and-measure from scratch rather than assume
   transcription error, and the pair table below REPLACES the
   original item-5 table in full (not merely its hash line).

   Rebuild: fresh clone of `cosmic-lua/cosmic`, two `git worktree`
   checkouts (one per commit) off that clone, each bootstrapped
   independently via the trust root (`bin/cosmic --make fetch &&
   bin/cosmic --make build`). Pins confirmed identical between the two
   commits before building (`3p/cosmos/cosmos_pin.tl` and
   `3p/tl/tl_pin.tl` both last touched at `a5b36f4a`, well before
   either commit) — no pin drift to control for. Each commit was built
   twice from a clean `o/bin` to check stability; both builds of each
   commit reproduced the identical hash:

   - `9fcfff3f` → `71f1030609723add88595beb1da001e861919297f8996a8916e3250de4f4c22d`
     (stable across 2 builds) — matches the cross-verified value.
   - `cf416d85` → `9bcfcd29dde5d3829f4664d13a7f382f5168e46313178415e08c92d326675d2b`
     (stable across 2 builds) — matches the cross-verified value.

   So the rebuild reproduces cleanly in this environment too (a third
   independent confirmation of these two hashes, after `c5wU_p1n9`'s
   own session and this round's reviewer), and this round's
   measurement below is certified against the correct commits: the
   harness records the measured binary's own sha256 in each result
   file's `meta.bin_sha`, and every one of the 24 JSON files produced
   below (12 pairs × 2 sides) was checked programmatically against
   these two expected hashes with zero mismatches.

   Environment note: CPU family 6 / model 207 / stepping 2, 4 vCPUs —
   NOT the same CPU class (family 6 / model 85 / stepping 7) that items
   1-4 and `measurement.md`'s own cited evidence ran on. Per
   `measurement.md`, magnitude does not transfer across sessions on
   different hardware even when the verdict does — noted here as an
   uncontrolled variable between this session and the prior four, not
   as a blocker.

   12 interleaved, order-randomized pairs (`o/bin/cosmic --make run
   _perf/run.tl --only re_match_log_line` on each commit's own built
   binary, back-to-back per pair, via `--make run` so the harness and
   scenario resolve against each commit's own tree per
   `skills/optimize/SKILL.md`'s harness-identity rule; order generated
   before running — 6 old-first, 6 new-first):

   | pair | old (9fcfff3f) ns/op (spread) | new (cf416d85) ns/op (spread) | delta |
   |---|---|---|---|
   | 1 | 3524.39 (±4.5%) | 3673.28 (±4.6%) | +4.22% |
   | 2 | 3591.98 (±14.1%) | 3534.07 (±6.6%) | -1.61% |
   | 3 | 3843.60 (±10.0%) | 4031.61 (±19.7%) | +4.89% |
   | 4 | 4365.47 (±32.6%) | 4125.41 (±16.7%) | -5.50% |
   | 5 | 4179.75 (±5.3%) | 4119.14 (±34.1%) | -1.45% |
   | 6 | 3856.95 (±13.3%) | 4091.75 (±12.2%) | +6.09% |
   | 7 | 4438.51 (±6.1%) | 4284.42 (±12.1%) | -3.47% |
   | 8 | 4724.63 (±24.7%) | 4530.62 (±4.8%) | -4.11% |
   | 9 | 5053.39 (±24.2%) | 5107.85 (±10.1%) | +1.08% |
   | 10 | 5044.24 (±25.5%) | 5432.63 (±7.6%) | +7.70% |
   | 11 | 5207.90 (±9.7%) | 5134.09 (±21.2%) | -1.42% |
   | 12 | 4569.03 (±23.0%) | 6001.27 (±11.7%) | +31.35% |

   6/12 (50%) pairs read "new slower" (regression direction) — an exact
   split. Mean delta +3.15%, median delta -0.17%; pooled (mean of all
   12 old readings vs mean of all 12 new readings) delta +3.18%, pooled
   median delta -4.48%.

   selfcheck A/A noise floor, three runs spread across the session
   (`gate.tl selfcheck --only re_match_log_line`, both sides the SAME
   binary): -4.0% (±17.2% spread, 9fcfff3f, early) → +5.5% (±22.5%
   spread, cf416d85, early) → -3.0% (±16.4% spread, 9fcfff3f, later).
   An UNCHANGED binary swung across a ~9.5-point band against itself
   within this one session, with spread up to 22.5% within a single
   comparison — the same within-session, same-binary noise
   `measurement.md` documents as uncontrollable from interleaving
   alone.

   Direct demonstration that the raw pair deltas above are
   noise-dominated, not signal: running the formal `gate.tl compare`
   (with `--baseline-bin`, so it can re-measure the baseline on a
   flag) on pair 12 — the largest raw delta, +31.35%/+31.3% as
   recomputed by the gate, initially flagged `regression` — triggered
   its full retry/tiebreak path: the retry re-measured both sides, the
   two `9fcfff3f` (baseline) readings then disagreed past the bar
   (4.57µs → 7.14µs), so `gate.tl` drew a third baseline sample
   (6.32µs) and judged against the median; the verdict flipped from
   `regression` to `ok` at +14.7%. Excluding pair 12 — the one whose
   noise origin this directly demonstrates — from the pooled figures
   drops the mean delta to +0.58% and the pooled mean to +0.49%, both
   indistinguishable from zero; the new-slower split becomes 5/11
   (45%), still no majority.

   **Verdict of this session alone (now measured against
   hash-verified binaries): no stable direction distinguishable from
   the demonstrated noise floor — reads like sessions 2 and 3, not
   sessions 1 and 4.** This is session 1 of the ≥2 day-separated
   sessions the `## Change` gate requires; the verdict logic there
   does not yet apply on one day-separated session alone. At least one
   more session, on a calendar day distinct from both 2026-09-03 and
   2026-09-04, is still needed before `c5wU_p1n9` / `pmIX_ommp`
   (`3IopfBATkXMfl9qRpLDpmIXommp`) / `3IonN6KwrW1QezqdCBs0pa6japm` can
   be resolved per this item's own decision tree.

   Raw JSON results, per-pair `meta.bin_sha` audit output, and
   worktree build logs from this round were written to an ephemeral
   scratchpad, not to this item; the table, selfcheck figures, and
   gate.tl transcript excerpt above are the complete extracted record.
   (This is the same limitation the correction above flags about the
   ORIGINAL item-5 session's now-inaccessible raw data — a future
   round auditing THIS round's numbers will face the identical gap
   unless raw results start being retained somewhere durable. Worth a
   process note if this pattern repeats a third time, but not itself
   part of this item's `## Change`.)

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
overwrite prior rounds — append). Before measuring, verify both
binaries' sha256 against a fresh rebuild (trust root, two builds per
commit for stability) rather than trusting a previously-recorded hash
string, and check every measured result file's `meta.bin_sha` against
that verified value — item 5's first version shipped hashes that did
not reproduce, so this check is now load-bearing, not optional. One of
the required ≥2 day-separated sessions is now recorded and verified
(Evidence item 5, 2026-09-04); at least one more, on yet another
calendar day, is still needed before the verdict logic below applies.

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
