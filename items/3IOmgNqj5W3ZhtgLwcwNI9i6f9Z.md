## Goal

G3 — an honest type layer. The parent (`3IOK2cxG`) is "close the 55
any-map field walk `from any` sites"; this is its `cosmic.deep` slice,
13 of the 55. `cosmic.deep` returns `any` from `copy` and `{any: any}`
from `merge`, so its own test and example cast at every read. Both
signatures can say what the module has always done — hand back the type
it was given.

## Evidence

Measured 2026-08-25 against `9c1ff401` (`main`) with
`grep -c -- "-- cast: " <file>` and `wc -l`. The three files are
byte-identical on `main` and on the `3IOmgCA2` branch
(`git diff --stat 9c1ff401 origin/claude/3IOmgCA2-box-merge -- cosmic/deep*.tl`
is empty), so every probe below was run on the latter and holds for
either base.

| file | `from any` sites | lines |
| --- | --- | --- |
| `cosmic/deep_test.tl` | 8 | 140 |
| `cosmic/deep_example.tl` | 5 | 49 |
| `cosmic/deep.tl` | 0 | 132 |

The whole `from any` bucket is 144 on `main`
(`git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l`).

**Callers are only these two files.** `grep -rn "deep\.\(copy\|merge\|equal\)("
--include=*.tl . | grep -v '^./o/' | grep -v 'cosmic/deep'` finds five
hits, all `deep.equal` in `_fuzz/{literal,json,url}_fuzz_test.tl`, whose
signature this slice does not touch. `copy` and `merge` have no caller
outside `cosmic/deep_test.tl` and `cosmic/deep_example.tl`.

**The item's own headline was wrong, and this replaces it.** Not all 13
sites are the return value. Only 5 are — `deep_test.tl:8`, `:28`, `:38`,
`:47` and `deep_example.tl:29`. The other 8 index a `{string: any}`
FIXTURE the test itself declared (`copy.nested`, `orig.nested`,
`merged.limits`, `base.limits`, `config.limits`, `copy.settings`,
`original.settings`). Typing the signatures alone closes 5 of 13; the
remaining 8 close only when the fixtures become records, which the
generics then carry through. Both halves are in `## Change` for that
reason — they are one change, not two: a record fixture cannot reach a
`{any: any}` parameter at all (a record is not a valid map), so the
fixtures cannot be typed without the generic `merge`, and the generic
`merge` buys nothing at the reads without the fixtures.

**Probe-verified 2026-08-25.** The whole change below was applied to a
scratch tree and gated. Facts it established, each with the command:

1. `bin/cosmic --make ci` on the finished change ends **`ci: PASS
   (5 stages)`**, with `coverage ratchet ok`.
2. `copy<T>(value: T): T` and `merge<T>(base: T, override: T): T`
   type-check, including through the `DeepModule` record field
   (`copy: function<T>(value: T): T`), for every call the two files
   make — scalars (`deep.copy(42)`, `deep.copy(nil)`) included.
3. **A bare `o/bin/cosmic --check types` on these files is misleading**:
   a bare script resolves `require("cosmic.deep")` to the binary's
   EMBEDDED copy, so it type-checks the call sites against the OLD
   signature and reports `<any type>` errors that do not exist. Probe
   with `bin/cosmic --make check cosmic/deep.tl cosmic/deep_test.tl
   cosmic/deep_example.tl`, which resolves against the tree and ends
   `check: PASS (3 files)`.
4. **The example runner does not see file-scope declarations.** Records
   declared at the top of `cosmic/deep_example.tl` fail at run time with
   `error: syntax error: unknown type Config`, because each `Example_*`
   body is extracted and run on its own. The records must be declared
   INSIDE the example functions, next to the existing
   `local deep = require("cosmic.deep")` line; with that, `bin/cosmic
   --make example cosmic/deep_example.tl` ends `example: PASS (1 file)`.
5. `deep.merge`'s two type-conflict tests (`deep_test.tl:115` and
   `:117`) pass differently-shaped table LITERALS, which a generic
   cannot unify: `argument 2: record (a: string "flat") is not a record
   (a: record (nested: boolean))`. Binding each side to a
   `local x: {string: any}` first fixes it with no cast and no changed
   assertion.
6. **Exactly one gate moves**: the casts ratchet, on the two casts
   `cosmic/deep.tl` gains. `_build/public_surface_test.tl` PASSES
   unchanged — the generics do not move the public-surface baseline —
   and so do `_build/ratchet_test.tl` and `cosmic/surface_test.tl`.

**Headroom after the change** (`wc -l`, 500-line cap): `deep.tl` 133,
`deep_test.tl` 168, `deep_example.tl` 66. All far under.

## Change

1. **`cosmic/deep.tl`** — two signatures, in the function and in the
   `DeepModule` record (`:120-124`), with the `@param`/`@return`
   comments updated to match:

   - `local function copy<T>(value: T): T`, returning
     `copy_impl(value, {}) as T` with the trailing reason
     `-- cast: copy_impl is the dynamic walk under the generic`.
   - `local function merge<T>(base: T, override: T): T`, returning
     `merge_impl(base as {any: any}, override as {any: any}) as T` with
     `-- cast: records are inspected as maps by the dynamic walk` on the
     line above (the line will not fit the reason at 90 columns).

   That is two cast-carrying lines in the file and no other change:
   `copy_impl`, `eq_impl` and `merge_impl` keep their `any`/`{any: any}`
   parameters, and `equal` is untouched (it returns `boolean` and costs
   its callers no cast).

