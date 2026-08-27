## Evidence

The release compare step's baseline side runs `_perf/run.tl` bare under
the PREVIOUS release binary (`.github/workflows/release.yml:173`).
`run.tl` discovers bench modules by scanning the tree
(`fs.find(BENCH_DIR, {glob = "*_bench.tl"})`) and then loads each with
`require`, so the scenario NAMES come from the tree while the BYTES come
from whatever answers the require. The binary answers for every module
it carries: `unzip -l o/bootstrap/cosmic | awk '{print $4}' | grep -c
'^_perf/'` is 30 compiled modules at the zip root, ahead of the cwd
patterns in `package.path`.

Consequence, in three classes:

- an ADDED bench module runs the tree's copy, compiled by the old
  binary's checker — the skew class `_perf/skew_test.tl` guards.
- the path-given ENTRY (`_perf/run.tl`) runs the tree's copy — also
  guarded.
- a CHANGED bench module the release already carries runs the RELEASE's
  copy. The tree edit is invisible on the baseline side, nothing fails
  to type-check, and no gate can see it.

Measured 2026-08-27 in a scratch tree holding a deliberately broken
sibling, under the pinned bootstrap:

```
$ D=$(mktemp -d) && mkdir -p "$D/_perf/bench" \
  && echo 'this is not valid teal at all !!!' > "$D/_perf/bench/json_bench.tl" \
  && printf 'local ok, mod = pcall(require, "_perf.bench.json_bench")\nprint("ok=" .. tostring(ok))\n' > "$D/probe.tl" \
  && (cd "$D" && o/bootstrap/cosmic probe.tl)
ok=true
```

The tree file is never opened.

So editing an existing scenario's body changes the CURRENT side of a
compare and not the BASELINE side, and the two rows are then produced by
different code under one scenario name. Whether any real release run has
diverged this way is NOT established — the mechanism is proven, its
historical incidence needs release-run logs nobody has fetched.

Split out of 3IVF3HbV, whose Non-goals exclude it: that item narrows the
skew guard to the two classes a type check can see and names this one in
the guard's docstring. The two candidate directions here are to make the
baseline lane resolve `_perf` from the tree (which changes what the
baseline number means, and needs its own argument) or to make the
compare refuse a scenario whose two sides came from different bytes.
