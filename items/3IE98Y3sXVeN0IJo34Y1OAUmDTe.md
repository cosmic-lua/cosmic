## Evidence

`_perf/gate.tl compare BASE CUR SELFB` overwrites the files it is
handed. When a regression is flagged it re-measures ("regression
flagged; re-measuring once to filter noise") and then runs its own A/A
control ("running A/A self-check to separate real regressions from
machine noise") — and those fresh runs are written back into the
argument paths rather than to scratch files of its own.

Observed 2026-08-21 while measuring the cosmos pin bump (3I7LGcLa).
Each gate invocation left its inputs holding a fresh run of the CURRENT
binary. Reading the metadata back after a gate call:

```
before:  base  2026.08.15-e21155f87 cc626c6abbff
         selfb 2026.08.15-e21155f87 cc626c6abbff
         cur   2026.08.21-87869141c e3e2de5f57d2
after:   base  2026.08.21-87869141c e3e2de5f57d2
         selfb 2026.08.21-87869141c e3e2de5f57d2
         cur   2026.08.21-87869141c e3e2de5f57d2
```

The second invocation then compares the new binary against itself, and
the gate's own guard catches that with "measured the SAME binary
(e3e2de5f57d2) ... a clean result says nothing about your change" —
which reads as an operator mistake rather than as the gate having eaten
its inputs. Writing outside `o/` does not help; the paths are
overwritten wherever they point, and `chmod 444` does not stop it under
root.

The working discipline is to keep pristine masters and pass throwaway
copies to every gate call:

```
cp m_base.json t_a.json; cp m_cur.json t_c.json; cp m_selfb.json t_s.json
gate.tl compare t_a.json t_c.json t_s.json
```

## Why it might matter

The guard fires only when two arguments end up identical. A partial
clobber — the third argument replaced while the first two still differ —
silently changes the noise floor the verdict is computed against, and
nothing reports it. That is a wrong perf verdict with no symptom.

Two shapes of fix worth weighing: have the gate write its internal
re-measures to its own temp files and never touch its arguments; or, if
writing back is intended as a cache, say so in the usage line and in
`skills/optimize/measurement.md`, which currently tells the reader to
trust the gate's verdict without mentioning that it consumes its inputs.
