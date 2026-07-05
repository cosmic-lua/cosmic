# 16. embed.collect_dir stats every directory entry, even ones it skips

- status: done (2026-07-04)
- layer: cosmic
- scenario: embed_run_tree

- result: `embed_run_tree` (new, in `lib/perf/bench/embed_bench.tl`,
  600 directories/1 file each so the syscall savings are big enough
  to show over `embed.run()`'s dominant, roughly-fixed cost of
  copying the ~6MB source executable into the output file): 41.98ms
  baseline; four re-measures came back -8.6%, -10.6%, -10.1%, -6.5%
  — consistently faster, never a regression, though the swing never
  cleared the noise bar (±38.6%, driven by that fixed exe-copy floor
  dominating the timing and only 5 samples fitting in the budget at
  ~40ms/op). Also added `embed_extract_tree`, covering `extract()`
  for entry 17 — unaffected by this round's fix since it only times
  `extract()`, not `collect_dir`.
- evidence: `collect_dir`'s `do_walk` called `fs.stat(full_path,
  false)` (lstat) on literally every directory entry before deciding
  what to do with it — including entries that turn out to be
  directories (stat result only checked via `fs.is_dir`, no data
  needed to recurse) or symlinks (silently skipped either way). The
  exact same waste `fs_walk.tl`'s `collect_all`/`files` already fix
  via dirent d_type (entry 5).
- fix: switched `collect_dir` from `fs.opendir` (whose `Dir.read`
  only exposes the entry name) to `unix.opendir` directly, cast to a
  local `EmbedDirHandle` type declaring `read`'s second return (the
  d_type), mirroring `fs_walk.tl`'s `WalkDirHandle` pattern exactly.
  `do_walk` now recurses on `kind == unix.DT_DIR` without a stat
  call (d_type never follows symlinks, so this can't be a symlinked
  dir — same cycle-prevention property the old lstat-based check
  had), skips entries that are definitely neither a dir nor a
  regular file (symlink, fifo, socket, ...) without stating them
  either, and only falls back to `fs.stat` for `DT_REG` (needs mode
  bits) or `DT_UNKNOWN` (filesystem doesn't expose d_type). Sorting
  entries for deterministic embed order now sorts an array of
  `{name, kind}` records instead of a bare `{string}` array, since
  the kind has to travel with the name through the sort.
- correctness: ran the full `embed_test.tl`/`embed_advanced_test.tl`/
  `embed_env_test.tl` suite, including the two tests that exist
  specifically to pin this function's symlink handling —
  `test_embed_symlink_loop_terminates` (a self-referential symlink
  inside the embed dir must not cause infinite recursion) and
  `test_embed_symlink_to_outside_file_skipped` (a symlink pointing
  outside the embed dir must not be embedded) — both pass unchanged,
  since DT_LNK falls into the "skip without stat" branch exactly
  like the old code's S_ISLNK check did.
- risk: low-medium — changes which C binding opens the directory
  (`unix.opendir` instead of `fs.opendir`) and adds a new local
  record type, but preserves every branch's existing behavior; the
  existing symlink-cycle and outside-symlink tests are the ones most
  likely to catch a regression here, and both still pass.
