## Goal

`release.yml`'s scheduled run on 2026-09-03 (run `33746684991`,
https://github.com/cosmic-lua/cosmic/actions/runs/33746684991, head
sha `63cc3a603fadd713e4edb8d131620904ecd467ba`) went red at the
`compare against the previous release` step, job `100620662371`,
blocking that day's release. This item exists because "lane repair:
release.yml is red" (board item `3IonN6KwrW1QezqdCBs0pa6japm`) turned
out to have no PR-shaped fix — a builder session investigated and
found the flagged scenario's own gate output, and its own local
revert-and-remeasure, both point to noise rather than a real
regression, but reaching a fully reproduced, reviewable verdict (in
the shape `3IjAuurwj3USV0a7jAPEas3TLvu` set for exactly this
situation on 2026-09-01) needs a local rebuild this item hands off to
a fresh session.

Evidence gathered so far (`get_job_logs`, job `100620662371`,
`return_content: true`):

```
re_match_log_line                 3.35 µs ->      3.40 µs     +1.5%  (noise  ±10.0%)  regression
...
perf-compare: re_match_log_line flagged in pass 1 and read quiet on the retry, but no same-binary control explains the gap -- counted as a regression
binaries: base 7cf051829899  current 240621c27e3c  (differ)
...
49 scenarios: 1 regression, 1 faster, 46 ok, 1 noise, 0 new, 0 missing, 0 error, 0 baseline-error, 0 malformed
perf-compare: FAIL
perf-baseline: OK 2026-09-02-c60dcf1
```

