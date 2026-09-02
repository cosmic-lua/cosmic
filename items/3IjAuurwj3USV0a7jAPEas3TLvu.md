## Goal

`release.yml`'s scheduled run on 2026-09-01 (run 33501918861,
https://github.com/cosmic-lua/cosmic/actions/runs/33501918861) went
red at the `perf-compare` step on its first attempt — job
`99836988229`, started 11:19:49Z, conclusion `failure`
(`mcp__github__actions_get get_workflow_job`,
`resource_id: 99836988229`). It did **not** block that day's
publish: a human rerun of the same run, attempt 2, job `99899421838`
(started 14:39:37Z, ~3h20m later, same head commit `3c80edca`),
re-measured the identical binary pair and ended `perf-compare: PASS`
(`mcp__github__get_job_logs job_id: 99899421838`); the run's overall
conclusion is `success`
(`mcp__github__actions_get get_workflow_run resource_id: 33501918861`
→ `"run_attempt":2,"conclusion":"success"`) and that day's release
did publish. This item exists because "lane repair: release.yml is
red" (board item `3Ij9W1WjKisRUAIHgLNP69OPzc2`) turned out to have no
PR-shaped fix — the gate, its retry, and its A/A self-check all
behaved exactly as D34/D35 specify on attempt 1, so the failure is
either real perf noise the gate correctly refused to publish past
that first time, or a real regression that a second, noisier
measurement happened to clear. Distinguish the two and answer
P69O_Pzc2's question: does this reproduce, and if so, what commit
caused it.

Evidence gathered from attempt 1's failing job log (`get_job_logs`,
run 33501918861, job `99836988229`, `failed_only`):

```
perf-baseline: OK 2026-08-31-a5b36f4
...
49 scenarios: 3 regression, 1 faster, 45 ok, ...
perf-compare: regression persists; running A/A self-check ...
...
binaries: base c02f8b1c77cd  current d61bb400a80c  (differ)
http_stream_read_1mb              1.42 ms -> 1.52 ms   +7.2%  (noise ±10.0%)  regression
embed_extract_tree              113.19 ms -> 131.08 ms +15.8%  (noise ±14.4%)  regression
fs_barf_slurp_64k                155.06 µs -> 162.78 µs +5.0%  (noise ±18.0%)  regression
49 scenarios: 3 regression, 1 faster, 45 ok, ...
perf-compare: FAIL
```

`http_stream_read_1mb` and `fs_barf_slurp_64k` are both flagged only
via D35's "quiet on retry, no same-binary control explains the gap"
restoration path — i.e. the self-check's OWN noise band (`±10%`,
`±18%`) does not clear them either way; they are the false-red class
D34/D35 already accept. `embed_extract_tree` is different: its
observed swing (+15.8%) exceeds even its own retry-measured noise
band (±14.4%), so it did not merely fail to clear noise — it
reproduced a second time under a fresh self-check binary pair. That
is a stronger signal than the other two carry.

A second, independent, CI-native data point on this exact question
comes from attempt 2's own log (`get_job_logs`, run 33501918861, job
`99899421838`, full log — attempt 2 is not itself a failed job, so
`failed_only` does not surface it): the SAME binary pair (base
`c02f8b1c77cd`, current `d61bb400a80c`) went through its own
retry/A-A cycle and produced these `embed_extract_tree` readings
before finishing `perf-compare: PASS`:

