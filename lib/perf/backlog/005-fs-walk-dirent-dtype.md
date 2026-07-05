# 5. fs.walk per-entry cost

- status: done (2026-07-04) — for `files()`/`collect_all()`;
  `walk()`/`collect()` unchanged (see below)
- layer: cosmic
- scenario: fs_files_tree

- binding check: `unix.Dir:read()` (`lib/types/cosmo/unix.d.tl:157`)
  already returns `string, number, number, number` — name, `kind`
  (d_type: `DT_DIR`/`DT_REG`/`DT_LNK`/.../`DT_UNKNOWN`), ino, off —
  but `fs_walk.tl`'s internal `WalkDirHandle` record only declared a
  single `string` return, discarding `kind`.
- key finding that narrowed the hypothesis: `walk()` (and `collect()`,
  which is implemented on top of `walk()`) hands every visitor a full
  `WalkStat`, per its documented contract — so those two can NOT skip
  the stat(2) call without changing observable behavior. Only
  `collect_all()` and `files()` have their own private traversal loops
  that never expose `st` to a caller, so only those two got the d_type
  fast path. `walk()`/`collect()` are unchanged; a future pass could
  revisit them with an explicitly lazy-stat visitor API, but that's a
  bigger, contract-changing effort out of scope here.
- fix: `WalkDirHandle.read` now returns the `kind` too. In
  `collect_all()`/`files()`, `kind == DT_DIR` recurses (or pushes)
  without stat (d_type never follows symlinks, so this still can't
  recurse into a symlinked dir — a symlink reports `DT_LNK`, the same
  cycle prevention `AT_SYMLINK_NOFOLLOW` stat gave before); any other
  definite (non-`DT_UNKNOWN`) kind skips stat too, since `files()`
  never needed stat data beyond "not a directory" and `collect_all()`
  only stores `DT_REG` entries (for which stat is still needed, for
  the mode bits); `DT_UNKNOWN` falls back to the original stat-based
  check unchanged, for filesystems that don't expose d_type.
- added a new scenario, `fs_files_tree` (iterates `fs.files()` over
  the existing seeded tree matching `*.txt`), since `files()` and
  `collect_all()` had no benchmark coverage before this — `files()`
  is the one where a file-heavy tree pays for zero stat(2) calls
  instead of one per entry, so it shows the win most clearly.
- result: `fs_files_tree` 415.81µs -> 187.31µs (-55.0%, confirmed
  -56.7% on re-measure). `bin/make perf-compare` both times: 21
  scenarios, 0 regression, 1 faster, 20 ok. `fs_walk_tree`/`fs_stat_tree`
  unaffected (within noise), as expected since `walk()` didn't change.
  verified against `lib/cosmic/fs_walk_test.tl`'s existing symlink-cycle
  tests for `collect_all()` and `files()`, which pass unchanged.
