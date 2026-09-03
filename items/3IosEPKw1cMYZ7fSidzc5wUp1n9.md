## Goal

Board item `3IopfBATkXMfl9qRpLDpmIXommp` locally reproduced (within
one session, order-randomized interleaved measurement, 6/6 pairs
non-flipping) a small, consistently-directional slowdown in
`re_match_log_line` (`_perf/bench/re_bench.tl`) on
`63cc3a603fadd713e4edb8d131620904ecd467ba` vs its release baseline
`c60dcf19`, and isolated it specifically to `cf416d85` ("casts: close
all 12 proved-value narrowing sites", #1646) vs its immediate parent
`9fcfff3f` (5/6 pairs, same direction, ~+4.3% mean / +2.8% median).
The mechanism is confirmed by diffing `o/cosmic/re.lua` before/after:
`cf416d85` replaced a compile-time-only `-- cast:` comment in
`cosmic/re.tl`'s `match()` with a runtime
`assert(caps is {string}, ...)`, compiling to `assert(type(caps) ==
"table", "...")` executed on every `re.match()` call.
`re_match_log_line` calls `re.match` once per op and measures
~4.1-4.6µs/op, so one added `type()`+`assert()` call per op is a
plausible few-percent cost at this scale.

Per `skills/optimize/measurement.md`'s own rule — a release-gating
regression on a single tight-loop or fixed-overhead scenario needs
reproduction across SEPARATE SESSIONS, ideally days apart, before it
is written into a board item as a confirmed finding — `pmIX_ommp`'s
within-session evidence, however internally consistent (no sign
flips across 6 full-window and 6 isolated-commit interleaved pairs),
is not yet sufficient on its own to certify this as a confirmed
regression. This item exists to get that second, independent
confirmation and then act on it.

## Change

1. In a FRESH session (a different container/day than
   `pmIX_ommp`'s), repeat its isolation measurement exactly: build
   `9fcfff3f` (cf416d85's immediate parent) and `cf416d85` in separate
   worktrees (`bin/cosmic --make fetch && bin/cosmic --make build` in
   each), confirm the two `_perf` `bin_sha` labels differ, then run at
   least 6 order-randomized interleaved comparisons of
   `o/bin/cosmic --make run _perf/run.tl --only re_match_log_line`
   between the two binaries (3 "before-first", 3 "at-first", per
   `measurement.md`'s interleaving discipline), plus a
   `_perf/gate.tl selfcheck --only re_match_log_line` on each binary
   alone to record that session's own noise floor.
2. If the cross-session run reproduces the same direction
   (`cf416d85`'s build reading slower) at a comparable order of
   magnitude to `pmIX_ommp`'s +2.8-4.3%: treat the regression as
   confirmed. Then, under `skills/optimize/SKILL.md`'s loop, evaluate
   a fix scoped to this ONE narrowing site in `cosmic/re.tl`'s
   `match()` — options include: proving the invariant statically so
   no runtime check is needed at all, finding a cheaper runtime check,
   or explicitly accepting the cost and adjusting the scenario's
   compare baseline instead of the code. Gate any code change with
   `--make ci` and the compare gate (`_perf/gate.tl compare`) per the
   skill.
3. If the cross-session run does NOT reproduce (holds inside that
   session's self-check noise band, or flips sign): record that as
   the deciding evidence that `pmIX_ommp`'s within-session
   reproduction was itself an artifact of session/container noise
   structure despite its internal consistency, close this item with
   no code change, and note on `pmIX_ommp` and
   `3IonN6KwrW1QezqdCBs0pa6japm` that the original CI flag is noise,
   dismissed — now with the cross-session evidence the single-session
   result lacked.

## Non-goals

Not relitigating `cf416d85`'s other 11 narrowing sites — scope is
strictly the one site in `cosmic/re.tl`'s `match()` that
`re_match_log_line` exercises. Not re-litigating D23/D30's
assert-justification policy — if the assert is kept, it remains
justified as-is under D23; the only question here is its cost on this
one hot path, not its legitimacy. Not touching
`.github/workflows/release.yml` or the gate's retry/dismissal design
(D34/D35) — same as `pmIX_ommp`'s own non-goals.

## Cross-session result (recorded 2026-09-03, fresh container)

Ran `## Change` step 1 exactly, in a session/container distinct from
`pmIX_ommp`'s: built `9fcfff3f` (`bin_sha 71f1030609723add8...`) and
`cf416d85` (`bin_sha 9bcfcd29dde5d382...`) in separate worktrees,
confirmed distinct `bin_sha`, then ran 6 order-randomized interleaved
`o/bin/cosmic --make run _perf/run.tl --only re_match_log_line`
comparisons (3 before-first, 3 after-first):

    pair  order        before(us/op)  after(us/op)  delta      direction
    1     before-first  3.24           2.95          -8.95%     after faster
    2     before-first  3.02           3.08          +1.99%     after slower
    3     before-first  3.04           3.02          -0.66%     after faster
    4     after-first   3.22           3.16          -1.86%     after faster
    5     after-first   3.14           3.23          +2.87%     after slower
    6     after-first   2.99           3.19          +6.69%     after slower

Mean delta ~= +0.01% (net zero). 3/6 pairs read "after faster", 3/6
read "after slower" — direction does not hold, unlike `pmIX_ommp`'s
5/6-6/6 same-direction result.

`_perf/gate.tl selfcheck --only re_match_log_line` on each binary
alone (that session's own noise floor):

    9fcfff3f (before): 3.13 -> 2.98 us (-5.0%), reported noise band +-12.0%
    cf416d85 (after):  3.04 -> 3.06 us (+0.9%), reported noise band +-10.0%

Every interleaved before/after delta above (-8.95% to +6.69%) sits
inside each binary's own self-check noise band, and the sign is not
stable pair to pair.

## Decision

This is `## Change` step 3's outcome: the cross-session run does NOT
reproduce `pmIX_ommp`'s regression — it holds inside noise and flips
sign. Per this item's own decision tree: close with no code change;
`pmIX_ommp` (`3IopfBATkXMfl9qRpLDpmIXommp`) and
`3IonN6KwrW1QezqdCBs0pa6japm`'s original CI flag is noise, and should
be marked dismissed on those items — the within-session result did
not survive a second, independent session, exactly the case
`measurement.md`'s cross-session-reproduction rule exists to catch.