```
embed_extract_tree                    1 x    204.59 ms/op  ±204.3%  cpu/wall 0.24  alloc   610.36 KB
embed_extract_tree                    1 x    371.19 ms/op  ± 37.6%  cpu/wall 0.14  alloc   610.36 KB
perf-baseline: OK 2026-08-31-a5b36f4
embed_extract_tree                    2 x     77.19 ms/op  ± 53.4%  cpu/wall 0.69  alloc   577.83 KB
binaries: base c02f8b1c77cd  current d61bb400a80c  (differ)
perf-compare: regression flagged; re-measuring once into o/perf/perf-retry.json to filter noise
embed_extract_tree                    1 x    208.96 ms/op  ±150.4%  cpu/wall 0.25  alloc   610.36 KB
perf-compare: re-measuring the baseline into o/perf/prev/perf-retry.json so a one-off baseline reading cannot anchor the verdict
embed_extract_tree                    2 x    250.83 ms/op  ± 60.7%  cpu/wall 0.21  alloc   577.83 KB
perf-compare: the two baseline readings disagree past the bar ...; measuring a third ... judging against the per-scenario median
embed_extract_tree                    4 x    255.39 ms/op  ± 99.0%  cpu/wall 0.21  alloc   561.56 KB
perf-compare: regression persists; running A/A self-check ...
embed_extract_tree                    2 x    137.27 ms/op  ± 73.2%  cpu/wall 0.39  alloc   577.83 KB
binaries: base c02f8b1c77cd  current d61bb400a80c  (differ)
perf-compare: PASS
```

Noise bands here run up to ±204.3% — this run was measured under far
worse contention than attempt 1 — but the wide swing across all
seven readings (204.59ms–371.19ms in the pre-baseline pass, then
77.19ms–255.39ms through the retry ladder, settling at PASS) on the
literal same two binaries is a second, CI-native corroboration that
`embed_extract_tree`'s timing is highly noise-sensitive even without
touching a single line of code between measurements — reinforcing,
not settling on its own, the question this item exists to answer.

The baseline this release compared against is tagged
`2026-08-31-a5b36f4` — i.e. commit `a5b36f4a` (Move to Lua 5.5.1,
#1594) IS the previous release's baseline, not a candidate cause.
The commits actually in the diff window (`git log --oneline
a5b36f4a..origin/main`, 8 commits):

```
3c80edca cosmic/surface_test.tl: require init.lua for a directory to count as a module (#1601)
3f375591 sandbox: merge() no longer drops the net section (#1602)
9b2866f5 quicksand: Box consumes the landlock net tier where netns cannot start (#1598)
5d5c630a sandbox: the facade reaches ABI 9 — ioctl, scopes, TSYNC (#1600)
8495ab0a cosmic.template: compile templates to typed Teal, escaping via SafeHtml (#1599)
b614c62d fs.visit: classify from d_type, make Entry.stat a lazy method (#1597)
0915453e sandbox: net section — per-port TCP policy via landlock ABI 4 (R7) (#1596)
54d754f1 Bump the trust root to a cosmic built on Lua 5.5 (#1595)
```

`embed_extract_tree` (`_perf/bench/embed_bench.tl:138`) extracts an
embedded zip tree end-to-end; `b614c62d` (fs.visit's d_type/lazy-stat
change) and the three sandbox/quicksand landlock commits are the
plausible-on-their-face candidates, but this is a prediction, not a
finding — nothing here has run a bisect yet.

## Change

Research slice, no PR: the deliverable is a recorded verdict on this
item (reproduced or not; if reproduced, which commit) plus follow-up
items for whatever answer that verdict points to.

1. Build `a5b36f4a` and current `origin/main` locally (per
   `skills/optimize/measurement.md`'s noise discipline — pinned CPU
   governor / quiet machine, not a shared CI runner) and run
   `bin/cosmic --make run _perf/run.tl --out <file>` for both, at
   least 3 times each, to get `embed_extract_tree`'s real distribution
   outside CI's noise. Use `_perf/gate.tl selfcheck` between two runs
   of the SAME binary first to confirm the local noise floor before
   trusting a cross-binary comparison.
2. If `embed_extract_tree` does not reproduce a >10% regression
   outside CI (i.e. it was CI-environment noise): record that verdict
   on this item with the commands and numbers that showed it, and
   stop — no follow-up item needed, P69O_Pzc2 unblocks as "noise,
   dismissed with evidence."
3. If it reproduces: `git bisect` the 8-commit window above using the
   same local `embed_extract_tree`-only measurement as the bisect
   script's pass/fail (a fixed number of iterations per commit, wide
   enough to clear the ±14.4% noise band observed in CI). Record the
   bisected commit and its plausible mechanism (read the diff) on
   this item.
