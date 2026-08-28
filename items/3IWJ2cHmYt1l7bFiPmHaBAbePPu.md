## Goal

G3 — an honest type layer, no escape hatches. The metatable `is`-rescue
(3ISSFrCO / PR #1439, widened to named targets by 3IVSDpFq / PR #1477,
recorded as D32) admits a map- or array-shaped target by its KIND alone
and then narrows `mt` to that target's full type, VALUE type included.
A `metatable<T>` value's values are metamethods, not the target's value
type, so the narrowing manufactures a type the runtime never has.

D32's consequences section states this cost and says "closing it is
separate work with its own decision". Nothing on the board carried that
work; this item does.

Measured 2026-08-27 with `cosmic.teal.check_file`, driven with
`package.loaded["tl"] = dofile(<derived tl.lua>)` (a `package.path`
probe silently measures the shipped checker — 3IVenbbU), against a
checker derived by applying `3p/tl/tl_patch/*.tl` to a pristine
tl 0.24.8 unpacked from `o/3p/tl/v0.24.8.tar.gz`:

```
local function f(x: any): integer
  local mt = getmetatable(x)
  if not (mt is {string: integer}) then
    return 0
  end
  return mt.__index + 1
end
print(f(setmetatable({}, {__index = function() end})))
```

- main `a80cf0cd` derived checker: `ok=true`
- PR #1477 derived checker: `ok=true`, and the same subject spelled
  `type Ints = {string: integer}` then `mt is Ints` is `ok=true` too
  (it was `ok=false` before #1477 — reach widened, hole unchanged)

`mt.__index` is typed `integer`; at runtime it is a function, so
`mt.__index + 1` throws. The checker passes a program that cannot run.

## Change

Rebuild the rescue's is-fact over the target's KIND with `any` values,
so the kind test still narrows but no value type is invented. Four
files.

**Why this shape, measured.** All figures below were produced
2026-08-28 against `o/bin/cosmic` at main `6a4d0182`, by loading
candidate checkers with `package.loaded["tl"] = dofile(<copy of
o/3p/tl/tl.lua with the entry's `replace` text edited>)` and running
`cosmic.teal.check_file` on each subject. The subjects and their
verdicts:

| subject | today | this change |
|---|---|---|
| `mt is {string: integer}` then `mt.__index + 1` | `ok=true` | `ok=false`: `cannot use operator '+' for types <any type> and integer` |
| `type Ints = {string: integer}`; `mt is Ints`; `mt.__index + 1` | `ok=true` | same refusal |
| `mt is {integer}` then `mt[1] + 1` | `ok=true` | same refusal |
| `mt is {string: integer}` then `local m: {string: integer} = mt` | `ok=true` | `ok=false`: `in map value: got <any type>, expected integer` |
| the seven shipped tests (T1–T7) | pass | pass, unchanged |

T1–T7 are the seven `test_metatable_*` functions in
`cosmic/teal_narrowing_test.tl` today, in file order: T1
`..._is_table_narrows` (inline `{string: any}`), T2
`..._is_scalar_is_refused`, T3 `..._is_record_is_refused`, T4
`..._is_interface_is_refused`, T5 `..._is_array_narrows` (inline
`{string}`, uses `#mt`), T6 `..._is_map_alias_narrows` (alias of
`{string: any}`), T7 `..._is_array_alias_narrows` (alias of `{string}`,
uses `#mt`).

The escape row is why the hole is worth closing at all: the
manufactured type does not stay inside the guard — it assigns out into
an ordinary variable or argument.

**What the checker can already spell, measured.** `metatable<T>` is a
RECORD in tl's stdlib (`o/3p/tl/tl.lua:20`, `global record
metatable<T>`) whose `__index`/`__newindex` are declared `any`. On an
unnarrowed `local mt = getmetatable(x)` the tree checker gives
`mt.__index` type `any`, refuses `mt.nope` (`invalid key 'nope' in
record 'mt'`), refuses `#mt` and refuses `mt[1]`. So the honest
metamethod shape needs no new spelling — it is the type the variable
already has. That makes this a small fix, not a design problem.

1. **`3p/tl/tl_patch/narrow.tl`** (403 lines; `wc -l <
   3p/tl/tl_patch/narrow.tl` — 97 lines of headroom under the 500-line
   cap). Change ONLY the `replace` text of the `narrow-metatable-is`
   entry; its `find` anchor, its `note`, and the other two metatable
   entries stay byte-identical. The new `replace` is the current one
   with the bare `return { [f.var] = f }` replaced by a rebuild of the
   fact over the same kind with `any` values:

   ```
                  elseif not self:is_a(f.typ, typ) then
                     if is_table_metatable(self, typ, f.typ) then
                        -- cosmic carried patch: the rescue admits the
                        -- target by its KIND, so only the kind may reach
                        -- the narrowed variable. A metatable<T>'s values
                        -- are metamethods, not the target's value type,
                        -- so the fact is rebuilt over the same kind with
                        -- `any` values: `mt is {string: integer}` narrows
                        -- mt to {string: any}, never to {string: integer},
                        -- and mt.__index stops typing as integer.
                        local metatable_target = f.typ
                        if metatable_target.typename == "nominal" then
                           metatable_target = self:resolve_nominal(metatable_target)
                        end
                        local anyt = a_type(f.w, "any", {})
                        local opened
                        if metatable_target.typename == "array" then
                           opened = a_type(f.w, "array", { elements = anyt })
                        else
                           opened = a_type(f.w, "map", {
                              keys = metatable_target.keys, values = anyt,
                           })
                        end
                        return { [f.var] = IsFact({ fact = "is",
                           var = f.var, typ = opened, w = f.w,
                           no_infer = f.no_infer }) }
                     end
                     self.errs:add(f.w, f.var .. " (of type %s) can never be a %s", typ, f.typ)
                     return { [f.var] = invalid_from(f) }
   ```

   `a_type`, `IsFact` and `resolve_nominal` are all in scope at this
   site (`invalid_from`, three lines above the entry's insertion point,
   uses the first two) — verified by running the edited checker.
   Update the entry's `note` to say the fact carries the kind, not the
   target. The indentation above is this spec's; inside the patch's
   `[=====[ ]=====]` literal, keep the surrounding file's existing
   indentation exactly, since `find`/`replace` are byte-exact.

2. **`cosmic/teal_metatable_test.tl`** — a NEW file. `cosmic/teal_narrowing_test.tl`
   is 452 lines (`wc -l < cosmic/teal_narrowing_test.tl`), 48 under the
   cap, and four new tests at ~22 lines each do not fit; that file's own
   header records that it was already split off `teal_test.tl` for the
   same reason. So:
   - move lines 287–452 of `cosmic/teal_narrowing_test.tl` verbatim
     (the block from the `-- The metatable-is patch:` comment through
     `test_metatable_is_array_alias_narrows()`) into the new file —
     seven test functions, `grep -c '^test_metatable'
     cosmic/teal_narrowing_test.tl` is 7 today and must become 0;
   - give the new file the same preamble the source file uses: the
     `#!/usr/bin/env cosmic` line, a `---` header saying it pins the
     metatable half of the carried tl patch, `local fs =
     require("cosmic.fs")`, `local teal = require("cosmic.teal")`,
     `local tmpdir = os.getenv("TEST_TMPDIR")`;
   - add four tests, each in the file's existing shape (write the
     subject with `fs.write`, `teal.check_file`, assert on
     `result.ok`), called on the line after their `end`:
     - `test_metatable_is_concrete_map_does_not_type_the_value` — the
       Goal's subject; asserts `not result.ok` and that the joined
       error messages contain `cannot use operator '+'`.
     - `test_metatable_is_concrete_map_alias_does_not_type_the_value` —
       the same via `local type Ints = {string: integer}`; same
       assertions.
     - `test_metatable_is_array_does_not_type_the_element` —
       `mt is {integer}` then `mt[1] + 1`; same assertions.
     - `test_metatable_narrow_does_not_escape_into_a_concrete_map` —
       `mt is {string: integer}` then `local m: {string: integer} = mt`;
       asserts `not result.ok` and that the messages contain `in map
       value`.

