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
`re.match`'s capture return on the scenario's hot path — a plausible
mechanism (an added `assert` on every call), but this is a
prediction, not a finding — the builder's own local test (reverting
`cf416d85` and remeasuring, ~4.4-4.8µs/op either way, within the
scenario's own ±2-3% local spread) already argues against it, but
was not run with the interleaving/aggregate rigor
`3IjAuurwj3USV0a7jAPEas3TLvu` used, nor against binaries matching the
exact CI SHAs (`base 7cf051829899`, `current 240621c27e3c`).

## Access

Read access to `cosmic-lua/cosmic` (the release run's Actions logs
cited above, and the tree itself to build and bisect it locally).

## Change

Research slice, no PR: the deliverable is a recorded verdict on this
item (reproduced or not; if reproduced, whether `cf416d85` is the
cause) plus a follow-up item for whatever answer that verdict points
to.

1. Build `c60dcf19` (baseline) and `63cc3a603fadd713e4edb8d131620904ecd467ba`
   (current — the release window's tip actually compared; do not
   substitute a later `origin/main`) in separate worktrees per
   `skills/optimize/measurement.md`'s noise discipline (pinned CPU
   governor / quiet machine, not a shared CI runner) and confirm each
   build's `_perf` binary-hash label matches the CI log
   (`base 7cf051829899`, `current 240621c27e3c`) before trusting any
   measurement against them.
2. Run `o/bin/cosmic --make run _perf/gate.tl selfcheck A.json B.json --only re_match_log_line`
   on EACH binary alone first, to establish the real local noise floor,
   the way `3IjAuurwj3USV0a7jAPEas3TLvu` did.
3. Run at least 3 interleaved (base/cur/base/cur/…, per
   `measurement.md`) cross-binary comparisons via
   `o/bin/cosmic --make run _perf/run.tl --only re_match_log_line`,
   aggregate the readings, and compare the aggregate median delta and
   any sign flips against both binaries' own self-check noise bands.
4. If `re_match_log_line` does not reproduce a real regression outside
   CI (i.e. the aggregate holds well inside self-noise, signs flip
   under interleaving): record that verdict on this item with the
   commands and numbers that showed it, and stop — no follow-up item
   needed, `0pa6_japm` unblocks as "noise, dismissed with evidence."
5. If it reproduces: `git bisect` the 9-commit window above using the
   same local `re_match_log_line`-only measurement as the bisect
   script's pass/fail, confirm (or rule out) `cf416d85` specifically,
   and record the bisected commit and its mechanism (read the diff) on
   this item.
6. Either way, file a follow-up item for whatever the verdict demands:
   a fix under `skills/optimize/SKILL.md` if a specific commit
   regressed `re_match_log_line`, or nothing further if it was noise.

## Non-goals

Not re-litigating D34/D35 (the gate's retry/dismissal design) — this
item takes that design as given and works within it, same as
`3IjAuurwj3USV0a7jAPEas3TLvu` did. Not touching
`.github/workflows/release.yml` — nothing here suggests the workflow
is wrong. Not investigating `http_fetch_get_with_headers`, which
stayed inside its own retry-noise class (`flagged only in the retry
— not reproduced, counted as noise`) and needed no restoration path —
it is not part of the FAIL verdict this item exists to explain.
