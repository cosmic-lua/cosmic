## Problem

`fs.find` is built on `fs.visit`, which stats every entry, and the
only thing `find`'s visitor asks of that stat is `e.stat:is_dir()`
(`cosmic/fs/find.tl:103-120`, current body at 107-111 — verified
2026-08-30 at `ce897b1e` / identical at `origin/main` `eba1cb1a`, no
diff on this file between the two). Its sibling `fs.find_iter` answers
the same question from the dirent `d_type` and never stats a non-directory
at all — that engine is already in the tree at `cosmic/fs/find.tl:199-303`,
where the dispatch at 254-284 has `DT_DIR` descend statlessly, a known
non-dir match by name alone, and only `DT_UNKNOWN` fall back to
`unix.stat(AT_SYMLINK_NOFOLLOW)`.

The gap the harness shows, re-measured this refinement (`export
SSL_USE_SYSTEM_CERTS=1 && bin/cosmic --make run _perf/run.tl --out
/tmp/perf.json` on a fresh clone of this tree at `ce897b1e`): `fs_walk_tree`
(the `visit` path) 285.31µs/op, 73.14KB alloc against `fs_files_tree` (the
`find_iter` path) 151.83µs/op, 2.77KB alloc, same 210-entry tree — 1.9x
the wall time and 26x the allocation for the one bit `find`'s visitor
actually reads. (The allocation figures match the 2026-08-23 research
pass on this item's parent almost exactly — 73.14KB vs 73KB, 2.77KB
exact; the wall-clock deltas moved with the machine, as timing always
does — the ratio is the fact that matters and it held.)

This is the cheap half of the parent's hypothesis, and it needs no
contract change at all: `find`'s own contract (a `Found` list, `.errors`
on the result, slot 2 for a root failure, `sorted`, `include_dirs`,
`max_depth`/`recursive`) is already exactly what draining `find_iter`
produces. The expensive half — `fs.visit`'s own d_type descent and a
lazy `Entry.stat` — is the sibling item «x5gU_h61r»
(`3ILxnhaKL5YDmOKs5Tqx5gUh61r`), and touches different files.

## Direction

Reimplement `find` (`cosmic/fs/find.tl:103-120`) as a drain of
`find_iter` — same `FindOptions`, sort when `sorted`, `.errors` from
the iterator's terminal second return — deleting its `fs_walk.visit`
call. `find_info` (`find.tl:130`) genuinely needs stat data per entry
(`FileInfo.mode`) and stays on `visit` (see `Non-goals`).

No gated scenario measures `fs.find` today: `_perf/bench/fs_bench.tl`
(195 lines, verified 2026-08-30) has `fs_walk_tree` and `fs_files_tree`
and nothing between them. A `fs_find_tree` scenario with its own
functional check, added in the same slice, is what makes the compare
gate able to see this change at all.

## Change

**`cosmic/fs/find.tl`** — reimplement `find`, in place, as a drain of
`find_iter`:

- Move the `FileIter` record and the `find_iter` function (currently
  `find.tl:155-303`) to before `find` (currently `find.tl:103-120`) —
  `find`'s new body calls `find_iter`, and Teal locals must be declared
  before use, so the definition order in the file has to flip. Leave
  `find_info` and `glob` where they are, after `find_iter`, unchanged.
- Rewrite `find`'s body to:
  ```
  local function find(dir: string, opts?: FindOptions): Found | nil, string
    local iter, ierr = find_iter(dir, opts)
    if not iter then
      return nil, ierr
    end
    local results: Found = {}
    for p in iter do
      table.insert(results, p)
    end
    local _, errs = iter()
    if opts and opts.sorted then
      table.sort(results)
    end
    results.errors = errs
    return results
  end
  ```
  The `for` loop is a full, unbroken drain — the release path
  `find_iter`'s own doc comment (`find.tl:175-176`) already documents —
  so no `<close>` attribute or explicit `iter:close()` is needed. Calling
  `iter()` once more after the loop reads the terminal `nil, errs` pair
  exactly the way `find_iter`'s own doc example does.