`re_match_log_line` is flagged via D34/D35's "quiet on retry, no
same-binary control explains the gap" restoration path — the same
mechanism that flagged (and was later dismissed as noise for)
`http_stream_read_1mb`/`fs_barf_slurp_64k` on 2026-09-01
(`3IjAuurwj3USV0a7jAPEas3TLvu`'s evidence) and `embed_run_startup` on
2026-08-31. The builder session that investigated this run (report
attached to `0pa6_japm`'s history) added detail beyond what the CI
log alone shows: the scenario's first raw current-side sample read
3.74µs against a per-scenario median-tiebroken baseline of 3.35µs
(+11.6%, over the 10% bar) — the `+1.5%` printed above is the
POST-tiebreak median comparison, not the sample that tripped the
gate — and the retry/self-check samples (3.40µs, 3.53µs) put the
largest same-binary pairwise swing (current-vs-retry) at -9.09%, just
under `loudest_control`'s 10% credit threshold, so `reproduce.restore`
correctly restored the "regression" classification per its documented
rule.

The baseline this release compared against is tagged
`2026-09-02-c60dcf1` — commit `c60dcf19` ("fetch tests: narrow the 18
nil-flow sites in cosmic/fetch/**", #1634) IS the previous release's
baseline, not a candidate cause. The commits actually in the diff
window (`git log --oneline c60dcf19..63cc3a60`, 9 commits):

```
63cc3a60 casts: share one is_present helper for the 3 boolean capability probes (#1647)
3473dca7 template: html mode's URL, JS, and CSS contexts, each behind its own safe type (#1648)
cf416d85 casts: close all 12 proved-value narrowing sites (#1646)
9fcfff3f docs: fix nil-flow.md's Method to name the real proof-of-life probe (#1645)
f2d7627d perf bench: close the 11 nil-flow sites the tooling/cosmic sweeps never reached (#1644)
0608b0bd make: widen the engine-rebuild dependency to the _tool/** tests that spawn it (#1641)
e414a290 sandbox: close the 12 remaining library nil-flow sites in cosmic/sandbox/ (#1640)
c13f4a56 make: declare o/bin/cosmic as a reads: dependency of fixtures_test.tl (#1636)
4e2f3fc4 coverage: refuse --baseline outside the recording environment (#1637)
```

`re_match_log_line` (`_perf/bench/re_bench.tl`) measures
`cosmic.re`'s `match` on a fixed log line. `cf416d85` ("casts: close
all 12 proved-value narrowing sites", #1646) is the only commit in
the window that touches `cosmic/re.tl`: it replaces a `-- cast:`
comment and cast with a runtime `assert(... is ...)` narrowing
`re.match`'s capture return on the scenario's hot path.

## Access

Read access to `cosmic-lua/cosmic` (the release run's Actions logs
cited above, and the tree itself to build and bisect it locally).

## Change

Research slice, no PR: the deliverable is a recorded verdict on this
item (reproduced or not; if reproduced, whether `cf416d85` is the
cause) plus a follow-up item for whatever answer that verdict points
to.

## Non-goals

Not re-litigating D34/D35 (the gate's retry/dismissal design) — this
item takes that design as given and works within it, same as
`3IjAuurwj3USV0a7jAPEas3TLvu` did. Not touching
`.github/workflows/release.yml` — nothing here suggests the workflow
is wrong. Not investigating `http_fetch_get_with_headers`, which
stayed inside its own retry-noise class (`flagged only in the retry
— not reproduced, counted as noise`) and needed no restoration path —
it is not part of the FAIL verdict this item exists to explain.

## Verdict

**Environment.** Worktrees built from the exact commits: baseline
`c60dcf19` (bin_sha `7cf051829899`) and current tip
`63cc3a603fadd713e4edb8d131620904ecd467ba` (bin_sha `240621c27e3c`) —
both hashes match the CI log's `binaries: base 7cf051829899  current
240621c27e3c` exactly, byte for byte. Container has no cpufreq
governor to pin; per `measurement.md` this means host
placement/mitigation state is unobservable here.

**Self-check noise floor** (`_perf/gate.tl selfcheck --only
re_match_log_line`, 4 trials each side): baseline binary swung -3.8%,
+0.1%, -1.9%, -0.8% (tight, ≤4%); current-tip binary swung +14.8%,
-10.5%, +4.6%, -2.8% (much wider, up to ±15%) — this container is
noisier than CI's own quoted spreads for this scenario.

**Full-window interleaved comparison** (baseline vs current tip,
`_perf/run.tl --only re_match_log_line`, 6 order-randomized pairs, 3
base-first + 3 cur-first):

```
pair  order       base(µs)  cur(µs)   cur-base
1     base,cur    4.15      4.50      +8.4%
2     base,cur    4.30      4.40      +2.3%
3     base,cur    4.16      4.35      +4.6%
4     cur,base    4.16      4.52      +8.7%
5     cur,base    4.13      4.30      +4.1%
6     cur,base    4.25      4.41      +3.8%
```
Current read higher in 6/6 pairs, in both orderings — no sign flip.
Aggregating these 6 plus 4 selfcheck-pair samples per side (14
samples each): base median 4.23µs, current median 4.47µs → **+5.7%
median / +6.6% mean**.

**Bisection, isolated to `cf416d85`.** Built its immediate parent
`9fcfff3f` and `cf416d85` itself. 6 interleaved pairs (3+3,
order-randomized):

```
pair  order        before(µs)  at-cf416d85(µs)  delta
1     before,at    4.37        4.35             -0.5%
2     before,at    4.25        4.54             +6.8%
3     before,at    4.24        4.38             +3.3%
4     at,before    4.34        4.12             +5.3%
5     at,before    4.28        4.27             +0.2%
6     at,before    4.59        4.14             +10.9%
```
`cf416d85`'s build read higher in 5/6 pairs (1 near-tie). Aggregate:
before median 4.245µs, at-cf416d85 median 4.365µs → **+2.8% median /
+4.3% mean** — same direction, same order of magnitude as the
full-window delta, consistent with `cf416d85` accounting for most of
it.

Diff-inspection of the other 8 commits in the window (`4e2f3fc4`,
`c13f4a56`, `e414a290`, `0608b0bd`, `f2d7627d`, `9fcfff3f`,
`3473dca7`, `63cc3a60`) confirms none touch `cosmic/re.tl` or any code
`re_match_log_line` executes — ruling all of them out analytically,
not just statistically.

**Mechanism, confirmed by compiled output.** `git show cf416d85 --
cosmic/re.tl`:
```diff
-    -- cast: captures, past the no-match/failure guard
-    return {text = m, caps = caps as {string}}
+    assert(caps is {string}, "a match always carries the capture table") -- assert: captures, past the no-match/failure guard
+    return {text = m, caps = caps}
```
Diffing compiled `o/cosmic/re.lua` before/after: before, the line
compiles to `return { text = m, caps = caps }` with zero runtime cost
(a Teal cast is compile-time only); after, it compiles to
`assert(type(caps) == "table", "...")` executed on every
`re.match()` call — one extra `type()` and one `assert()` call on a
~4.2µs op.

**Conclusion.** `re_match_log_line` DOES reproduce a real,
non-flipping, mechanism-confirmed slowdown within this session,
isolated to `cf416d85`, of roughly +3-7% depending on the comparison
— stronger evidence than the noise dismissed on 2026-09-01
(`3IjAuurwj3USV0a7jAPEas3TLvu`, which showed sign flips). This is
**not** the "noise, dismissed" outcome the Change anticipated as one
branch. Per `skills/optimize/measurement.md`'s own rule — a
tight-loop/fixed-overhead scenario's regression needs reproduction
across SEPARATE SESSIONS, ideally days apart, before it is written
into a board item as a confirmed finding — this single session's
internally-consistent evidence is not yet sufficient to certify the
regression outright either. Follow-up filed:
`3IosEPKw1cMYZ7fSidzc5wUp1n9` (cross-session confirmation, then fix
or accept). `3IonN6KwrW1QezqdCBs0pa6japm` should NOT be closed as
"noise, dismissed" on this evidence — see that item's own history for
how it resolves once the follow-up lands.