3. **`_make/patch_test.tl`** (291 lines; 209 of headroom). Add
   `test_reverse_flips_the_metatable_value_type`, modelled line-for-line
   on the file's existing `test_reverse_flips_the_checker_on_the_real_pin`
   (line 253): save `package.loaded["tl"]`, call `patch.reverse` with
   `pin = "3p/tl/tl_pin.tl"`, `dir = "o/3p/tl"`, `entries =
   {"narrow-metatable-is"}`, `file = "tl.lua"`, `module_name = "tl"`,
   re-check the Goal's subject through `cosmic.teal`, restore
   `package.loaded["tl"]`, then assert that the SHIPPED checker refuses
   the subject and the REVERSED one refuses it too but with a different
   message — measured 2026-08-28, reversing this one entry makes the
   subject report `mt (of type metatable<<any type>>) can never be a
   {string : integer}`, which the shipped checker must NOT say. Assert
   on those two message substrings, so the test cannot pass with the
   entry absent.

4. **`docs/decisions/d33-<slug>.md`** plus an amendment to
   `docs/decisions/d32-metatable-rescue-judges-resolved-shape.md`.
   `ls docs/decisions/` shows d32 is the highest, so 33 is the next free
   number. D33 records: the rescue's fact carries the target's KIND, not
   the target. Its `rejected:` section carries the three measured
   losers below, each with its measured cost. D32 gets `status: amended
   2026-08 (D33 closed the value-type hole)` and a final `- **amended
   2026-08 (D33 closed the value-type hole):**` bullet saying its stated
   accepted cost no longer holds; its body is not otherwise touched.
   Run `bin/cosmic _docs/derive.tl` to rewrite the index table.

   The three rejected options, measured 2026-08-28 by running each as an
   edited checker over the same subject set:
   - **narrow to nothing — leave `mt` at `metatable<T>`.** Closes the
     hole and is maximally honest (`mt.nope` becomes an invalid-key
     error). Loses because it flips T5 `array-len` and T7
     `array-alias-len` to `ok=false` (`cannot use operator '#' on type
     metatable<<any type>>`): the array half of D32 stops admitting
     anything, one day after it was decided.
   - **drop `narrow-metatable-is` entirely, keeping the helper and the
     negated-branch entry.** Looks like the obvious revert of the
     unsound half. Loses because it flips T5, T6 AND T7 to `ok=false`
     (`mt (of type metatable<<any type>>) can never be a Meta`) — T6 is
     the `{string: any}` ALIAS, which is D32's whole contribution.
     (T1, the INLINE `{string: any}`, survives: measured, tl's own
     subtyping already admits it through the `self:is_a(typ, f.typ)`
     branch above the rescue, so the rescue's positive half exists only
     for targets a metatable is not.)
   - **refuse a target whose value type is not `any`.** Turns the
     unsound narrow into a hard error rather than a weaker type. Loses
     because it re-introduces on the value axis exactly the asymmetry
     D32 removed on the naming axis: `{string: any}` narrows and the
     byte-equivalent `{string: integer}` is refused, with an error that
     names no fix.
   The upstream option (build the is-fact from the resolved type in tl
   itself) is not rejected — D21's maturity clause and D32's "what would
   make us revisit" already stand; D33 restates that landing it upstream
   deletes the carried entry rather than amending D33.

