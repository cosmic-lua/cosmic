## Goal

G3 — the cast epic's wave 6c. Wave 6's re-measure (item `3I7OygFC`,
research) found 42 of the 82 `narrowing-gap` cast sites removable
against main `aaf4af95`. Ten of them are one reason string and are
wave 6b's; these are the other 32, spread over five sub-families. They
are filed as one wave because they were all verified together in one
worktree and every further split would fall below the epic's 8-site
cluster floor.

**Attach this item under `3HyRcW05` (the cast epic), sibling of
`3I7OygFC` and of wave 6b.** It is filed unparented only because
`plan` was over its WIP limit when the research landed.

## Change

Delete the cast and its `-- cast:` marker at each of the 27 plain
sites below; make the one companion deletion and the four `is`-guard
restructures noted after them. Nothing else moves.

All 42 removals (these 32 plus wave 6b's 10) were verified together in
one throwaway worktree at `aaf4af95`: `--make check: PASS (513 files)`,
`--make lint: PASS (605 files)`, `--make fmt: PASS (513 files)`. Each
was also verified alone with `--check types <file>`.

**Plain deletions (27).**

```
pcall returns (4)
  cosmic/searcher.tl:76          return mod as TealSearch
  cosmic/shm.tl:220              {swapped = success as boolean, value = actual as integer}
                                   — BOTH casts on this line go
  cosmic/sqlite/extras.tl:57     pcall(fn, self) as (boolean, any, any)
  cosmic/sqlite/extras.tl:99     pcall(fn, self) as (boolean, any, any)

or fallback (1)
  _cli/build/steps.tl:271        (fs.resolve(root_named) or root_named) as string

record fields (3)
  _make/stage.tl:193             (v.target as string) .. "-summary.txt")
  _make/stage.tl:196             graph.run(proj, v.target as string, …)
  cosmic/_script_cache.tl:217    result.code as string

setmetatable-built records (7)
  cosmic/fetch/body.tl:143       }) as Body
  cosmic/fs/find.tl:295          setmetatable({} as FileIter, {
  cosmic/ip.tl:87                } as Addr,
  cosmic/ip.tl:97                setmetatable({_n = n} as Addr, Addr_mt)
  cosmic/ip.tl:232               } as Cidr,
  cosmic/ip.tl:240               setmetatable({_n = n, _bits = bits} as Cidr, Cidr_mt)
  cosmic/zip.tl:189              }) as Archive

singletons (12)
  _fuzz/sse_fuzz_test.tl:118           return reader as stream.Reader
  _make/stage.tl:41                    out[#out + 1] = k as Kind
  cosmic/coverage/init.tl:40           package.preload as {string: any}
  cosmic/fetch/init.tl:216             error_mt as metatable < Error >
  cosmic/quicksand/box/init_test.tl:75  (err as string):find("Linux only", 1, true)
  cosmic/quicksand/box/init_test.tl:104 (err as string):find("closed", 1, true)
  cosmic/searcher_test.tl:84           #(package.searchers as {any})
  cosmic/searcher_test.tl:87           #(package.searchers as {any})
  cosmic/searcher_tree_test.tl:67      package.searchers[2] as function(string): (any, any)
  cosmic/stream.tl:180                 return reader as stream.Reader
  cosmic/stream.tl:199                 return buf as stream.Buffer
  cosmic/sys.tl:107                    unix.uname() as (Uname, any)
```

**One companion deletion (1).** `cosmic/fs/dir_test.tl:49`
(`mt.__close as function(fs_types.Dir)`) type-checks clean once the
cast goes, but the file's `local fs_types = require("cosmic.fs.types")`
then has no other use and `--check types` fails on the unused-type
warning. Delete the require in the same edit.

**`is`-guard restructures (4).** Four sites guard with
`type(x) == "function"`, which does not narrow, and then cast. Teal's
`is` DOES narrow to a function type through an early-exit guard — the
correction #1191 landed and `cosmic/teal_narrowing_test.tl` pins for
primitives, records and arrays. Replace the guard, then delete the
cast:

```
cosmic/_teal_ast.tl:54
  -  if not ok or type(thaw) ~= "function" then
  +  if not ok or not (thaw is function({string: any}): (any, any)) then
  -  local thaw_fn = thaw as function({string: any}): (any, any)
  +  local thaw_fn = thaw

cosmic/_teal_ast_test.tl:30      same shape, assert form:
  -  assert(type(thaw) == "function", "…")
  +  assert(thaw is function({string: any}): (any, any), "…")

_types/tlast_test.tl:53          same, with `function(any): (any, any)`

cosmic/searcher_tree_test.tl:40
  -  if type(got) ~= "function" then
  +  if not (got is Loader) then
  -  return got as Loader
  +  return got
```

**Pin the narrowing fact these four now rely on.** Add a case to
`cosmic/teal_narrowing_test.tl` alongside `test_early_exit_is_guard_narrows`:
an `is` guard on a FUNCTION type (both the anonymous
`function(A): (B, C)` spelling and a named function-type alias) narrows
`any` past a return-terminated early exit, and past an `assert(x is F)`.
Nothing pins that today, so a future tl bump could silently take these
four deletions back.

**Regenerate the cast floor** (`_build/casts_baseline.tl`) in the same
commit. Expected per-file delta:

```
_cli/build/steps.tl            -1    cosmic/fs/find.tl              -1
_fuzz/sse_fuzz_test.tl         -1    cosmic/ip.tl                   -4
_make/stage.tl                 -3    cosmic/quicksand/box/init_test.tl -2
_types/tlast_test.tl           -1    cosmic/searcher.tl             -1
cosmic/_script_cache.tl        -1    cosmic/searcher_test.tl        -2
cosmic/_teal_ast.tl            -1    cosmic/searcher_tree_test.tl   -2
cosmic/_teal_ast_test.tl       -1    cosmic/shm.tl                  -1
cosmic/coverage/init.tl        -1    cosmic/sqlite/extras.tl        -2
cosmic/fetch/body.tl           -1    cosmic/stream.tl               -2
cosmic/fetch/init.tl           -1    cosmic/sys.tl                  -1
cosmic/fs/dir_test.tl          -1    cosmic/zip.tl                  -1
```

Tree total: 444 markers → 412 on its own, or → 402 with wave 6b landed.

## Non-goals

- wave 6b's ten `function shape` sites are not touched here.
- the 40 still-blocked sites are not touched, and no code is reshaped
  to make one of them pass. `cosmic/fetch/init.tl:220` carries TWO
  casts on one line and exactly one of them can go — leave the line
  alone; it is a blocked site, recorded as such in `3I7OygFC`.
- no tl patch work (`3p/tl/tl_patch.tl`).
- `_perf/bench/micro_bench.tl:191` is blocked as measured; a
  `check.must` rewrite would remove it but that is a different change
  and not this wave's.

## Acceptance

```
bin/cosmic --make ci
git grep -h -o -E -- '-- cast: [^(]*' -- '*.tl' | wc -l   # 412 (or 402 after 6b)
bin/cosmic --make test cosmic/teal_narrowing_test.tl
```

- `ci: PASS`, quoted in the PR description.
- the new `is`-on-a-function-type case in
  `cosmic/teal_narrowing_test.tl` fails when its guard is reverted to
  `type(x) == "function"` — demonstrate that in the PR description, so
  the test is shown to pin something.
- the diff touches only the files listed above,
  `cosmic/teal_narrowing_test.tl`, and `_build/casts_baseline.tl`.

## Enablement

none needed — every site is enumerated by `file:line` with its current
text, every deletion is pre-verified alone and as a set, and the four
restructures are given as diffs.
