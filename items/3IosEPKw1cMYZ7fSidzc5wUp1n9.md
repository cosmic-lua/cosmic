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
