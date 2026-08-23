## Goal

G3 — the cast epic's wave 6c. Wave 6's re-measure (item `3I7OygFC`,
research) found 42 of the 82 `narrowing-gap` cast sites removable
against main `aaf4af95`. Ten of them are one reason string and are
wave 6b's; these are the other 32, spread over five sub-families. They
are filed as one wave because they were all verified together in one
worktree and every further split would fall below the epic's 8-site
cluster floor.

## Change

Delete the cast and its `-- cast:` marker at each of the 27 plain
sites below; make the one companion deletion and the four `is`-guard
restructures noted after them, add the narrowing pin, and regenerate
the cast floor. Nothing else moves.

All 42 removals (these 32 plus wave 6b's 10) were verified together in
one throwaway worktree at `aaf4af95`: `--make check: PASS (513 files)`,
`--make lint: PASS (605 files)`, `--make fmt: PASS (513 files)`. Each
was also verified alone with `--check types <file>`.

**Re-measured 2026-08-23 at main `d71d7f15`.** All 32 sites are still
at the line numbers below — each was read with `git show
origin/main:<file> | sed -n '<line>p'` — and none of the surrounding
code has moved since `aaf4af95`. What DID move is the tree total, and
only because cast wave 4 landed as #1328: `git grep -h -o -E -- '--
cast: [^(]*' -- '*.tl' | wc -l` now prints **443**, not the 444 the
wave-6 research recorded. Every count below is stated against 443.

**Marker position: 24 of the 32 carry the marker as a trailing comment
on the cast's own line, and 8 carry it as a STANDALONE comment on the
line directly above** (both spellings are what `--make lint` accepts).
For the standalone eight the deletion collapses TWO lines into none or
one — do not leave an orphaned `-- cast:` line behind, and do not
delete a marker without its cast. The eight, verified by reading each
site's line and the one after it:

```
cosmic/shm.tl:220                      cosmic/ip.tl:240
cosmic/sqlite/extras.tl:57             cosmic/quicksand/box/init_test.tl:75
cosmic/sqlite/extras.tl:99             cosmic/quicksand/box/init_test.tl:104
_make/stage.tl:196                     cosmic/searcher_tree_test.tl:67
```

**Plain deletions (27).** Line numbers are the CAST's line; for the
eight above the marker sits one line higher.

```
pcall returns (4)
  cosmic/searcher.tl:76          return mod as TealSearch
  cosmic/shm.tl:220              {swapped = success as boolean, value = actual as integer}
                                   — BOTH casts on this line go; it is ONE marker line,
                                   which is why the floor row moves by 1 and not by 2
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
`is` DOES narrow to a function type through an early-exit guard.
Replace the guard, then delete the cast:

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

**The narrowing fact these four rely on, measured 2026-08-23** against
a binary built from `d71d7f15` (`o/bin/cosmic --check types F` on four
throwaway files, each ending `Type check passed` or the quoted error).
All three positive spellings narrow, and the guard being replaced does
not — so the restructures are sound AND the pin below has teeth:

| snippet | verdict |
|---------|---------|
| `if not (v is function({string: any}): (any, any)) then return end` then use as that type | passes |
| `local type Loader = function(string): (any, any)`; `if not (v is Loader) then return end`; `local g: Loader = v` | passes |
| `assert(v is Thaw)`; `local g: Thaw = v` | passes |
| `if type(v) ~= "function" then return end`; `local g: Loader = v` | **fails**: `error: in local declaration: g: got <any type>, expected Loader` |

**Pin it in `cosmic/teal_narrowing_test.tl`** (143 lines today — `wc -l
< cosmic/teal_narrowing_test.tl` — so 357 lines of headroom under the
500-line cap; this addition is ~45 lines). Follow the file's existing
shape exactly: each test writes a snippet to `fs.join(tmpdir, "<name>.tl")`,
runs `teal.check_file(path)`, and asserts on `result.ok`. Add TWO
functions after `test_early_exit_is_guard_narrows` (which ends at line
121, and is the positive-case template) — each called on the line after
its `end`, per AGENTS.md:

- `test_is_guard_narrows_a_function_type` — asserts `result.ok` for a
  snippet carrying all three positive rows of the table above (the
  anonymous `function(A): (B, C)` spelling, a named function-type
  alias, and the `assert(x is F)` form). Model the failure message on
  `test_early_exit_is_guard_narrows`'s, which concatenates
  `result.errors`' messages so a regression names the checker's own
  complaint.
- `test_type_eq_function_does_not_narrow` — the negative twin, modelled
  on `test_error_terminated_guard_does_not_narrow` (line 127): the same
  alias snippet guarded with `type(v) ~= "function"`, asserting `not
  result.ok`. This is what makes the positive test pin something rather
  than merely pass; without it a tl bump that made `type(x) ==
  "function"` narrow would leave the pin unable to fail.

Nothing pins this today, so a future tl bump could silently take the
four deletions back.

**Regenerate the cast floor** (`_build/casts_baseline.tl`) in the same
commit, with `bin/cosmic --make run _build/casts.tl --baseline` — the
command `_build/casts.tl`'s own header and the gate's failure message
both print. This is required, not cosmetic: `_build/casts_test.tl`
matches the counts EXACTLY, not as a ceiling.

The floor counts MARKER LINES, not `as` occurrences (`_build/casts.tl`'s
`in_text`: one line holds at most one justification, so the line count
is the cast-line count). That is why `cosmic/shm.tl`, whose one line
carries two casts under one marker, moves by 1. Rows read at
`d71d7f15`, with their expected values after this wave — note the SIX
row REMOVALS, because a file at zero is absent from the floor rather
than present with a 0:

```
_cli/build/steps.tl                2 → 1     cosmic/fs/find.tl                  4 → 3
_fuzz/sse_fuzz_test.tl             1 → row deleted
_make/stage.tl                     4 → 1     cosmic/ip.tl                       4 → row deleted
_types/tlast_test.tl               3 → 2     cosmic/quicksand/box/init_test.tl 15 → 13
cosmic/_script_cache.tl            2 → 1     cosmic/searcher.tl                 3 → 2
cosmic/_teal_ast.tl                1 → row deleted
cosmic/_teal_ast_test.tl           4 → 3     cosmic/searcher_test.tl            4 → 2
cosmic/coverage/init.tl           12 → 11    cosmic/searcher_tree_test.tl       2 → row deleted
cosmic/fetch/body.tl               1 → row deleted
cosmic/fetch/init.tl              15 → 14    cosmic/shm.tl                      3 → 2
cosmic/fs/dir_test.tl              1 → row deleted
                                             cosmic/sqlite/extras.tl            6 → 4
                                             cosmic/stream.tl                   3 → 1
                                             cosmic/sys.tl                      2 → 1
                                             cosmic/zip.tl                      2 → 1
```

Tree total: 443 markers → **411** on its own, or → **401** with wave
6b landed. The regen's own summary line names the same total it wrote.

**In-flight overlap to expect.** Wave 6b (item `3IFUa4AY`, PR #1331) is
in `check` as of 2026-08-23 and touches two files this wave also
touches:

- `_build/casts_baseline.tl`. Resolve any conflict by re-running the
  regen command on the merged tree, never by editing rows by hand.
- `cosmic/fetch/init.tl`, where 6b deletes seven marker lines at 381–427
  and this wave deletes one at 216. Line 216 is ABOVE 6b's edits, so its
  number does not shift either way; only the floor row does — 15 → 14 if
  this wave lands first, 8 → 7 if 6b does.

Wave 6b landing also moves the tree total from 443 to 433, which is
what makes this wave's Acceptance count 401 rather than 411. Refresh
those two numbers at pull per the slice loop; both are detail drift,
neither changes the shape.

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
- no change to what any of the 32 sites' surrounding code DOES: every
  one of the 27 plain deletions and the companion deletion is a pure
  removal, and the four restructures swap a guard spelling and nothing
  else. If a site does not check clean after its stated edit alone,
  main has moved — bounce the item rather than reshaping the code.
- the two new narrowing tests pin the checker's behaviour only; do not
  add cases for other types (primitives, records and arrays are already
  pinned by `test_early_exit_is_guard_narrows`).

## Acceptance

```
bin/cosmic --make ci
git grep -h -o -E -- '-- cast: [^(]*' -- '*.tl' | wc -l    # 411 (401 if 6b landed first; 443 today)
bin/cosmic --make test cosmic/teal_narrowing_test.tl
wc -l < cosmic/teal_narrowing_test.tl                      # ≤ 500 (143 today, ~188 expected)
git status --short
```

- `bin/cosmic --make ci` ends `ci: PASS (5 stages)`, quoted in the PR
  description.
- `bin/cosmic --make test cosmic/teal_narrowing_test.tl` ends
  `test: PASS (1 file)`, including both new functions.
- `wc -l < cosmic/teal_narrowing_test.tl` prints a number ≤ 500.
- the marker count falls from 443 to 411 (or from 433 to 401 if wave 6b
  landed first).
- `git status --short` lists exactly 24 modified files and no others:
  the 22 named in the floor table above, plus
  `cosmic/teal_narrowing_test.tl` and `_build/casts_baseline.tl`.

## Enablement

none needed — every site is enumerated by `file:line` with its current
text and its marker position, all 32 were re-read against main
`d71d7f15` during this refinement pass, every deletion is pre-verified
alone and as a set, the four restructures are given as diffs, and the
narrowing behaviour they depend on was measured in this pass with the
snippets and verdicts recorded above rather than inferred from the
earlier research.

The one wrong turn a literal session could take — deleting a standalone
`-- cast:` marker line without its cast, or the reverse — is walled by
naming the eight standalone sites explicitly, and caught by `--make
lint` (an unjustified cast) and `--make check` (an orphaned comment
leaves an unused local or an unreferenced type). The second — regenerating
the floor by hand and getting the shm.tl or the six deleted rows wrong —
is walled by stating the regen command and the exact expected rows.
