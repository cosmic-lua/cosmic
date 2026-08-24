## Problem

`fs.find` is built on `fs.visit`, which stats every entry, and the
only thing `find`'s visitor asks of that stat is `e.stat:is_dir()`
(`cosmic/fs/find.tl:106-110`, measured 2026-08-24 at main `9bcb0f7d`).
Its sibling `fs.find_iter` answers the same question from the dirent
`d_type` and never stats a non-directory at all — that engine is
already in the tree at `cosmic/fs/find.tl:238-290`, where `DT_DIR`
descends statlessly, a known non-dir is matched by name alone, and
only `DT_UNKNOWN` falls back to `unix.stat(AT_SYMLINK_NOFOLLOW)`.

The gap the harness already shows: `fs_walk_tree` (the `visit` path)
354.74µs / 73KB per op against `fs_files_tree` (the `find_iter` path)
170.06µs / 2.77KB on the same 210-entry tree — from the 2026-08-23
research pass recorded on this item's parent.

This is the cheap half of the parent's hypothesis, and it needs no
contract change at all: `find`'s own contract (a `Found` list, `.errors`
on the result, slot 2 for a root failure, `sorted`, `include_dirs`,
`max_depth`/`recursive`) is already exactly what draining `find_iter`
produces. The expensive half — `fs.visit`'s own d_type descent and a
lazy `Entry.stat` — is the sibling item, and touches different files.

## Direction

Reimplement `find` (`cosmic/fs/find.tl:102-119`) as a drain of
`find_iter` — same `FindOptions`, sort when `sorted`, `.errors` from
the iterator's terminal second return — deleting its `fs_walk.visit`
call. `find_info` (`find.tl:132`) genuinely needs stat data per entry
and stays on `visit`; say so in `Non-goals` when this reaches the bar.

No gated scenario measures `fs.find` today: `_perf/bench/fs_bench.tl`
(195 lines, measured 2026-08-24) has `fs_walk_tree` and
`fs_files_tree` and nothing between them. A `fs_find_tree` scenario
with its own functional check, added in the same slice, is what makes
the compare gate able to see this change at all.

## Open at refinement

- Whether the handle-closing guarantees `cosmic/fs/find_close_test.tl`
  pins still hold when `find` drains the iterator to exhaustion (it
  should: draining is one of the three documented release paths).
- Whether discovery order changes anything for an unsorted `find`.
  Both engines walk depth-first, but the ORDER within a directory is
  the same readdir order, and `find` never promised one — confirm
  against `cosmic/fs` tests rather than assuming.
