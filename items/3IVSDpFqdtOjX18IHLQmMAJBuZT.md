## Goal

G3 — an honest type layer, no escape hatches. Under 3ISJI4Lg's fourth
gap (metatable is-dispatch, landed as 3ISSFrCO / PR #1439): the rescue
stops judging how a target was SPELLED and starts judging what shape it
IS, so `mt is Meta` narrows wherever the byte-identical
`mt is {string: any}` already does, while a record or interface nominal
keeps failing.

Measured 2026-08-27 against main `ae5d1581` with `cosmic.teal.check_file`,
byte-identically under `o/bin/cosmic` (tree checker) and
`o/bootstrap/cosmic` (pinned release) — today's asymmetry:

| subject | today |
|---|---|
| `mt is {string: any}` (inline map) | `ok=true` |
| `type Rec = {string: any}` then `mt is Rec` | `ok=false` |
| `mt is {string}` (inline array) | `ok=true` |
| `type Arr = {string}` then `mt is Arr` | `ok=false` |
| `mt is Handler` (record nominal) | `ok=false` |

The refused cases all report `cannot resolve a type for mt here` (x2)
plus `mt (of type metatable<<any type>>) can never be a <Name>`. The
cause is at `o/3p/tl/tl.lua:14136`,
`node.known = IsFact({ var = node.e1.tk, typ = ub, w = node })` — the
is-fact carries `ub`, the UNRESOLVED target — so a named type reaches
`is_table_metatable` (`3p/tl/tl_patch/narrow.tl:241`, derived at
`o/3p/tl/tl.lua:11530`) with `typename == "nominal"` and never matches
`table_kinded` (`3p/tl/tl_patch/narrow.tl:239`, derived at
`o/3p/tl/tl.lua:11528`).

This is a NEW decision, not a bug fix, and the record is part of the
slice (see `Change` step 3).

## Change

Three files, one build step, one derived-index regen.

**Sequencing — this slice starts after PR #1468 merges.** 3IVL4phw
(#1468) trims `table_kinded` to `{ map = true, array = true }` inside
this very entry, and without that trim the same three lines below admit
records and interfaces, reversing 3ISSFrCO's stated wall. Measured
2026-08-27: with the untrimmed set plus the resolve, `mt is Handler`
flips to `ok=true`; with #1468's trimmed set plus the resolve it stays
`ok=false`. Branch off `origin/main` only once #1468 is merged; every
line number and quoted string below is #1468's post-merge text
(`git show claude/3IVL4phw-table-kinded:<path>`), recorded here so the
implementer can diff rather than guess. `blocked_by` carries the edge.

**1. `3p/tl/tl_patch/narrow.tl`, entry `narrow-metatable-helper` only.**
Inside that entry's `replace` string:

- Insert three lines at the head of `is_table_metatable`'s body, above
  the existing `return table_kinded[target.typename] == true and` line
  (line 246 post-#1468), at the 9-space indentation that `return` uses:

```
         if target.typename == "nominal" then
            target = self:resolve_nominal(target)
         end
```

  This is the shape this same file's `without_nil` already uses
  (`3p/tl/tl_patch/narrow.tl:287-290` on main `ae5d1581`;
  `grep -c 'resolve_nominal' 3p/tl/tl_patch/narrow.tl` → `3`), so
  `self:resolve_nominal` is established practice inside carried patch
  code and needs no new plumbing. Nothing else in the helper moves.

- Rewrite the two sentences #1468 added about named targets — lines
  237-241 post-#1468, from `-- name. The is-fact carries the UNRESOLVED
  target type (ub), so a` through `-- literal does.` — because this
  change makes them false. The replacement states the new rule: the
  is-fact carries the UNRESOLVED target type (`ub`), so a named type
  arrives with `typename == "nominal"`; resolve it first and judge the
  STRUCTURAL kind, so an inline `{K: V}` / `{T}` and a
  `type X = {K: V}` alias of one are the same case. A record or
  interface nominal resolves to `record` / `interface`, neither of which
  is in this set, so it keeps failing — a metatable carries metamethod
  keys, not a record's declared fields. Keep the surrounding sentences
  (the `-- cosmic carried patch:` opener through `-- name.`, and the
  closing two lines about the call sites sharing the closure and self
  being passed explicitly) byte-identical, and drop the word `inline`
  from the opening sentence, which now over-narrows.

- Change the entry's `note` (line 224 post-#1468) to
  `note = "recognize the std metatable<T> nominal against a map- or array-shaped is-target, inline or named",`

Keep byte-identical: the entry's `find` anchor (it anchors on
`invalid_from`, which does not move — a `find` change is walled below),
`local table_kinded = { map = true, array = true }` exactly as #1468
leaves it, the rest of `is_table_metatable`'s body, and the entries
`narrow-metatable-is` and `narrow-metatable-not`.

**2. `cosmic/teal_narrowing_test.tl`.** One comment amendment and two
new tests.

- Amend the three comment lines 334-336 post-#1468, which read
  `-- ...and a NAMED target never reaches the rescue: the is-fact carries`
  / `-- the unresolved type, so a record nominal arrives as "nominal", not`
  / `-- "record", and the can-never-be refusal stands.` That claim is
  false after this change. Rewrite it to say that the target IS now
  resolved, and a record's resolved typename is not in `table_kinded`,
  so the refusal stands for a different reason. Change nothing else in
  the five existing metatable tests.

- Append these two tests after `test_metatable_is_array_narrows()`
  (line 401 post-#1468, the file's last statement). Both bodies were
  run verbatim on 2026-08-27 (evidence in `Acceptance` item 8):

```teal
-- A named alias of a map narrows exactly as the inline literal does:
-- the rescue resolves a nominal target and judges its structural kind.
local function test_metatable_is_map_alias_narrows()
  local path = fs.join(tmpdir, "narrow_metatable_map_alias.tl")
  assert(fs.write(path, [[
local type Meta = {string: any}
local function m(x: any): boolean
  local mt = getmetatable(x)
  if not (mt is Meta) then
    return false
  end
  return mt.__index ~= nil
end
print(m({}))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "a metatable narrowed by `is Meta` (an alias of a map) must check: " ..
    table.concat(msgs, "; "))
end
test_metatable_is_map_alias_narrows()

-- ...and the array half of the same rule.
local function test_metatable_is_array_alias_narrows()
  local path = fs.join(tmpdir, "narrow_metatable_array_alias.tl")
  assert(fs.write(path, [[
local type Names = {string}
local function n(x: any): integer
  local mt = getmetatable(x)
  if not (mt is Names) then
    return 0
  end
  return #mt
end
print(n({}))
]]))
  local result = teal.check_file(path)
  local msgs = {}
  for _, e in ipairs(result.errors) do
    msgs[#msgs + 1] = e.message
  end
  assert(result.ok,
    "a metatable narrowed by `is Names` (an alias of an array) must check: " ..
    table.concat(msgs, "; "))
end
test_metatable_is_array_alias_narrows()
```

**3. `docs/decisions/d32-<slug>.md` — write the record**, then run
`bin/cosmic _docs/derive.tl` to rewrite the derived index table in
`docs/decisions/README.md` (never hand-edit those rows). `32` is the
next free number: `ls docs/decisions/` on main `ae5d1581` tops out at
`d31-gate-noise-from-every-control-pair.md`, and no local branch claims
a `d32` file (checked with `git ls-tree -r --name-only <branch>
docs/decisions/` over every branch `git branch --format='%(refname:short)'`
lists). Use the four-section form and H1 grammar in
`skills/decide/SKILL.md` (`# D32 — <lowercase claim>`, em dash,
`date: 2026-08`, `status: active`). The record must carry:

- **decision** — the metatable is-rescue resolves a nominal target and
  admits it by its RESOLVED structural kind, restricted to `map` and
  `array`. A target resolving to `record` or `interface` keeps failing;
  so does every scalar, aliased or not. Naming is irrelevant: the source
  side is still identity against `cache_std_metatable_type`.
- **context** — the asymmetry table in `Goal` above, its `ub` cause with
  the `o/3p/tl/tl.lua` site, and the fact that the constraint being
  narrowed lived only in a completed board item's Non-goals (3ISSFrCO)
  until now.
- **rejected**, each with the reason it lost:
  - resolve and admit every table-kinded resolved kind, records and
    interfaces included — one line SHORTER (delete the set), and it is
    what Teal's own `is` does for an `any`-typed value. It loses because
    a `metatable<T>` value carries metamethod keys, so narrowing it to
    `Handler {name: string}` types `mt.name` as `string` for a field
    that does not exist.
  - leave the rescue inline-only and document the limitation. It loses
    because "inline narrows, the byte-identical alias does not" is an
    accident of where the is-fact is built (`ub`, not the resolved
    `rb`), not a property anybody chose, and it teaches users to inline
    a shape they already named.
  - match the target by NAME rather than by resolved kind — already
    rejected by 3ISSFrCO in favour of identity against
    `cache_std_metatable_type`; restated so nobody re-opens it.
- **consequences** — including the accepted cost, measured: the rescue
  is already unsound for the VALUE type, since `mt is {string: integer}`
  checks clean today under the shipped checker (probed 2026-08-27 under
  `o/bootstrap/cosmic` → `ok=true`), typing `mt.__index` as `integer`.
  This decision widens the ways to REACH that hole (by name) without
  creating it; closing it is separate work and this record does not
  claim to. Also state what would make us revisit: an upstream tl that
  builds the is-fact from the resolved type, which deletes the entry
  outright, per D21's maturity clause.

**4. Re-apply the patch before gating.** This is patch DATA: the edit
does not reach the checker until the pin is re-unpacked and re-patched.
Run `bin/cosmic --make fetch` after editing
`3p/tl/tl_patch/narrow.tl`. Editing `o/3p/tl/tl.lua` directly is not the
change — `fetch` restores it from the pristine archive.

Capacity, measured 2026-08-27 (`git show
claude/3IVL4phw-table-kinded:<path> | wc -l`): post-#1468
`3p/tl/tl_patch/narrow.tl` is `397` (103 under the 500-line cap) and
`cosmic/teal_narrowing_test.tl` is `401` (99 under). The drafted test
file with both new tests appended measures `452` lines.

## Non-goals

- Do NOT add `record` or `interface` back to `table_kinded`, and do NOT
  delete the set to "simplify". Admitting a record is the option D32
  rejects; a diff that does it contradicts the record it ships beside.
- Do NOT touch entries `narrow-metatable-is` or `narrow-metatable-not`,
  or any part of `is_table_metatable` other than the three inserted
  lines.
- Do NOT change a `find` anchor anywhere in `3p/tl/tl_patch/`. An anchor
  must keep matching the pinned tl source exactly once; a pin bump that
  moves one is supposed to fail loudly, and that signal is not softened
  here. This entry's anchor is `invalid_from` and does not move.
- Do NOT touch any other entry or file in `3p/tl/tl_patch/`. In
  particular leave the loop-site work (3IVQJa0b, PR #1473), the
  assigned-scan shapes (3IVL5DSr, PR #1472), 3IVZsiwL and 3IVenbbU
  alone.
- Do NOT touch `_make/patch.tl` or `_make/fetch.tl` (the mechanism is
  frozen by PR #1424), `3p/tl/tl_pin.tl`, or `bin/cosmic.pin`. No pin
  bump, no version change, no release staging.
- Do NOT close the VALUE-type unsoundness (`mt is {string: integer}`
  checking clean). It predates this slice, D32 records it as an accepted
  cost, and narrowing it is separate work with its own decision.
- Do NOT delete, weaken, reword or reorder the five existing metatable
  tests, beyond the single three-line comment at lines 334-336 that
  `Change` names. Do NOT touch any other test in the file.
- Do NOT touch `cosmic/fs/types.tl` (the tree's one production metatable
  is-dispatch site, an inline `mt is {string: any}` at line 248) or any
  other product source, and do NOT convert any site to a named alias to
  exercise the new rule. The source-side retires are 3IU5Vhvy's, gated
  on a pin bump.
- Do NOT hand-edit the derived table rows in `docs/decisions/README.md`;
  `_docs/derive.tl` owns them. Do NOT renumber, retitle, or amend any
  existing decision record.
- Do NOT raise the 500-line file cap or add an exemption for patch data.

## Acceptance

Run from the repo root, on a branch cut from `origin/main` after #1468
has merged. Every command is safe to run verbatim and writes only into
`o/` or a fresh `mktemp -d`.

1. `bin/cosmic --make fetch` ends `fetch: PASS (2 pins)` — the edited
   entry still applies exact-once to a freshly unpacked `tl.lua`.
2. `grep -c 'target = self:resolve_nominal(target)' o/3p/tl/tl.lua` →
   `1`. It is `0` today. This is the proof the edit reached the DERIVED
   checker rather than only the patch source.
3. `grep -c 'local table_kinded = { map = true, array = true }' o/3p/tl/tl.lua`
   → `1`, and
   `grep -c 'record = true\|interface = true' 3p/tl/tl_patch/narrow.tl`
   → `0` — #1468's trim is intact and was not widened.
4. `grep -c 'is_table_metatable' o/3p/tl/tl.lua` → `3` (one definition,
   two call sites) — the helper grew a resolve, it did not move or
   multiply.
5. `bin/cosmic --make ci` ends `ci: PASS`.
6. `bin/cosmic --make test _build/coldbuild_test.tl` ends
   `test: PASS (1 file)` — generation 1's pinned checker still accepts
   the whole tree, the new tests included.
7. `bin/cosmic --make test cosmic/teal_narrowing_test.tl` ends
   `test: PASS (1 file)` and prints
   `✓ cosmic/teal_narrowing_test.tl (16 test functions)`. It is
   `(14 test functions)` after #1468; the two new tests are the
   difference.
8. **The reverse-apply proof — the new tests must FAIL without the
   entry.** Two independent forms; run both.

   a. The pinned-release oracle:
   `TEST_TMPDIR=$(mktemp -d) o/bootstrap/cosmic cosmic/teal_narrowing_test.tl; echo $?`
   → NON-ZERO, with stderr naming
   `test_metatable_is_map_alias_narrows` and a message ending
   `can never be a Meta`. The pinned binary's embedded checker has no
   resolve, so a test that passed there would be vacuous. (Note: this
   inverts #1468's Acceptance item 8, which required `0` from the same
   command before these tests existed. That is expected and is the point.)

   b. Entry-level reverse-apply on a scratch copy of the DERIVED
   checker, isolating exactly these three lines:

```
export TMP=$(mktemp -d)
o/bin/cosmic -e 'local h=assert(io.open("o/3p/tl/tl.lua"));local s=h:read("a");h:close();local a=[[         if target.typename == "nominal" then
            target = self:resolve_nominal(target)
         end
]];local out,n=s:gsub((a:gsub("%p","%%%0")),"");assert(n==1,"expected 1 occurrence, got "..n);local o=assert(io.open(os.getenv("TMP").."/tl_noresolve.lua","w"));o:write(out);o:close();print("reverse-applied "..n.." block")'
printf '%s\n' 'local type Meta = {string: any}' 'local function m(x: any): boolean' '  local mt = getmetatable(x)' '  if not (mt is Meta) then return false end' '  return mt.__index ~= nil' 'end' 'print(m({}))' > $TMP/subject.tl
for TL in o/3p/tl/tl.lua $TMP/tl_noresolve.lua; do TLP=$TL o/bin/cosmic -e 'package.loaded["tl"]=dofile(os.getenv("TLP"));local r=require("cosmic.teal").check_file(os.getenv("TMP").."/subject.tl");print(os.getenv("TLP")..": ok="..tostring(r.ok))'; done
```

   must print `reverse-applied 1 block`, then
   `o/3p/tl/tl.lua: ok=true` and `<tmp>/tl_noresolve.lua: ok=false`.
   The `package.loaded["tl"] = dofile(...)` preload is mandatory:
   `require("tl")` inside the cosmic binary resolves `/zip/tl.lua` from
   its own zip and IGNORES `package.path`, so a `package.path` probe
   silently measures the shipped checker (3IVenbbU). This exact command
   block was run on 2026-08-27 against a scratch checker carrying the
   change and printed those three lines.
9. `wc -l 3p/tl/tl_patch/narrow.tl` → at most `500` (`397` after #1468);
   `wc -l cosmic/teal_narrowing_test.tl` → at most `500` (`452` in the
   drafted version).
10. `bin/cosmic --make test _build/docs_test.tl` ends
    `test: PASS (1 file)` — the derived decisions index matches the new
    record, so `_docs/derive.tl` was run.
11. `git diff origin/main...HEAD --name-only` lists exactly four paths:
    `3p/tl/tl_patch/narrow.tl`, `cosmic/teal_narrowing_test.tl`,
    `docs/decisions/README.md`, and `docs/decisions/d32-<slug>.md`.

## Enablement

**Blocked on 3IVL4phw (PR #1468)** — mirrored in `blocked_by`. Not a
preference: measured 2026-08-27 against a scratch checker built three
ways from main `ae5d1581`'s derived `o/3p/tl/tl.lua`, driven through
`cosmic.teal.check_file` with the `package.loaded["tl"]` preload:

| checker | inline map | alias of map | alias of array | record nominal |
|---|---|---|---|---|
| main today | ok=true | ok=false | ok=false | ok=false |
| main + resolve, UNTRIMMED set | ok=true | ok=true | ok=true | **ok=true** |
| #1468's entry, no resolve | ok=true | ok=false | ok=false | ok=false |
| #1468's entry + resolve | ok=true | ok=true | ok=true | ok=false |

Applied before #1468, this slice admits records — reversing what
3ISSFrCO settled. Applied after it, records stay refused. The two also
edit the same entry and the same test-file tail, so they must serialize
regardless.

**The cold-build rule does not bite; no pin bump stages first —
measured, not reasoned.** The drafted test file (post-#1468 text plus
both new tests) type-checks clean under the PINNED release:
`o/bootstrap/cosmic --check types --include-dir . --include-dir
o/_types/types_gen <draft>` printed `Type check passed` and exited `0`
on 2026-08-27. The tests write their subject source into `TEST_TMPDIR`
and check it at RUN time, so generation 1 never needs the new rule to
COMPILE them; `--make ci` converges and runs them under the checker the
tree just built, where the drafted file completed all 16 tests against a
scratch checker carrying the change. The same file run under the pinned
binary fails, which is Acceptance 8a, not a gate.

**No regression to the rest of the tree — measured.** Every `.tl` under
`cosmic _cli _make _tool _build cmd` (458 files, `find ... ! -name
'*.d.tl'`) was `check_file`d under three checkers — main's derived
`o/3p/tl/tl.lua`, #1468's entry alone, and #1468's entry plus the
resolve — and the three `ok=`/error-count listings are byte-identical
(`diff` clean). Resolution also leaves the adversarial cases alone: an
undefined nominal (`mt is Nope`) keeps its `unknown type Nope` error
with no extra diagnostic and no crash, `type S = string` then `mt is S`
keeps failing, and a non-metatable `x is Rec` is untouched.

**Enablement check — five predicted wrong turns, each already walled:**

- landing before #1468 and silently admitting records → the
  `blocked_by` edge plus the table above; Acceptance 3 catches a widened
  set.
- editing `o/3p/tl/tl.lua` instead of the patch source → Acceptance 1
  and 2 (a `fetch` restores it from the pristine archive, so a direct
  edit disappears).
- skipping `--make fetch`, leaving the checker unchanged and passing 5
  vacuously → Acceptance 2.
- writing a test that passes either way → Acceptance 8, both halves, and
  the 3IVenbbU preload trap is stated inline there.
- shipping the behaviour with no record, leaving the constraint in a
  completed item's Non-goals → Acceptance 10 and 11.

No countermeasure needs its own item: each is an Acceptance command or a
Non-goal in this spec.
