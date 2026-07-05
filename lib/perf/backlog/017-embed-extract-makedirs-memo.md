# 17. embed.extract calls makedirs once per file, even when files share a dir

- status: done (2026-07-04) — modest win
- layer: cosmic
- scenario: embed_extract_tree

- result: `embed_extract_tree` (reused from entry 16; bumped the
  shared source tree from 600 dirs/1 file each to 120 dirs/5 files
  each so extract() actually has repeated files per directory to
  dedupe — the original 1-file-per-dir shape gave this round nothing
  to optimize): baseline 59.73ms; five re-measures (after the
  harness's own noise-filter retry) settled at +2.7%, -1.1%, -0.8%,
  -2.7% — leaning improved (3 of 4 better) but never a confirmed
  regression, never conclusively crossing the ±10% noise bar either
  way. `embed_run_tree`'s numbers (-18.3%/-14.8%, consistent with
  entry 16) are unaffected by this round's change, as expected —
  that scenario doesn't call `extract()`.
- evidence: `extract()`'s loop called `fs.makedirs(dir)` for every
  file entry and every explicit directory entry, unconditionally.
  Archive contents are commonly many files under a handful of
  directories (e.g. extracting a whole embedded tree), so most of
  those calls re-walk a directory path that was already created by
  an earlier entry in the same `extract()` call.
- fix: added a `made_dirs: {string: boolean}` memo table, keyed by
  the joined output path, checked before each `fs.makedirs` call
  (both the explicit-directory-entry branch and the per-file
  branch) and set after. Directory entries and file dirnames share
  the same cache since `fs.join`/`fs.dirname` normalize to the same
  string for the same directory either way.
- correctness: full `embed_test.tl`/`embed_advanced_test.tl`/
  `embed_env_test.tl` suite passes. The memoization only skips a
  call that would otherwise redundantly recreate a directory that's
  already been created earlier in the same `extract()` call — it
  doesn't change what gets created, in what mode, or the error
  contract (a failed `makedirs` is still surfaced the same way,
  via the subsequent `cio.barf` failing).
- risk: low — the fix can only reduce the number of `makedirs` calls
  for paths already proven created within the same run; it never
  skips the first call for a given directory.