## Non-goals

- Do NOT re-narrow which KINDS the rescue admits — D32 settled `{map,
  array}`, records and interfaces refused. That is the shape question,
  not the value-type question.
- Do NOT reintroduce the spelling asymmetry D32 removed.
- Do NOT edit `narrow-metatable-helper` or `narrow-metatable-not`, and
  do NOT delete `narrow-metatable-is`. The helper carries D32's kind
  set; the `not` entry is what keeps `if not (mt is …)` from poisoning
  `mt` to invalid (measured: reversing all three makes T1 report
  `cannot resolve a type for mt here`).
- Do NOT add a `tl.tl` counterpart entry. All three metatable entries
  target `tl.lua` only — this is checker logic, not a stdlib
  declaration like `narrow-assert-decl`, which needs both.
- Do NOT change `cosmic/fs/types.tl`. `grep -rn "mt is " --include=*.tl
  . | grep -v '^./o/'` shows the tree's only production use of the
  rescue is `extend_metatable` at `cosmic/fs/types.tl:248`, and it uses
  `{string: any}` — measured unaffected by this change.
- Do NOT bump `bin/cosmic.pin`, and do NOT touch `3p/tl/tl_pin.tl`
  (version or sha256). The archive is unchanged; only the patch data is.
- Do NOT commit anything under `o/`.
- No new lint, no new `--check` rule, no change to `_make/patch.tl`.

