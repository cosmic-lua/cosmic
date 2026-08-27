## Goal

G3 — an honest type layer, no escape hatches. The carried closure-carry
patch keeps a narrow inside a closure when the FILE never reassigns the
name. For a `global` the file is not the assignment universe: scope 1's
`vars` table IS `env.globals`, shared across every file checked in one
environment, which is the type-level mirror of the runtime `_G` sharing.
So another module assigns the global and an escaped closure runs on a
stale narrow, with no cast, no warning and no error anywhere.

The tree's own gates cannot see it, so the whole cost lands on user
projects cosmic checks — which is exactly the promise-transfer G3 and
the no-silent-bugs promise exist to protect.

## Evidence (measured 2026-08-27; tl pin v0.24.8, sha `8d7a143f…f022`)

**The bug is live, end to end, across a real module boundary.** Both
files type-check clean and the runtime is type-confused:

```teal
-- moda.tl
global gv: string | integer = "x"
local use: function(): string
if gv is string then
  use = function(): string return gv end
end
return {use = use}
```
```teal
-- main.tl
global gv: string | integer
local a = require("moda")
gv = 2
local s: string = a.use()
print("declared type: string; runtime type: " .. type(s))
print("upper: " .. s:upper())
```
```
$ o/bin/cosmic --check types moda.tl                              → Type check passed (exit 0)
$ o/bin/cosmic --check types --include-dir <dir> main.tl          → Type check passed (exit 0)
$ o/bin/cosmic main.tl
declared type: string; runtime type: number
main.tl:9: attempt to index a number value (local 's')
exit=1
```

**Control, confirming the mechanism rather than an unrelated path**: add
`gv2 = 2` at the bottom of the SAME file and the carry correctly drops —
`modb.tl:6:12: error: in return value: got string | integer, expected string`.
So the carry is governed exactly by `assigned_anywhere` over the chunk
root, and a cross-module assignment is invisible to it.

**The site.** `widen_all_unions` is untouched by the patch today
(`o/3p/tl/tl.lua:10910-10921`, identical in pristine and unpacked):

```lua
   function TypeChecker:widen_all_unions(node)
      for i = #self.st, 1, -1 do
         local scope = self.st[i]
         if scope.narrows then
            for name, _ in pairs(scope.narrows) do
               if not node or assigned_anywhere(name, node) then
                  self:widen_in_scope(i, name)
               end
            end
         end
      end
   end
```

The carried patch replaces stock `self:widen_all_unions()` with
`self:widen_all_unions(self.chunk_body)` at **seven** widen sites
(`closure-anon-function`, `closure-anon-macroexp`, `closure-fn-rvalue`,
`closure-global-function`, `closure-local-function`,
`closure-local-macroexp`, `closure-record-function`); the other two
entries are `closure-root` and `closure-assigned-scan`. With a `node`,
`assigned_anywhere` only ever sees THIS chunk's AST — which is why a
global slips through.

**Scope 1 is the global scope and it is shared** (`o/3p/tl/tl.lua:15076-15084`):

```lua
         st = {
            {
               vars = env.globals,
               pending_global_types = {},
            },
         },
```

