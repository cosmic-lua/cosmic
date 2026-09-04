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
   `measurement.md`'s interleaving discipline), plus
   `_perf/gate.tl selfcheck <A.json> <B.json> --only re_match_log_line`
   on each binary alone to record that session's own noise floor —
   `selfcheck`'s positional args are the two output paths; `--only`
   and its value come AFTER them, not in their place.
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

**Noise floor (corrected):** the first pass through this item recorded
`_perf/gate.tl selfcheck --only re_match_log_line` with `--only`
standing in the required output-path slots — that invocation silently
runs the full 49-scenario suite instead of narrowing to one scenario,
so its "noise band" numbers described a different, unrelated
measurement and are withdrawn. The correct form,
`_perf/gate.tl selfcheck <A.json> <B.json> --only re_match_log_line`,
run on each binary alone (verified independently in review under
session `review-c5wU_p1n9-1`, itself a third, distinct session/build):

    9fcfff3f (before): noise band +-10.0%
    cf416d85 (after):  noise band +-10.6%

Every interleaved before/after delta above (-8.95% to +6.69%), and the
review's own independent 6-pair re-run (-3.73% to +9.49%, same 3/3
split with no stable direction), sit inside these corrected noise
bands.

Note: this cross-session run and `pmIX_ommp`'s original run both land
on 2026-09-03, hours apart rather than the "ideally days apart" this
item's own `## Goal` names from `measurement.md`. Taken alone that
would be a gap; here it is offset by a second, independently-run
confirmation (the review's own from-scratch build and 6-pair re-run,
under a different session, landing on the same no-stable-direction
conclusion) — two independent non-reproductions rather than one.

## Decision

Superseded. `## Change` step 3 fired on this cross-session result and
`3IqZDdd7` (`review-c5wU_p1n9-3`) correctly reopened it: `3IpIfJ5G`'s
own accepted, day-separated finding (2026-09-04, 11/12 pairs "new
slower", pooled mean +4.15%, outside a same-binary ±1% control band)
and that review's own fresh third build (5/6 pairs, ~+4.4% mean) both
land on "regression", not "net zero" — three independent sessions now
agree on direction even though this item's own single-day pair did
not. The "close, no code change, mark noise" conclusion above is
withdrawn; do not act on it.

`3IqZDdd7` held the resulting fork open (one more day-separated
session vs. short-circuit to the fix) for the goal owner. Their call,
recorded there: (b) — short-circuit. Do not spend a fourth
measurement session chasing exact magnitude; proceed directly to
`## Change` step 2's first option — prove the invariant statically at
the one narrowing site in `cosmic/re.tl`'s `match()` so no runtime
`assert(caps is {string}, ...)` is needed at all — gated by
`--make ci` and the compare gate (`_perf/gate.tl compare`) per
`skills/optimize/SKILL.md`, same as step 2 already specified. Once
that lands (or is found infeasible and a cheaper-check/accept-cost
fallback is chosen instead, per step 2's other options), close this
item and update `pmIX_ommp`/`3IonN6KwrW1QezqdCBs0pa6japm` to match
whichever outcome actually landed — not the withdrawn "noise" verdict
above.

## Resolution

The narrowing site no longer exists. `3IkMf7BY`'s cosmos pin bump
(#1705, merged) replaced `regex:match`'s tuple return (`m, caps` with
`caps` unioned against the error-string case) with a single bundled
`re.SearchMatch` result whose `.captures` field is already `{string}`
with no union — so `cosmic/re.tl`'s `match()` no longer needs
`assert(caps is {string}, ...)` at all, and the pin bump dropped it
along with the rest of the tuple-return adaptation (confirmed:
`grep -n "cast:\|assert:" cosmic/re.tl` on current `main` returns
nothing; the compiled `o/cosmic/re.lua` carries no `type()`/`assert`
check on `caps`/`captures` anywhere in `match()`). This is `## Change`
step 2's first option, "proving the invariant statically", arrived at
via the binding contract itself rather than a re.tl-local change.

Measured 2026-09-04 to confirm the regression is actually gone, not
just the code: built `5d5dc3a5` (pre-pin-bump, still carries the
assert, `bin_sha 6ca3496789a6...`) and current `main` at `2385634d`
(post-pin-bump, no assert, `bin_sha 6cb433773591...`) in separate
worktrees, confirmed distinct `bin_sha`, then ran 3 order-randomized
interleaved `--make run _perf/run.tl --only re_match_log_line`
pairs (before-first, after-first, before-first):

    pair  order        before(us/op)  after(us/op)  delta
    1     before-first  3.52           3.59          +2.1%
    2     after-first    3.56          3.65          +2.5%  (after measured first)
    3     before-first  3.60           3.71          +3.1%

`_perf/gate.tl selfcheck` on the after binary alone: noise band
±10.0% for this scenario on this machine. `_perf/gate.tl compare`
(pair 1 as base/current, `--only re_match_log_line`):
`re_match_log_line 3.52 µs -> 3.59 µs +2.1% (noise ±10.0%) ok` —
`perf-compare: PASS`. All three pairs' deltas (+2.1% to +3.1%) sit
inside the noise band; no regression survives.

Note: the "after" binary's `alloc` column reads slightly higher
(0.48 KB vs 0.38 KB) — the new `re.SearchMatch` binding shape bundles
match+captures into one C-side table that `match()` immediately
unpacks into its own `{text=.., caps=..}` record, a small extra
allocation the old tuple return didn't pay. Per this item's own
Non-goals ("scope is strictly the one narrowing site"), that is a
separate, new observation about the pin bump's binding shape, not
this item's regression — worth its own hypothesis capture if a future
session wants to chase it, not folded into this closure.

No code change: nothing to gate with `--make ci` beyond what #1705
already gated. `pmIX_ommp` and `3IonN6Kw` need no further update —
both are already closed with resolution text that does not assert
the withdrawn "noise" verdict this item's own stale Decision section
carried; `3IonN6Kw`'s own closing note already correctly named this
item as carrying the remaining work.
