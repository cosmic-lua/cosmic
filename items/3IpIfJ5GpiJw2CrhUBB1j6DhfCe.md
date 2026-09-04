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
1-4 above), 2026-09-04 (×1 calendar day, item 5 below — first
day-separated session; item 5 records more than one measurement
sub-run made that day, corrected in place after review).**

5. **Day-separated session 1 of the required ≥2 (2026-09-04, this
   item's research slice, reviewed and corrected in place).** Gate
   check: `date -u +%F` → `2026-09-04`, which does not appear among
   the four recorded 2026-09-03 sessions, so the `## Change` gate
   below was satisfied and this session recorded a genuinely
   day-separated measurement — one calendar day after all four
   same-hour sessions in items 1-4.

   **First sub-run (superseded — built via a shortcut that does not
   reproduce; kept here only for the audit trail, see the
   reconciliation below).** Built `9fcfff3f` and `cf416d85` in two git
   worktrees, but seeded each worktree's `o/3p` by `cp -r`-ing an
   already-fetched cache from a third clone instead of letting each
   worktree run its own `--make fetch`. That produced *some* working
   binaries (hashes `f67e7b16c6831f280f0590ce79b45cee1344d8fece0d2760090fca4d452c2e9f`
   for `9fcfff3f` and `cbfd6712f56c616b62c30f594feed5d8ab5b1101c0980af92d4244f5c06a20bb`
   for `cf416d85`) and a 12-pair interleaved comparison that read "no
   stable direction" — but a fresh-context reviewer, building the same
   two commits in their own fresh clone, got two DIFFERENT hashes
   (`71f1030609723add88595beb1da001e861919297f8996a8916e3250de4f4c22d`
   for `9fcfff3f`, `9bcfcd29dde5d3829f4664d13a7f382f5168e46313178415e08c92d326675d2b`
   for `cf416d85`) and flagged the mismatch. The same review also
   caught a real arithmetic bug in this sub-run's "excluding the two
   most volatile pairs" analysis (a Python slice bug took the first 6
   of 12 pairs rather than actually excluding pairs 7 and 8, silently
   turning a claimed "+0.08%, converges to zero" into what should have
   been "-1.94% pooled / -1.44% mean-of-deltas, a sign-flipped swing of
   comparable size" — corrected value shown for the record, but this
   entire sub-run is superseded below rather than relied on).

   **Hash-discrepancy investigation and reconciliation.** Root-caused
   directly, not assumed: rebuilt both commits a second time, in two
   more fresh git worktrees, this time letting each run its own real
   `--make fetch` (no `cp` cache-seeding shortcut) followed by
   `--make build`. Result: `9fcfff3f` → exactly
   `71f1030609723add88595beb1da001e861919297f8996a8916e3250de4f4c22d`
   and `cf416d85` → exactly
   `9bcfcd29dde5d3829f4664d13a7f382f5168e46313178415e08c92d326675d2b` —
   bit-for-bit the SAME hashes the reviewer independently obtained,
   for BOTH commits. So the build system itself is not the source of
   nondeterminism (`cosmic/embed/floor.tl`'s fixed-epoch mtime handling
   and the deliberate no-`git describe` version stamp
   (`cmd/cosmic/embed_gen.tl`'s `declared_version`) are exactly the
   reproducibility engineering that makes this hold): the mismatch was
   this session's own methodological shortcut — seeding `o/3p` with a
   plain `cp -r` (which does not preserve source mtimes; copied files
   land with "now" as their mtime) instead of a real per-worktree
   `--make fetch`, which most likely disturbed the incremental build's
   own mtime-based staleness tracking (`_make/stamp.tl`,
   `_make/readstamp.tl`, `project.mk`'s `srcdeps_<stem>`) enough to
   change some generated artifact's bytes without changing its
   function. **Conclusion: the binary hash IS a reliable fresh-session
   integrity check when a build follows the documented procedure
   (`--make fetch` then `--make build`, no shortcuts) — this session's
   first sub-run just didn't follow it.** The corrected, verified
   hashes above are this item's canonical record for these two
   commits' binaries going forward.

   **Corrected sub-run (authoritative for this session) — 12 fresh
   interleaved, order-randomized pairs, `run.lua --only
   re_match_log_line`, on the two verified binaries above** (order
   generated before running: 6 old-first, 6 new-first):

   | pair | old (9fcfff3f) ns/op (spread) | new (cf416d85) ns/op (spread) | delta |
   |---|---|---|---|
   | 1 | 4083.48 (±4.3%) | 4261.29 (±2.8%) | +4.35% |
   | 2 | 4092.81 (±3.1%) | 4462.86 (±7.0%) | +9.04% |
   | 3 | 4182.85 (±30.0%) | 4215.32 (±8.9%) | +0.78% |
   | 4 | 4214.22 (±4.0%) | 4420.18 (±4.1%) | +4.89% |
   | 5 | 4235.06 (±4.2%) | 4210.70 (±2.6%) | -0.58% |
   | 6 | 4168.57 (±4.8%) | 4300.66 (±3.3%) | +3.17% |
   | 7 | 4112.69 (±6.0%) | 4358.06 (±42.1%) | +5.97% |
   | 8 | 4146.54 (±6.4%) | 4217.43 (±1.5%) | +1.71% |
   | 9 | 4172.62 (±5.6%) | 4256.53 (±12.6%) | +2.01% |
   | 10 | 4139.99 (±0.8%) | 4252.23 (±1.0%) | +2.71% |
   | 11 | 4170.92 (±5.2%) | 4680.04 (±13.2%) | +12.21% |
   | 12 | 4141.82 (±1.9%) | 4297.33 (±4.2%) | +3.75% |

   11/12 (92%) pairs read "new slower" (regression direction); mean
   delta +4.17%, median +3.46%, stdev of per-pair deltas 3.57%; pooled
   (mean of all 12 old readings vs mean of all 12 new readings) delta
   +4.15%, pooled median delta +2.93%. Not driven by the single largest
   pair: excluding pair 11 (the biggest outlier, +12.21%) leaves 10/11
   (91%) same direction, mean +3.44%, median +3.17% — the signal holds
   with any one pair removed.

   selfcheck A/A noise floor on these SAME verified binaries (`gate.tl
   selfcheck --only re_match_log_line`, both sides the identical
   binary): `cf416d85` vs itself +0.6% (spread ±3.1%/±23.1% on the two
   individual passes); `9fcfff3f` vs itself -0.3% (spread ±5.1%/±4.6%).
   Both same-binary controls landed within ±1% of zero — a materially
   quieter noise floor than this session's own first (superseded)
   sub-run showed (-10% to +5%, spread up to 22%) or than sessions 1-4
   showed, though still not zero. The measured +4.15% pooled mean sits
   clearly outside this control band. (A per-pair `gate.tl compare
   --baseline-bin` run on pair 11 alone, the largest single delta,
   reads "ok" rather than "regression" — that tool judges one pair
   against its own within-run spread, ±13.2% here, and does not see
   the cross-pair 11/12 consistency; the aggregate table above is the
   stronger evidence, exactly per `measurement.md`'s point that
   within-run spread understates cross-run variance and that direction
   is read from interleaved repetition, not from a single pass.)

   **Verdict of this session's corrected, authoritative data: a real,
   consistent regression — same direction as sessions 1 and 4, not
   sessions 2 and 3.** This reverses the "no stable direction" reading
   this session originally reported before its binaries were shown not
   to reproduce; the corrected binaries and re-measurement are what
   this item now carries forward.

   A fresh-context reviewer also ran an independent 4-pair spot-check
   on their own separately-built (also hash-verified) binaries and got
   4/4 "new slower", pooled +3.4% — too few pairs to be dispositive on
   its own by this item's own bar (≥6 pairs), but a fifth data point
   that also leans "regression," consistent with the corrected 12-pair
   table above. It was measured the same calendar day (2026-09-04) as
   this session's corrected sub-run, so it does not itself supply the
   second required day-separated session below.

   This is session 1 of the ≥2 day-separated sessions the `## Change`
   gate requires; the verdict logic there does not yet apply on one
   day-separated calendar day alone, however consistent that one day's
   corrected reading is. At least one more session, on a calendar day
   distinct from both 2026-09-03 and 2026-09-04, is still needed before
   `c5wU_p1n9` / `pmIX_ommp` (`3IopfBATkXMfl9qRpLDpmIXommp`) /
   `3IonN6KwrW1QezqdCBs0pa6japm` can be resolved per this item's own
   decision tree — but that next session should note this session's
   corrected direction (regression) going in, not the superseded
   "no stable direction" first reading.

   Raw JSON results and worktree build logs from this session were
   written to an ephemeral scratchpad, not to this item; the tables and
   hashes above are the complete extracted record.

## Change

Ready when: today is not a day any recorded session ran on. Every
session in Evidence, and every one appended below, records its date;
the puller runs

    date -u +%F

first and proceeds only if that date appears nowhere in this spec's
session records (2026-09-03 ×4, 2026-09-04 ×1 calendar day so far —
see the "Session dates recorded" line above Evidence item 5 for the
running tally). A match means this session cannot add a day-separated
measurement — drop the claim bare (the item is fine as written) and
let the next day's session take it.

Run the cross-session comparison `9fcfff3f` vs `cf416d85` on
`re_match_log_line` (interleaved, order-randomized, at least 6 pairs
per session, `_perf/gate.tl selfcheck <A.json> <B.json> --only
re_match_log_line` for the noise floor) in at least two MORE sessions
genuinely separated by calendar days, not hours, per
`skills/optimize/measurement.md`'s own rule. **Build each side with a
real, per-checkout `bin/cosmic --make fetch` followed by `bin/cosmic
--make build` — no shortcuts (e.g. copying an already-fetched `o/3p`
cache between worktrees), which this item's own session 1 showed does
not reproduce and can silently swap in a different, non-canonical
binary.** Verify each binary's `sha256sum o/bin/cosmic` against this
item's recorded hashes for the commit before measuring
(`9fcfff3f` → `71f1030609723add88595beb1da001e861919297f8996a8916e3250de4f4c22d`,
`cf416d85` → `9bcfcd29dde5d3829f4664d13a7f382f5168e46313178415e08c92d326675d2b`)
— a mismatch means investigate before trusting any measurement built
on it, the same way this session's own did. Record each session's raw
pair table and selfcheck noise band on this item as it runs (do not
overwrite prior rounds — append). One of the required ≥2 day-separated
sessions is now recorded (Evidence item 5, 2026-09-04, corrected in
place — reads "regression"); at least one more, on yet another
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
