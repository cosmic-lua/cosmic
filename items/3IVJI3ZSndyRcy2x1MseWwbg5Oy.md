## Evidence

`.github/workflows/release.yml`'s `peers` job runs the tree's peer
harness bare under a downloaded release binary:

```
./dl/cosmic-lua _perf/peers/run.tl --bin ./dl/cosmic-lua ...
```

A bare run resolves `_perf.*` from that binary's embedded
`/zip/_perf/*.lua`, not from the tree — established under 3IVF3HbV,
where the same shape at `release.yml`'s compare step was measured in
full. The binary carries 5 `_perf/peers/*` modules among its 30
embedded `_perf` files, so the peers lane has the same split as the
compare step had: the entry script comes from the tree because it is
passed by path, and everything it requires comes from the release.

Two consequences, both inherited:

- a peers module CHANGED in the tree is not what runs — the release's
  copy is, silently;
- a peers module ADDED in the tree does run from the tree, compiled by
  the old binary's Teal against the old embedded `cosmic.*`
  declarations, which is the skew class `_perf/skew_test.tl` exists
  for. That guard covers `_perf/**` including `_perf/peers/**`, so this
  lane is the reason the guard keeps its job after 3IVF3HbV converts
  the compare step.

3IVF3HbV deliberately leaves this lane alone: it is the same edit
against a different lane and a different artifact, and folding it in
would put a second workflow change into a two-file diff whose
acceptance is written around the compare step.

## What this item must settle

Whether the peers lane wants the same conversion — a `root` + `build`
manifest and the prebuilt `o/_perf/peers/run.lua` entry — or whether a
peers comparison deliberately wants each binary running its OWN peer
harness. That question is genuinely open here in a way it was not for
the compare step: the compare step measures two binaries against one
instrument, while a peers run may reasonably want each release measured
as it shipped.

Answer that first; the edit is small either way, and if the answer is
"convert it", the shape is already written and measured in 3IVF3HbV's
`## Change`. If the answer is "leave it", say so in the lane's own
comment so the next reader does not re-open it, and keep the guard.
