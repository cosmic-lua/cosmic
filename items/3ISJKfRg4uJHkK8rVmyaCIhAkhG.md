## Goal

G3 — an honest type layer, no escape hatches. Two `-- cast: from any`
sites where the `any` is not a fact about the value but an artifact of a
declaration we own: one in our own `tl.d.tl` curation, one in a dynamic
`require` that a type test closes better than a cast does.

## Evidence

Measured 2026-08-26 at main `b4ad036b`, from the repo root. Both fixes
below were **applied and reverted** during this refinement, so the
commands and their outcomes are observed, not predicted.

- **The from-any census.**
  `git ls-files '*.tl' | xargs grep -c -- "-- cast: from any" | grep -v ':0$' | sort`
  →

  ```text
  _build/casts_test.tl:2
  _cli/assert_lint_test.tl:1
  _tool/lint_test.tl:1
  cosmic/fd.tl:1
  cosmic/fetch/init.tl:3
  cosmic/quicksand/proc.tl:1
  cosmic/surface_test.tl:1
  cosmic/teal.tl:1
  cosmic/zip.tl:1
  ```

  This slice closes the two named in its title. `cosmic/fetch/init.tl`'s
  three are `3IQCrJpB`'s. The three in `_build/casts_test.tl`,
  `_cli/assert_lint_test.tl` and `_tool/lint_test.tl` are fixture TEXT
  for the lints that count casts, not casts in working code. The rest
  are out of scope here.

- **Site 1 is an under-typing in our own generator.**
  `cosmic/teal.tl:164-169`:

  ```teal
  local found, fd = tl.search_module(module_name, false)
  tl.path = saved_tl_path
  if fd ~= nil then
    local f = fd as FILE -- cast: from any
    f:close()
  end
  ```

  Upstream declares the real type — `o/3p/tl/tl.tl:724` and `:7434` both
  read
  `search_module: function(module_name: string, search_all: boolean): string, FILE, {string}`
  — but `_types/gentl.tl`'s erasure turns `FILE` into `any`, because
  `FILE` is in none of its three tables (`KEEP` at `:17-20`, `TO_STRING`
  at `:21-25`, `NAMED` at `:26-29`) and `erase` (`:31-54`) falls through
  to `any`. So `grep -n search_module o/_types/types_gen/tl.d.tl` reads
  `search_module: function(string, boolean): string, any, {string}` (line
  65). `FILE` is a Lua stdlib type, not an internal tl record, so the
  erasure rule's own stated intent ("internal records, interfaces become
  any", `:14-16`) already says it should be kept.

  **Applied and measured:** adding `FILE = true` to `KEEP`, rebuilding,
  and deleting the cast — `grep -n FILE o/_types/types_gen/tl.d.tl` then
  names exactly two lines, the doc comment at `:63` and `search_module`
  at `:65`, so nothing else in the generated surface moves;
  `o/bin/cosmic --check types cosmic/teal.tl` → `Type check passed`; and
  `o/bin/cosmic --make check` → `check: PASS (534 files)`. In particular
  the existing `if fd ~= nil` guard over a now-non-nil `FILE` raises no
  unreachable-branch warning, which is what would have made
  warnings-are-errors reject the change.

- **Site 2 is a dynamic require with an established alternative.**
  `cosmic/surface_test.tl:92`:

  ```teal
  local mod = require("cosmic." .. name) as {string: any} -- cast: from any
  ```

  `is {string: any}` is the shape the tree already uses to narrow an
  `any` to a table — `cosmic/json.tl:140`,
  `cosmic/quicksand/proxy/rules.tl:91`,
  `cosmic/quicksand/box/merge.tl:98`, and as an assertion in
  `cosmic/literal_test.tl:144-148`. **Applied and measured:** replacing
  the cast with `local mod = require("cosmic." .. name)` followed by
  `assert(mod is {string: any}, "cosmic." .. name .. ": not a module table")`
  → `o/bin/cosmic --check types cosmic/surface_test.tl` →
  `Type check passed`.

- **The cast floor is exact in BOTH directions.**
  `_build/casts_test.tl:34-56` collects `over` and `under` and asserts
  both are empty — a file with fewer casts than its committed row fails
  just as a file with more does, and a baseline row whose file has none
  left fails as `no casts left`. So the regen is mandatory, not
  optional. `grep -n 'cosmic/teal.tl\|cosmic/surface_test.tl' _build/casts_baseline.tl`
  → `["cosmic/surface_test.tl"] = 1` (`:83`) and `["cosmic/teal.tl"] = 1`
  (`:86`); `grep -c '\] = ' _build/casts_baseline.tl` → **88**. A file
  with no casts is absent from the render, so both rows leave and the
  count becomes 86. `_build/casts.tl:17` prints the regen command.

- **`tl.d.tl` is generated, never committed.** `_types/types_gen.tl`
  writes `o/_types/types_gen/`, which every graph-touching verb runs
  first, so the generator edit is the whole of the type change and there
  is no checked-in artifact to update.

## Change

Four files.

### `_types/gentl.tl` — keep `FILE`