Corroborated at `tl.lua:15170`, `:12941` (`local global_scope = self.st[1]`)
and `:12915` (`fail_unresolved_nominals(self.st[2], self.st[1])`, guarded
by `#self.st == 2`, so scope 2 is the chunk's top level).

`add_global` writes `self.st[1].vars[varname] = var` (`tl.lua:10946`),
with no `is_specialized`. A NARROW of that global is a fresh specialized
shadow entry in the current scope (`specialize_var`, `tl.lua:8475-8497`),
always at index ≥ 2 — the `["statements"]` visitor calls `begin_scope`
before any statement (`tl.lua:12907-12910`). So scope 1 never appears in
`scope.narrows`, and the widen loop's `i` is the NARROW's scope, not the
declaration's.

**The naive test over-approximates, and the tree would feel it.**
`self.st[1].vars[name] ~= nil` is true for a local merely SHARING a name
with a stdlib global (`tostring`, `type`, `next`, …), because those live
in `env.globals` too. Probed on three files, printing the narrow's scope,
the declaring scope, and the naive test:

| probe | narrowed name | narrow scope | declaring scope | `st[1].vars[name] ~= nil` |
|---|---|---|---|---|
| `global gv: string \| integer` | `gv` | 3 | **1** | true |
| `local lv` | `lv` | 3 | 2 | false |
| `local tostring` shadowing the stdlib | `tostring` | 3 | 2 | **true** |

The third row is the problem: the naive form spuriously widens a SOUND
local narrow. Errs conservative rather than unsound, but it is a real
behaviour change, and the tree does shadow.

**The tree declares 2 globals, not none — the opening capture is wrong.**

```
grep -rnE '^[[:space:]]*global[[:space:]]' --include='*.tl' . | grep -v '^\./o/'
```
→ `cosmic/cosmic_debug_test.tl:8: global TEST_BIN: string` and
`cmd/cosmic/main.tl:4: global warn: function(...: any)`.

Neither is exposed: `TEST_BIN` is a bare non-union, never narrowed;
`warn` is a non-union AND assigned in the same file (`cmd/cosmic/main.tl:433`),
so `assigned_anywhere` already widens it. **So this fix changes the
type-check result of no file currently in the tree** — which is what
makes the tests below the only evidence it works.

**No existing coverage.** `cosmic/teal_closure_test.tl` (118 lines, 4
tests) is the closure-carry home, split out of `teal_narrowing_test.tl`
under the 500-line cap. No test in ANY of the teal test files mentions
`global` — grep returns zero hits.

**Anchor uniqueness**, counted as fixed substrings over the raw bytes of
both the pristine archive and the unpacked `o/3p/tl/tl.lua` (counts
agree):

| candidate | count |
|---|---|
| `               if not node or assigned_anywhere(name, node) then` | **1** |
| that line preceded by `            for name, _ in pairs(scope.narrows) do` | **1** |
| bare `self:widen_in_scope(i, name)` without its 18-space indent | 2 (the other is `tl.lua:8652`, inside `widen_back_var`) |
| bare `assigned_anywhere` | 2 (definition + call) |

## Change

One new entry in `3p/tl/tl_patch/closure.tl`, plus tests.

**1. The patch entry**, named `closure-global-widen` so it sorts inside
the existing `closure-*` namespace. Anchor on the two-line form — the
`for` line plus the `if` line — because the replacement needs a
statement slot between them:

```
find:
            for name, _ in pairs(scope.narrows) do
               if not node or assigned_anywhere(name, node) then
```

The replacement inserts the declaring-scope walk and adds `decl == 1` as
a first disjunct, so a global is treated as always-assigned:

```lua
            for name, _ in pairs(scope.narrows) do
               -- cosmic carried patch: scope 1's vars table IS
               -- env.globals, shared by every file checked in one
               -- environment, so a global's assignment universe is not
               -- this file. assigned_anywhere only ever sees this
               -- chunk's AST, so another module's assignment is
               -- invisible to it and the narrow is kept -- an escaped
               -- closure then runs on a stale narrow. A narrow is a
               -- specialized shadow in a scope >= 2, so walk down for
               -- the scope the name is DECLARED in and treat scope 1
               -- as always-assigned. The walk, not st[1].vars[name],
               -- because env.globals also holds the stdlib: a local
               -- shadowing `tostring` would widen spuriously.
               local decl = 0
               for j = i, 1, -1 do
                  local sv = self.st[j].vars[name]
                  if sv and ((not sv.is_specialized) or sv.specialized_from) then
                     decl = j
                     break
                  end
               end
               if decl == 1 or not node or assigned_anywhere(name, node) then
```

The walk starts at `i` and mirrors tl's own
`get_real_var_from_lower_scope` (`o/3p/tl/tl.lua:7818-7826`), which
cannot be reused because it returns the var and not its index. Give the
entry a `note` in the style of its neighbours.

**2. `cosmic/teal_closure_test.tl` — three test functions**, each
`test_*` called on the line after its `end`, each driving the file's
existing `checks(name, src)` helper (`:23-32`) with source in a long
bracket, matching `test_the_anonymous_reassignment_hole_is_closed`
(`:72-90`) as the template:

- `test_a_global_narrow_does_not_carry_into_a_closure` — the single-file
  shape from Evidence; asserts `not ok`. This is the bug.
- `test_a_global_narrow_does_not_carry_into_a_named_function` — the same
  with a named `local function` rather than an anonymous one, since the
  named boundaries are where the patch introduced NEW unsoundness
  relative to stock (stock widened everything there); asserts `not ok`.
- `test_a_local_shadowing_a_stdlib_global_still_carries` — a
  `local tostring` narrowed and used in a closure, never reassigned;
  asserts `ok`. This is the over-approximation guard, and it is the case
  the naive `st[1].vars[name] ~= nil` test would fail.

Keep the file's trailing `print(...)` line last and stay under the
500-line cap (118 today).

## Non-goals

- **No change to any of the seven existing widen entries**, to
  `closure-root`, or to `closure-assigned-scan`. This adds one entry; it
  edits none.
- **No change to `widen_in_scope`, `assigned_anywhere`, `add_global`,
  `add_var`, or `specialize_var`.** The fix is one condition at one site.
- **No fork of tl.** The entry is a carried patch under the existing
  exact-once contract; if a pin bump moves the anchor, `--make fetch`
  must fail loudly and the patch be re-audited, exactly as the other
  entries do.
- **No new narrowing behaviour for locals.** A local narrow that carries
  today must still carry — that is what the third test pins.
- **No `global` declaration added, removed or changed in the tree**, and
  no edit to `cosmic/cosmic_debug_test.tl:8` or `cmd/cosmic/main.tl:4`.
- No edit to `teal_narrowing_test.tl`, `teal_nilflow_test.tl` or
  `teal_test.tl`; the closure-carry home is `teal_closure_test.tl`.
- No `docs/decisions/` record and no `docs/guides/checking.md` rewrite.
  This closes a hole the guides never promised was open; if the guides
  should say something about globals, that is its own item.
- No cast anywhere in the new code.

## Acceptance

1. **The patch applies, exactly once.**
   `bin/cosmic --make fetch` ends `fetch: PASS`. Then, on a tree that has
   already fetched, re-running it is a byte-for-byte no-op (the
   idempotence `patch.applied` provides). Quote both.

2. **The repo gate.** `bin/cosmic --make ci` ends `ci: PASS`.

3. **The bug is closed, single-file.** With the Evidence probe written to
   a scratch path OUTSIDE the repo (a `.tl` inside it joins the build
   graph):
   ```
   o/bin/cosmic --check types <scratch>/single.tl
   ```
   exits non-zero and names a `got string | integer, expected string`
   error. On `origin/main` today the same command prints
   `Type check passed` and exits 0 — quote both, they are the
   before and after.

4. **The bug is closed across a module boundary.** The two-module probe
   from Evidence: `--check types` on `moda.tl` now exits non-zero.
   Quote it against today's `Type check passed`.

5. **No local narrow was lost.**
   `bin/cosmic --make test cosmic/teal_closure_test.tl` ends
   `test: PASS`, with all four pre-existing tests plus the three new
   ones, and
   ```
   git diff origin/main...HEAD -- cosmic/teal_closure_test.tl | grep -c '^+local function test_'
   ```
   → `3`. Use the THREE-dot form: the two-dot form prints main's forward
   progress on a stale checkout.

6. **The cold-build rule is satisfied, measured not assumed.**
   `bin/cosmic --make test _build/coldbuild_test.tl` ends `test: PASS`.
   The change makes the checker STRICTER and the tree's two globals are
   non-unions that are never narrowed, so generation 1 under the pinned
   checker should still compile the whole tree — but that is the claim
   the gate exists to check, so run it and quote it. If it fails, this
   slice stages behind a release and a pin bump and the item bounces
   rather than the gate being worked around.

7. **The diff is exactly two files.**
   `git diff origin/main...HEAD --name-only` → `3p/tl/tl_patch/closure.tl`
   and `cosmic/teal_closure_test.tl`, nothing else. In particular
   `o/3p/tl/tl.lua` is build output and must not appear.

8. **Nothing outgrew the cap.**
   `wc -l cosmic/teal_closure_test.tl 3p/tl/tl_patch/closure.tl` — each
   ≤ 500 (118 and 179 today).

## Enablement

None needed; every fact the Change rests on is measured above with its
command — the anchor's uniqueness against both pristine and unpacked
bytes, scope 1's identity as `env.globals`, the declaring-scope walk
verified on three probes, and the two-module runtime repro.

Two wrong turns are closed here rather than left to judgment:

- *"use `self.st[1].vars[name] ~= nil`, it is simpler"* — it is, and it
  spuriously widens a local shadowing any stdlib global. The Change
  specifies the walk and the third test pins the difference.
- *"the tree declares no globals, so nothing can regress"* — the tree
  declares two. Neither is exposed, which is why the tests are the only
  evidence; do not read a green `--make ci` as proof the rule works.

The one thing that could still bounce this is Acceptance 6, and the
bounce condition is stated there rather than left for an implementer to
improvise around.
