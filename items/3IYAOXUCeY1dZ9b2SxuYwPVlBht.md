## Evidence

Two `_perf` comments still describe the pre-3ff022d3 release compare
step, and both are load-bearing: each explains why its file reaches a
`cosmic.*` API through a tolerant map view instead of the typed call,
and each gives a reason that is no longer true.

- `_perf/run.tl:149-152` — "release.yml's compare step runs this
  script bare under the PREVIOUS release binary … and the typed access
  is a load-time type error there".
- `_perf/bench/literal_bench.tl:67-72` — "release.yml's compare step
  runs this module bare under the PREVIOUS release binary … and the
  typed call is a load-time type error there".

Measured against `origin/main` `40776231`. Since 3IVF3HbV (#1480,
`3ff022d3`), `release.yml:184` measures the baseline through
`o/bin/cosmic --make run _perf/baserun.tl --bin o/perf/prev/cosmic-lua`,
and `_perf/baserun.tl:126,40` spawns
`<prev binary> --modules <manifest> o/_perf/run.lua`. That is not a
bare run and its entry is not `.tl`: the scoped root serves
`<root>/<build>/<rel>.lua` first (`_perf/baserun.tl:15-20`) and every
`_perf` module the lane loads is prebuilt (`ls o/_perf/bench/*.lua`
→ 18, plus `o/_perf/run.lua`). Nothing on the baseline side is
type-checked any more, so neither "bare" nor "load-time type error"
holds.

The corrected reasons are different in kind, which is why the comments
mislead rather than merely age:

- what still forces the map view is `_perf/skew_test.tl`, which
  type-checks every non-test `_perf/**` source against the PINNED
  bootstrap at PR time — a compile-time gate in CI, not a load-time
  failure in the lane;
- what the lane itself would now do with a typed access is return nil
  and skip (run.tl's case, silent and harmless) or ignore the extra
  argument and measure the wrong layout under the right scenario name
  (literal_bench's case, silent and WRONG). literal_bench's own next
  sentences already describe that second reading correctly; its first
  sentence contradicts them.

Fix is a comment rewrite in two files, no behaviour change. Filed
while resolving 3IVKRdTZ, which asked whether any release lane can
still trip the skew guard; it can, and these two comments are the
tree's remaining description of the old shape of that lane.
