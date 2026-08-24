## Problem

`cosmic/fs/walk.tl:75` stats every entry with
`unix.stat(AT_SYMLINK_NOFOLLOW)`, wraps it (`types.wrap`) and builds a
fresh `Entry` table, before the visitor has said whether it wants any
of that. The dirent `d_type` — already the second return of
`DirHandle:read()` (`cosmic/fs/types.tl:111-118`) — answers the walk's
own only question, "is this a real directory". Probe numbers from the
2026-08-23 research pass recorded on this item's parent (200 iters,
scouting numbers, not the gate): raw d_type walk 81µs; walk +
stat-per-entry 276µs; today's `fs.visit` 429-447µs; a lazy prototype
171µs when the visitor never touches `e.stat` (−62%) and 354µs when it
does (−21%).

This is the contract-adjacent half of the parent hypothesis, and the
exact wall whilp/cosmic#469 stopped at: "walk() hands every visitor a
full WalkStat, per its documented contract … a future pass could
revisit them with an explicitly lazy-stat visitor API, but that's a
bigger, contract-changing effort out of scope here." Its sibling item
(routing `fs.find` through the existing d_type engine) takes the half
that needs no contract change, and touches `cosmic/fs/find.tl` rather
than these files.

## The two decisions this item exists to settle

1. **How `Entry.stat` becomes lazy, honestly.** `Entry` is a plain
   public record whose `stat: Stat` is declared non-nil
   (`cosmic/fs/types.tl:151-156`). A metatable `__index` is invisible
   to field access but visible to `pairs()` and deep-copy, and has
   nothing honest to return when the stat FAILS — which is the shape
   D20/D24 forbid. Retyping the field `Stat | nil` is a compile break
   for every visitor that writes `e.stat:is_file()`; measured
   2026-08-24 at main `9bcb0f7d`, `fs.visit` has 6 non-test callers
   outside `cosmic/fs` (`_docs/publish.tl:92`,
   `_tool/coverage/report.tl:176`, `_make/project.tl:370`,
   `_make/extract.tl:36`, `_make/artifact.tl:214`, plus
   `cosmic/fs/find.tl:132`'s `find_info`), and unknown callers outside
   the repo. A third shape — a `type`/`kind` field carrying the d_type
   answer for free, with `stat` unchanged — buys the descent saving
   without the lazy field, and should be priced against the other two
   before either is picked. Whichever is chosen, the reasoning is a
   candidate for a decision record (the `decide` skill), because it is
   a public-API tradeoff a later session will otherwise relitigate.
2. **The `walked.errors` delta.** `walk.tl:97` records a stat failure
   for entries the visitor never sees. With a lazy stat those failures
   surface only on access, or through the `DT_UNKNOWN` fallback, so
   the error list a caller gets back changes meaning. Decide whether
   that is a documented change, or whether the failures are collected
   some other way.

## Direction

Descend from `d_type` in `walk_entries` (`walk.tl:65-103`), falling
back to `unix.stat(AT_SYMLINK_NOFOLLOW)` only on `DT_UNKNOWN` — the
symlink-cycle guarantee is preserved by construction, since d_type
never follows symlinks and a symlinked directory reports `DT_LNK`.
Then apply decision 1 to `Entry`. `fs.remove_all` and `--make`'s tree
scans ride on this walker, so the win is broad.

Measured 2026-08-24 at main `9bcb0f7d`: `wc -l` — `cosmic/fs/walk.tl`
168, `cosmic/fs/types.tl` 300, `cosmic/fs/walk_test.tl` 440 (60 lines
of headroom under the 500-line cap, which is the tightest constraint
here and may force the new lazy-stat tests into their own file).

`_perf/bench/fs_bench.tl`'s `fs_walk_tree` scenario is the gate for
this one; its visitor never touches `e.stat` today (it reads
`e.path`), so it measures the stat-free case. A stat-touching
companion scenario would price the −21% side and should be considered
at refinement.