## Acceptance

Run from the repo root, on a branch cut off the latest `origin/main`.

- `git diff origin/main...HEAD --name-only` lists exactly these seven
  paths and nothing else:
  `3p/tl/tl_patch/narrow.tl`, `cosmic/teal_narrowing_test.tl`,
  `cosmic/teal_metatable_test.tl`, `_make/patch_test.tl`,
  `docs/decisions/d32-metatable-rescue-judges-resolved-shape.md`,
  `docs/decisions/d33-<slug>.md`, and `docs/decisions/README.md`
  (the derived index).
- `bin/cosmic --make fetch` ends `fetch: PASS` — it is what re-applies
  the changed patch DATA into the unpack directory. Then, against the
  DERIVED checker:
  - `grep -c "local metatable_target" o/3p/tl/tl.lua` is `1` (it is `0`
    today).
  - `grep -c "return { \[f.var\] = f }" o/3p/tl/tl.lua` is `3` (it is
    `4` today: the rescue's occurrence is the one that goes).
- `bin/cosmic --make test cosmic/teal_metatable_test.tl` ends
  `test: PASS (1 file)` and prints `(11 test functions)`;
  `grep -c '^test_' cosmic/teal_metatable_test.tl` is `11`.
- `grep -c '^test_metatable' cosmic/teal_narrowing_test.tl` is `0` (it
  is `7` today) and `grep -c '^test_' cosmic/teal_narrowing_test.tl` is
  `9` (it is `16` today).
- `bin/cosmic --make test _make/patch_test.tl` ends
  `test: PASS (1 file)` and prints `(11 test functions)` — it prints
  `(10 test functions)` today (measured 2026-08-28).
- `bin/cosmic --make test 3p/tl/tl_test.tl` ends `test: PASS (1 file)`
  with `3 tests: 3 passed` — the patched checker's own smoke test.
- `bin/cosmic --make test _build/coldbuild_test.tl` ends
  `test: PASS (1 file)`. It passes today (measured 2026-08-28, 16.3s);
  a failure here means the diff needs a checker newer than the pinned
  release and must stage behind a pin bump.
- `bin/cosmic _docs/derive.tl` then `bin/cosmic --make test
  _build/docs_test.tl` ends `test: PASS (1 file)`.
- `wc -l cosmic/teal_metatable_test.tl` ≤ 500,
  `wc -l cosmic/teal_narrowing_test.tl` ≤ 500,
  `wc -l 3p/tl/tl_patch/narrow.tl` ≤ 500,
  `wc -l _make/patch_test.tl` ≤ 500.
- `bin/cosmic --make ci` ends `ci: PASS`. If the coverage ratchet
  complains, run exactly the regen command its failure message prints
  and commit the result — no other way of quieting a gate is in scope.

## Enablement

`none needed` for tooling — the countermeasure this item would have
wanted, `patch.reverse`, landed as 3IVenbbU / PR #1479 and this spec
spends it (Change item 3, Acceptance's reverse-apply proof). No blocker
items; `blocked_by` stays empty.

**No pin bump stages first, measured.** The cold-build rule is that
generation 1 compiles the whole tree with the PINNED release's checker,
so a source needing the tree's own checker passes `--make ci` and fails
a cold build. This diff cannot trip it: it makes the checker STRICTLY
more refusing, and generation 1 runs the more permissive pinned one;
the two source files it adds to are Teal whose new content is string
literals (the patch entry's `[=====[ ]=====]` body, the tests' subject
programs), which no checker version judges differently.
`bin/cosmic --make test _build/coldbuild_test.tl` passes today
(2026-08-28, 16.3s, `test: PASS (1 file)`) and is in Acceptance so the
claim is re-checked rather than trusted.

The wrong turns a literal-minded builder takes here, each with the
Acceptance line or Non-goal that catches it:

1. **Probing with `package.path`.** Dropping a modified `tl.lua` on
   `package.path` and calling `cosmic.teal` measures the checker
   embedded in the binary, not the copy on disk, and reports a
   confident wrong answer with nothing logged — the trap that cost
   three sessions before 3IVenbbU. Use `package.loaded["tl"] =
   dofile("o/3p/tl/tl.lua")` to measure the DERIVED checker by hand,
   and `_make.patch`'s `reverse` (read its header, "Probing an entry")
   for the with/without comparison. Caught by: the Acceptance greps
   run against `o/3p/tl/tl.lua`, not against a `package.path` copy.
2. **Forgetting `--make fetch`.** The patch is DATA; editing
   `3p/tl/tl_patch/narrow.tl` changes nothing until `fetch` re-applies
   it into `o/3p/tl/tl.lua`. A builder who edits and runs `--make test`
   will see the old behaviour and conclude the edit did not work.
   Caught by: the two `grep -c` bounds on `o/3p/tl/tl.lua`, which are
   stated with today's values so a stale unpack directory is visible.
3. **Writing a test that passes either way.** Asserting only
   `not result.ok` on the new subjects proves nothing: they are
   `ok=false` with the whole rescue reversed too, for an entirely
   different reason (`can never be a {string : integer}` rather than
   `cannot use operator '+'`). Caught by: Change item 2 requiring the
   message substring in each new assertion, and Change item 3 plus the
   `_make/patch_test.tl` Acceptance line requiring the reverse-apply
   proof that pins BOTH messages.
4. **Reverting the rescue instead of repairing it.** "The positive half
   is unsound, delete it" is the intuitive move and it is wrong:
   measured, it also kills the `{string: any}` ALIAS case (T6) that
   PR #1477 landed the day before. Caught by: the Non-goal forbidding
   deletion of `narrow-metatable-is`, and by the seven moved tests,
   which must still pass in the new file.
5. **Growing `cosmic/teal_narrowing_test.tl` past 500 lines.** It is at
   452; four new tests do not fit, and `--check lint` fails the build
   with no other diagnosis. Caught by: Change item 2 directing the move
   into a new file, and the four `wc -l` bounds in Acceptance.
6. **Skipping the decision record, or writing the wrong kind.** D32
   says this work needs "its own decision", and `decide`'s independent
   test agrees: there are three losing options a competent contributor
   would pick (they are enumerated with their measured costs in Change
   item 4), so this is a decision, not a bug fix. It is an AMENDMENT to
   D32, not a supersession — D32's call (resolve the nominal, admit map
   and array) stands untouched; only its stated accepted cost goes
   away. Caught by: Change item 4 naming both files, and Acceptance's
   `_docs/derive.tl` + `_build/docs_test.tl` pair, which fails on a
   malformed H1 or a drifted index row.
7. **Bumping the pin "to be safe".** Nothing here needs one, and a pin
   bump would drag an unrelated tl version change into a patch-data
   diff. Caught by: the Non-goal, and the six-path `git diff
   origin/main...HEAD --name-only` bound.
