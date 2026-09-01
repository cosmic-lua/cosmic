## Goal

`release.yml`'s scheduled run on 2026-09-01 (run 33501918861,
https://github.com/cosmic-lua/cosmic/actions/runs/33501918861) went
red at the `perf-compare` step, blocking that day's publish. This
item exists because "lane repair: release.yml is red" (board item
`3Ij9W1WjKisRUAIHgLNP69OPzc2`) turned out to have no PR-shaped fix —
the gate, its retry, and its A/A self-check all behaved exactly as
D34/D35 specify, so the failure is either real perf noise the gate
correctly refused to publish past, or a real regression. Distinguish
the two and answer P69O_Pzc2's question: does this reproduce, and if
so, what commit caused it.

Evidence gathered from the failing job's log (`get_job_logs`,
run 33501918861, job `build`, `failed_only`):

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
workflow is wrong.