- Update `find`'s doc comment to say it drains `find_iter` (not
  `fs_walk.visit`) and drop the now-inaccurate `@param`/`@return`
  wording only if it names `visit`; the existing wording ("Slot 2 means
  the root failed; subtree failures ride on the result as
  `found.errors`") is still accurate and can stay.
- No other function in the file changes body. `fs_walk` stays imported
  (line 13) — `find_info` still calls `fs_walk.visit` at its current
  line — so the import is not removed.
- The reordering nets to no line-count growth: moving a block plus
  shrinking `find`'s body from 18 lines to about 15 keeps the file at
  its current 400 lines, unchanged from today and well under the
  500-line cap `--make lint` enforces.

**`_perf/bench/fs_bench.tl`** — add one scenario, `fs_find_tree`, placed
directly after `fs_files_tree` (after line 106 in the current file) so
the three file-collection scenarios (`fs_walk_tree`, `fs_files_tree`,
`fs_find_tree`) sit together:

```lua
{
  -- Exercises fs.find() itself (not find_iter directly): the scenario
  -- the fs_walk_tree vs fs_files_tree gap was never gated on.
  name = "fs_find_tree",
  fn = function(_: any): any
    local found = check.must(fs.find(tmpdir, {glob = "*.txt"}))
    return #found
  end,
  check = function(_: any, res: any): boolean, string
    if not (res is integer) then
      return false, "fs_find_tree: result is not an integer"
    end
    local count = res
    if count ~= DIRS * FILES_PER_DIR then
      return false, string.format("found %s *.txt files, want %d",
        tostring(count), DIRS * FILES_PER_DIR)
    end
    return true
  end,
},
```
Same shape as its two neighbors: reuses `tmpdir`/`DIRS`/`FILES_PER_DIR`
from `init_tree`, same glob, same expected count (`DIRS * FILES_PER_DIR`
= 200), `check.must` already imported (used by `fs_files_tree`).

**No test file needs to change.** Verified this refinement, in a
throwaway clone of this tree (`git clone /home/user/cosmic
/tmp/fs-find-refine`, discarded after) with the `find.tl` reorg above
applied: `o/bin/cosmic --make test cosmic/fs/walk_test.tl
cosmic/fs/find_close_test.tl cosmic/fs/glob_test.tl` — output `3 checks:
3 passed / 35 tests: 35 passed / test: PASS (3 files)`, unmodified
against the reimplementation. `o/bin/cosmic --check fmt|types|lint
cosmic/fs/find.tl` all reported PASS on the reorganized file, no cast or
line-length fallout.

## Non-goals

- `find_info` stays on `fs_walk.visit`: it needs `FileInfo.mode` per
  entry, which requires the stat `find_iter` deliberately skips for
  non-directories. Not touched by this change.
- `fs.visit`'s own d_type descent and a lazy `Entry.stat` — the
  expensive half of the parent hypothesis — is the sibling item
  «x5gU_h61r» (`3ILxnhaKL5YDmOKs5Tqx5gUh61r`), a different file
  (`cosmic/fs/walk.tl`) and a different PR.
- `glob` is untouched — a different capability (component-path
  expansion, never recurses) with its own contract; not part of the
  `find`/`find_iter`/`find_info` engine swap.
- `find` does not gain a documented order guarantee. It never promised
  one before this change and does not promise one after — `sorted`
  remains the only way to get one. (See "Open at refinement" below for
  why the *unsorted* order happens not to move either, which is a fact
  about this change, not a new contract.)

## Open at refinement — resolved

**Handle-closing guarantee.** `cosmic/fs/find_close_test.tl` pins that
`find_iter`'s directory handles are released by three paths: draining,
`iter:close()`/`<close>`, and GC as backstop — it never calls `find()`
itself, so it was never at risk of pinning a stale expectation about
`find`. `find`'s reimplementation uses exactly the first of those three
paths (a plain `for p in iter do ... end` to exhaustion, no `break`), the
same shape `find_close_test.tl`'s own `count_open_fds` helper uses. Verified
two ways in the throwaway clone above:
- The existing suite (`find_close_test.tl` included) passes unmodified
  against the reimplementation: `o/bin/cosmic --make test
  cosmic/fs/find_close_test.tl` → `✓ cosmic/fs/find_close_test.tl (3 test
  functions)`, `test: PASS (3 files)`.
- A scratch test calling `find()` itself (not `find_iter`) and counting
  `/proc/self/fd` before and after, mirroring `count_open_fds`, passed:
  `after == before` for a 3-subdirectory tree. (This scratch test was
  discarded, not added to the tree — the shipped diff needs no new test
  for this, since `find_close_test.tl` already pins the release-path
  guarantee at the `find_iter` layer that `find` now sits directly on.)

**Discovery order.** No test in `cosmic/fs/` asserts an unsorted `find`'s
order — `cosmic/fs/walk_test.tl`'s `test_find_max_depth_and_recursive`
and the missing-root/success tests check counts and membership only;
every order assertion in the suite (`test_find_include_dirs_and_sorted`)
passes `sorted = true` first. Source-level: `fs_walk.visit`
(`cosmic/fs/walk.tl:65-103`, `walk_entries`) and `find_iter`'s `step`
function (`find.tl:241-291`) are both a synchronous, dive-immediately
depth-first walk — each visits/yields a directory entry, then (if it's
a directory) fully recurses into it before reading the next sibling
from the same `readdir` handle — so the two engines produce the *same*
entry order for the same tree. Confirmed empirically in the throwaway
clone: built the tree once with the original `find` (via `fs_walk.visit`)
and once with the reimplementation (via `find_iter`), ran an unsorted
`find(base, {include_dirs = true})` over an identical mixed tree (3 top-level
files, 2 subdirectories, one containing 2 files) against both, and got
byte-identical output both times: `zzz`, `zzz/q.txt`, `zzz/a.txt`,
`b.txt`, `m.txt`, `z.txt`, `aaa`. Unsorted `find` order is unaffected by
this change.