2. **`cosmic/deep_test.tl`** — declare the fixture records at file
   scope, after the `require`, and give every fixture local its record
   type instead of `{string: any}`/`{any: any}`. The shapes the existing
   tests need: `Nested` (`b: any` — `test_copy_is_independent` overwrites
   `b` with a string on purpose, so the field is honestly `any`);
   `CopyFixture` (`a: integer`, `nested: Nested`, `self: CopyFixture`,
   `x: {integer}`, `y: {integer}`, `name: string` — the union of what
   the four copy tests build); `Limits` (`mem: integer`, `cpu: integer`)
   and `Conf` (`limits: Limits`) for the merge tests. Then delete all 8
   casts: `deep.copy(orig)` is the fixture's own type, so
   `copy.nested`, `orig.nested.b`, `merged.limits` and `base.limits`
   all read directly. In `test_copy_preserves_shared_references`,
   `shared` becomes `{integer}` to match the record field. In
   `test_merge_override_wins_on_type_conflict`, bind the two literals to
   `local nested: {string: any}` and `local flat: {string: any}` and
   pass those, per probe fact 5.

3. **`cosmic/deep_example.tl`** — the same move, with the records
   declared INSIDE `Example_merge` and `Example_copy` per probe fact 4:
   `Limits`/`Config` for the merge example, `Settings`/`Prefs` for the
   copy example. Delete all 5 casts; `config.limits.mem`,
   `config.limits.cpu`, `copy.settings` and `original.settings.theme`
   read directly. The `-- Output:` blocks do not change.

Then rewrite the ratchet floor with exactly the command the gate prints —
`bin/cosmic --make run _build/casts.tl --baseline` — and commit the
result. Never hand-edit `_build/casts_baseline.tl`.

## Non-goals

- **Do not change what any of the three functions DOES.** The semantics
  frozen in the module header (`cosmic/deep.tl:15-23`) all stay exactly
  as they are: copy copies table keys as well as values, shared
  references stay shared within one copy, cycles terminate, metatables
  are not copied, `equal` matches table-valued keys by identity rather
  than structure, and `merge` recurses only where both sides hold tables
  so lists merge by index. This slice moves types, not behaviour.
- **Do not touch `equal`.** Its `(a: any, b: any): boolean` signature
  costs no caller a cast, and its five out-of-file callers are the
  `_fuzz` tests, which this slice must leave untouched.
- **Do not change `copy_impl`, `eq_impl` or `merge_impl`.** The dynamic
  walk is the implementation and stays `any`-typed; the generics are a
  boundary over it, which is what the two casts are.
- **Do not weaken or delete a test assertion, or an example's
  `-- Output:` block.** Casts and fixture annotations change; asserts and
  printed output do not.
- **Do not edit `docs/design/casts.md`.** It is a dated snapshot
  ("Measured against `d3e59de7` on 2026-08-25"), not a live table, and
  `3IOmgCA2` set the precedent of leaving it alone; refreshing one
  bucket's rows would leave the document half-current.
- **No new `-- cast: from any` anywhere.** The only casts this diff adds
  are the two in `cosmic/deep.tl`, with the reasons named above.
- **Do not touch any other file.** The diff is three sources plus the
  regenerated `_build/casts_baseline.tl`.

## Acceptance

All commands run verbatim from the repo root.

- `bin/cosmic --make ci` ends **`ci: PASS (5 stages)`**.

- **The 13 sites are gone.**

  ```
  grep -c -- "-- cast: .*from any" cosmic/deep_test.tl cosmic/deep_example.tl
  ```

  reports `0` for each (8 and 5 at `9c1ff401`), and

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: .*from any" | wc -l
  ```

  reports exactly **13 fewer** than at pull — 131 if the bucket is still
  144. Re-measure at pull and quote both numbers.

- **The two boundary casts are the only ones added, and they say what
  they are.**

  ```
  grep -n -- "-- cast: " cosmic/deep.tl
  ```

  reports exactly **2** lines, neither containing `from any` (0 today),
  and

  ```
  grep -c -- "-- cast: " cosmic/deep_test.tl cosmic/deep_example.tl
  ```

  reports `0` for both.

- **The signatures are generic at both the function and the module
  record.**

  ```
  grep -n 'copy<T>\|merge<T>\|function<T>' cosmic/deep.tl
  ```

  reports **4** lines: `copy` and `merge` at their definitions, and both
  again as `DeepModule` fields.

- **The behaviour is unchanged**, which is what the existing tests and
  example are for:

  ```
  bin/cosmic --make test cosmic/deep_test.tl
  ```

  ends `test: PASS (1 file)` with `13 test functions`, and

  ```
  bin/cosmic --make example cosmic/deep_example.tl
  ```

  ends `example: PASS (1 file)` — the example runner re-checks each
  `-- Output:` block, so this is what proves the printed output did not
  move. No assertion is lost:

  ```
  grep -c 'assert(' cosmic/deep_test.tl
  ```

  reports at least **33** — the count at `9c1ff401`.

- **`equal`'s other callers still build.**

  ```
  bin/cosmic --make check _fuzz/literal_fuzz_test.tl _fuzz/json_fuzz_test.tl \
    _fuzz/url_fuzz_test.tl
  ```

  ends `check: PASS (3 files)`.

- **The floor was regenerated, not edited.** After
  `bin/cosmic --make run _build/casts.tl --baseline`,
  `bin/cosmic --make test _build/casts_test.tl` ends `test: PASS`;
  `_build/casts_baseline.tl` shows `cosmic/deep.tl` at **2** and no row
  for `cosmic/deep_test.tl` or `cosmic/deep_example.tl`.

## Enablement

None needed, and none to invent: the mechanism is Teal's own generics,
verified working here through a record field (probe fact 2), and every
file this slice touches is ordinary cosmic source under AGENTS.md's
existing conventions. The two probing traps are recorded as facts 3 and
4 above rather than left for the implementer to rediscover.
