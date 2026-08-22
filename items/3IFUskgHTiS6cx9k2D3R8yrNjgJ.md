## Evidence

`gitboard move ID check` refuses without `--pr N`
(`_work/gitverbs.tl:336`), but `skills/work/review.md` says a research
slice's deliverable is "recorded findings, no PR" and that such a slice
"takes the same three verdicts" — which requires it to reach `check`,
since `check` is the only phase a verdict may end.

Hit on 2026-08-22 by session `sched-n4i2ns` finishing item `3I7OygFC`
(cast wave 6, a research slice whose whole deliverable is prose written
back into its own spec sidecar). The only way through was
`move 3I7OygFC check --force --why "…"`, i.e. spending the repair
escape on ordinary flow — which the work skill's hard rules say
`--force` is not for.

The same gap has a second half: `land` and the accept path assume a PR
to merge, while review.md says an accepted research slice goes straight
to `done ID` with no move into `land`. A reviewer accepting `3I7OygFC`
will meet that half next.

Two shapes worth weighing: a `--research` flag on `new`/`move` that the
gates read, or deriving it (an item whose spec declares no code change).
Either way the handover gate, the accept path and `next`'s ordering
should agree on what a PR-less item is.

**Attach under whatever container holds the board machinery's own
defects** — it is a sibling of `3ICDNqdv` (move into land is ungated)
and `3IEv60qj` (land has no lease), which name adjacent holes in the
same gate family.