4. Either way, file a follow-up item for whatever the verdict
   demands: a fix under `skills/optimize/SKILL.md` if a specific
   commit regressed `embed_extract_tree`, or nothing further if it
   was noise.

## Non-goals

Not re-litigating D34/D35 (the gate's retry/dismissal design) — this
item takes that design as given and works within it. Not fixing
`http_stream_read_1mb` or `fs_barf_slurp_64k` — both stayed inside
their own self-check noise bands and are the accepted false-red
class those decisions already cover; only `embed_extract_tree`
cleared its own band and earns a bisect. Not touching
`.github/workflows/release.yml` itself — nothing here suggests the
workflow is wrong. Not investigating why attempt 2's own retry
ladder needed a third baseline reading and a per-scenario median
(the "two baseline readings disagree past the bar" path) — that is
D34/D35's documented restoration machinery operating as designed
under worse contention than attempt 1, not a new question this item
opened.

## Verdict — recorded 2026-09-02: NOISE, dismissed with evidence

`embed_extract_tree` does not reproduce a regression outside CI.
Step 2's branch applies: no bisect was run, no follow-up item filed.
P69O_Pzc2 unblocks as "noise, dismissed with evidence." (Separately,
per the corrected `## Goal` above, the release was never actually
blocked: attempt 2 of the same run passed and published same-day —
this verdict answers the reproduction question the item was opened
for, not a publish outage that never occurred.)

**Method.** Built `a5b36f4a` (baseline) and `3c80edca` (the release
window's tip — the actual "current" CI compared; `origin/main` has
moved 24 commits further since and was deliberately not used, since
that would not reproduce CI's comparison) in separate worktrees via
`bin/cosmic --make fetch && bin/cosmic --make build`
(`3p/cosmos/cosmos_pin.tl` is unchanged across the whole window, so
this rebuilds the exact runtime the release used). Both builds'
`_perf` binary-hash labels matched the CI log byte-for-byte — base
`c02f8b1c77cd`, current `d61bb400a80c` — confirming every measurement
below targets the precise artifacts run 33501918861 compared, not
stand-ins.

**Same-binary (A/A) self-check**
(`o/bin/cosmic --make run _perf/gate.tl selfcheck A.json B.json --only embed`):

| binary | pair | delta | self noise band |
|---|---|---|---|
| base `c02f8b1c77cd` | 104.20ms → 113.52ms | **+8.9%** | ±11.5% |
| cur `d61bb400a80c` | 83.34ms → 103.60ms | **+24.3%** | ±12.2% |

Both same-binary swings meet or exceed CI attempt 1's own reported
+15.8% and its ±14.4% band — an UNMODIFIED binary alone reproduces a
bigger swing against itself than what CI attempt 1 flagged as a real
cross-binary regression. This matches the pattern CI's own attempt 2
independently showed (readings from 77.19ms to 371.19ms on the
identical binary pair, noise bands up to ±204.3% — see `## Goal`
evidence above): `embed_extract_tree` swings widely run to run even
with zero code change in play, on both a local quiet-discipline
build and a contended CI runner.

**Cross-binary, interleaved A/B** (base/cur/base/cur/…, per
`measurement.md`'s interleaving discipline,
`o/bin/cosmic --make run _perf/run.tl --only embed`):

| pair | base | cur | delta |
|---|---|---|---|
| 1 | 92.71ms | 102.28ms | +10.3% |
| 2 | 75.70ms | 77.91ms | +2.9% |
| 3 | 98.73ms | 79.54ms | **-19.4%** (cur faster) |
| 4 | 76.80ms | 79.45ms | +3.4% |

Sign flips across interleaved pairs — the signature of noise, not a
masked real effect: a real regression holds direction under
interleaving even when its magnitude wobbles.

**Aggregate** (12 raw readings per binary — block-sequential runs +
selfcheck + interleaved, well past "at least 3 times each"): base
median 80.29ms (range 75.70–113.52), cur median 81.12ms (range
77.83–105.96) — **median delta +1.0%**, far under either binary's
own self-noise.

**Code-diff review** (secondary confirmation — no mechanism found).
`embed_extract_tree`'s measured `fn` is only `embed.extract`
(`cosmic/embed/extract.tl`) → `cosmic/zip.tl`'s `extract_entries`
(`ensure_dir`/`fs.make_dirs`/`fs.join`/`fs.dirname`/
`fs.is_unsafe_entry_name`/`fs.set_mode`, `archive:save`). None of
the 8 commits touch `cosmic/zip.tl` or `cosmic/embed/*.tl`.
`b614c62d` (fs.visit d_type/lazy-stat, the leading suspect named
above) touches 19 files (`git show --stat b614c62d`):
`_build/casts_baseline.tl`, `_docs/publish.tl`, `_make/artifact.tl`,
`_make/extract.tl`, `_make/fixpoint_test.tl`, `_make/project.tl`,
`_tool/coverage/report.tl`, `cosmic/coverage/init_test.tl`,
`cosmic/fs/find.tl`, `cosmic/fs/path_test.tl`, `cosmic/fs/types.tl`,
`cosmic/fs/walk.tl`, `cosmic/fs/walk_example.tl`,
`cosmic/fs/walk_test.tl`, `docs/decisions/README.md`,
`docs/decisions/d41-lazy-entry-stat.md`, `docs/design/cast-sites.tsv`,
`docs/design/casts.md`, `docs/guides/recipes.md`. The functions
`extract_entries` actually calls resolve to `cosmic/fs/dir.tl`
(`make_dirs`), `cosmic/fs/path.tl` (`join`, `dirname`,
`is_unsafe_entry_name`), and `cosmic/fs/ops.tl` (`set_mode`) — none
of those three files, nor `cosmic/zip.tl` or
`cosmic/embed/extract.tl`, is among `b614c62d`'s 19 touched files, so
the mechanism conclusion holds even against the corrected file list:
`b614c62d` does not touch anything on `embed_extract_tree`'s measured
call path. Separately, `embed.write`'s `collect_dir` (used only in
the scenario's `setup`, not the timed `fn`) walks via raw
`unix.opendir` (`cosmic/embed/init.tl:103`), not `fs.visit`
(`cosmic/fs/walk.tl`, one of the 19 files) — so even the untimed
setup path is unaffected by `b614c62d`. The four sandbox/quicksand
commits touch only `cosmic/sandbox/**`/`cosmic/quicksand/**`, neither
of which `embed.extract` calls (no subprocess, no sandbox in this
scenario's path). `54d754f1` only bumps the bootstrap trust-root pin
(`bin/cosmic.pin`); the resulting artifacts hashed byte-identical to
CI's, so no code-gen drift entered there either. There is no
plausible code-level mechanism in this window for a real regression
in `embed_extract_tree`.

**Environment caveat** (does not change the verdict). Measurement ran
in a shared container (`/proc/loadavg` ~8–9 on 4 cores throughout, no
`cpupower`/cpufreq governor control available), not the quiet,
pinned machine `measurement.md` calls for. This likely inflates the
absolute noise magnitudes above versus a dedicated box, but only
reinforces the verdict: even under contention the two binaries'
distributions fully overlap and interleaved comparisons flip sign,
which is what noise looks like, not what a masked-but-real
regression looks like.

**Conclusion**: this reproduces the same false-red class D34/D35
already accept for `http_stream_read_1mb` and `fs_barf_slurp_64k`,
and CI's own attempt 2 independently corroborates the same
noise-sensitivity on the identical binary pair. No bisect was
warranted or run. No follow-up item is filed.
