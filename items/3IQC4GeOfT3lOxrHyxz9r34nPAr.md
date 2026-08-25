`docs/design/casts.md` is a dated snapshot ("Measured against `d3e59de7`
on 2026-08-25") and the tree has moved out from under every number in
it. Measured 2026-08-25 against `1f9279ab`:

```text
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l          # 314, doc says 402
git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"  # 111, doc says 192
git ls-files '*.tl' | xargs grep -lc -- "-- cast: .*from any" | wc -l    # 46, doc says 63
```

The per-class tables are stale row by row, not just in aggregate. In
the "Any-map field walk" table (13 rows, stated total 55), 5 rows name
files that are gone or now carry zero from-any sites
(`cosmic/deep_example.tl`, `cosmic/deep_test.tl`,
`cosmic/quicksand/box/init_test.tl`, `cosmic/quicksand/box/merge.tl`,
`cosmic/quicksand/box/merge_test.tl`), and the live rows sum to 22, not
55.

This matters because the document is what the G3 cast-closure items are
cut from: a session reading it to size the remaining work reads numbers
that overstate the job by roughly 2x, and a slice that dutifully edits
"its" row leaves the document neither current nor a coherent snapshot —
while colliding with every sibling slice editing the same table.

Two shapes worth weighing at refinement: re-measure and rewrite the
document as a fresh snapshot pinned to a new commit (and accept that it
goes stale again), or derive the per-class tables from the tree the way
`_build/casts_baseline.tl` is derived, leaving only the class prose
hand-written. The second is more work and is the only one that stops
the drift.
