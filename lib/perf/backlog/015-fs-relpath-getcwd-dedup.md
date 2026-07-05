# 15. fs_path.relpath calls getcwd(2) twice for the common case

- status: done (2026-07-04)
- layer: cosmic
- scenario: fs_relpath_relative

- result: `fs_relpath_relative` (new, in `lib/perf/bench/fs_bench.tl`):
  5.03µs baseline; three re-measures came back -8.3%, -10.4% (crossed
  the noise bar, flagged `faster`), -5.9% — consistently faster,
  never slower, across all three passes.
- evidence: `relpath(p, base)` with a relative `p` and no explicit
  `base` (the common call shape — "make this path relative to cwd")
  called `abspath(p)` first, which internally calls `unix.getcwd()`
  to resolve `p`, and then called `unix.getcwd()` a second time to
  resolve the implicit `base`. Two syscalls doing the same lookup.
- fix: in `lib/cosmic/fs_path.tl`, `relpath` now fetches `cwd` once
  when `base` is nil, reusing it both to resolve `p` (via
  `normalize(cwd .. "/" .. p)` when `p` isn't already absolute) and
  directly as `abs_base`, instead of the previous unconditional
  second `unix.getcwd()` call. The explicit-`base` path is
  unchanged.
- correctness: `fs_path_test.tl`'s six `relpath` cases all pass
  absolute paths for both `p` and `base`, so they pin the shared
  path-math (common prefix / `..` counting) the fix doesn't touch,
  without exercising the changed branch directly. Verified by hand
  that the new branch produces identical results to the old code
  for relative-`p`/no-`base` inputs — both reduce to
  `normalize(cwd .. "/" .. p)` vs. `cwd` itself.
- risk: low — pure refactor of which syscall runs when, no change to
  the string math or the public signature.