In `KEEP` (`:17-20`), add `FILE = true`, with a comment saying why it
belongs there and the others do not: `FILE` is a Lua stdlib type that the
Teal standard library already declares, so keeping it names a real type,
while every name that falls through to `any` is an internal tl record or
interface this curation deliberately does not re-declare. Change nothing
else: not `TO_STRING`, not `NAMED`, not `erase`, and no new `Entry`
field. The `search_module` entry's comment (`:158-161`) already says the
second return is an open FILE handle the caller must close; leave it as
it is.

### `cosmic/teal.tl` — drop the cast

In `search_module` (`:158-170`), the guarded block becomes:

```teal
  if fd ~= nil then
    fd:close()
  end
```

The guard stays. Upstream declares the second return non-nil but returns
nil when the module is not found, and that guard is what makes the
declaration safe to consume; removing it would be the actual bug this
site has been papering over with a cast. `search_module`'s own cosmic-side
signature (`string | nil`) does not move.

### `cosmic/surface_test.tl` — narrow instead of cast

In `test_directory_module_entry_points` (`:91-95`):

```teal
  for name, fn in pairs(surface) do
    local mod = require("cosmic." .. name)
    assert(mod is {string: any}, "cosmic." .. name .. ": not a module table")
    assert(type(mod[fn]) == "function",
      "cosmic." .. name .. " must expose " .. fn .. "()")
  end
```

The `is` test is a real check with a real message, where the cast was an
assertion nobody could fail.

### `_build/casts_baseline.tl` — regenerate

`bin/cosmic --make run _build/casts.tl --baseline`, then commit the
result: both rows leave the file. Never hand-edit it.

**If a ratchet complains, run the command its failure message prints and
commit the result** — that is in scope and is the only sanctioned way to
move a floor. `cosmic/teal.tl` loses two lines, so
`bin/cosmic --make coverage --baseline` may be needed for
`.cosmic-coverage` as well; if the coverage ratchet passes untouched,
leave that file alone rather than regenerating it for tidiness.

## Non-goals

- **No upstream change and no pin bump.** `3p/tl/tl_pin.tl`,
  `3p/tl/tl_patch.tl` and anything under `o/3p/` stay as they are: the
  under-typing is in OUR curation, not in tl.
- **Do not widen `KEEP` beyond `FILE`.** Every other name `erase` sends
  to `any` is an internal tl record or interface that this curation
  deliberately does not re-declare, and adding one silently freezes an
  upstream internal into our surface. One name, for the one reason
  stated.
- **Do not touch the other from-any sites.** `cosmic/fetch/init.tl`'s
  three belong to `3IQCrJpB`; `cosmic/fd.tl`, `cosmic/quicksand/proc.tl`
  and `cosmic/zip.tl` are not this slice's; and the occurrences in
  `_build/casts_test.tl`, `_cli/assert_lint_test.tl` and
  `_tool/lint_test.tl` are fixture text whose whole purpose is to be
  counted — editing them breaks the lints' own tests.
- **Do not remove or weaken the `fd ~= nil` guard**, and do not change
  `cosmic.teal.search_module`'s `string | nil` return.
- **No decision record and no doc prose.** The erasure rule's intent is
  already written at `_types/gentl.tl:14-16`; this makes the code match
  it.
- **Frozen:** `tl.d.tl` stays generated and uncommitted; the cast lint,
  its `-- cast:` grammar, and the baseline format are untouched.

## Acceptance

Run from the repo root.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `grep -c -- "-- cast: from any" cosmic/teal.tl cosmic/surface_test.tl`
   prints `0` for each (both print `1` today).
3. `grep -n search_module o/_types/types_gen/tl.d.tl` shows
   `search_module: function(string, boolean): string, FILE, {string}`
   (today it reads `string, any, {string}`).
4. `grep -n FILE o/_types/types_gen/tl.d.tl` names exactly two lines —
   the doc comment and `search_module` — so no other generated signature
   moved.
5. `grep -c '\] = ' _build/casts_baseline.tl` prints `86` (it is `88`
   today), and
   `grep -c 'cosmic/teal.tl\|cosmic/surface_test.tl' _build/casts_baseline.tl`
   prints `0`.
6. `o/bin/cosmic --make test cosmic/surface_test.tl _build/casts_test.tl`
   passes.
7. `git diff --name-only origin/main` prints exactly, in any order:

   ```text
   _build/casts_baseline.tl
   _types/gentl.tl
   cosmic/surface_test.tl
   cosmic/teal.tl
   ```

   plus `.cosmic-coverage` if and only if the coverage ratchet asked for
   it.

## Enablement

none needed. Both edits were applied and reverted during this
refinement, so the two things a spec normally has to guess — whether
keeping `FILE` disturbs any other generated signature, and whether the
`fd ~= nil` guard over a non-nil type trips warnings-are-errors — are
answered above by commands with their output. The regen commands come
from the gates' own failure messages (`_build/casts.tl:17`), and the
`is`-guard shape has four in-tree precedents cited at real line numbers.
