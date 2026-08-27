Two sessions refined `3IOCdZCA` within four minutes on 2026-08-27 and the
second silently replaced the first's spec. `gitboard spec` writes the whole
sidecar and publishes; nothing compares the base against what the caller read,
so a session that reads a sidecar, spends minutes refining it, and writes it
back overwrites whatever landed in between — no refusal, and no trace in the
item's own trail, because `show` renders the events recorded in the `.tl` file
and a `spec` commit touches only the `.md`. Neither version is visible without
`git log -- items/<id>.md`. Concretely: `848b1a68` (05:50:04) is the text the
`ready` move at `a1934e41` (05:50:23) was made against — it cut `--filter` to
item `3IUCW3Wj`, filed 34 seconds earlier for the measured reason that
`cmd/cosmic/main.tl` sits at 499 lines against the hard 500-line cap
(`_tool/lint.tl:31`). `5cef0e2e` (05:54:22) replaced it wholesale with a
version that re-adds `--filter` and points `--report`'s counts line at tests,
which would corrupt the fmt, lint, example and benchmark verdicts:
`_make/stage.tl:221` renders every stage verdict as
`stage_detail(summary, #files, "file")` and all six stages share one
`--report` (`embed/cosmic.mk:158,199,222,243,266,294`). The item stayed
`ready` across the swap, so the ready bar was never re-run against the text
that replaced the text it had passed, and the puller found it only by reading
`git log` on the sidecar out of suspicion. Two changes would close it: `spec`
refusing a write whose base differs from what the caller read — the same
compare-and-swap the push half already performs — and a `spec` mutation
recording an event in the item file, so `show`'s trail names every spec
change the way it names every move.
