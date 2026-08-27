## Goal
G3 — an honest type layer, no escape hatches (parent `3HyRcW05`). The
carried patch entry `closure-assigned-scan`
(`3p/tl/tl_patch/closure.tl:33-63`) closed a real soundness hole in the
scan that decides whether a narrow may cross a closure boundary. Three
of the four source shapes it fixed are pinned by no test, so a re-port
after a tl pin bump could silently reintroduce the hole.

## Change
Add three tests to `cosmic/teal_closure_test.tl`, using the file's
existing `checks(name, src): boolean, string` helper and the existing
call-after-define convention. Measured now: `wc -l <
cosmic/teal_closure_test.tl` is 175 (325 lines of headroom under the
500-line cap) and `grep -c '^local function test_'
cosmic/teal_closure_test.tl` is 7.

Each test asserts that an assignment sitting in the named position DOES
widen the narrow at a closure boundary — i.e. that the scan sees it.
Each also asserts the error message, so the test cannot pass on an
unrelated failure: the message under the tree checker is exactly
`in return value: got string | integer, expected string` (measured
2026-08-27 with `o/bin/cosmic --check types` on each source below).
Assert with the existing pattern —
`assert(not ok, "...")` plus `assert(msgs:find("in return value: got string | integer, expected string", 1, true), msgs)`
(the `, 1, true` is required by the `find-needle` lint).

The three sources, verbatim, each as the `src` argument:

1. `test_an_assignment_in_an_else_block_widens_at_the_boundary`, file
   name `closure_widen_else.tl`:

```
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local function use(): string
  return v
end
if os.time() > 0 then
  print(1)
else
  v = pick()
end
print(use())
```

2. `test_an_assignment_in_a_stepless_fornum_body_widens_at_the_boundary`,
   file name `closure_widen_fornum.tl`:

```
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local function use(): string
  return v
end
for _i = 1, 3 do
  v = pick()
end
print(use())
```

3. `test_an_assignment_in_an_assignment_rvalue_widens_at_the_boundary`,
   file name `closure_widen_rvalue.tl`:

```
local function pick(): string | integer
  return "x"
end
local v = pick()
if not (v is string) then return end
local function use(): string
  return v
end
local z: integer = 0
z = (function(): integer
  v = pick()
  return 1
end)()
print(use(), z)
```

Give each test a comment naming why its shape is distinct, from the
node walkers in the derived file: `assignment`, `local_declaration` and
`global_declaration` all walk through `walk_vars_exps`
(`o/3p/tl/tl.lua:5143-5152`), which writes `xs[1]` from `vars`, leaves
`xs[2]` unset when there is no `decltuple` — an assignment statement
never has one — and writes the rvalue expressions into `xs[3]`; an
`else` block and a stepless `fornum` leave the same kind of hole ahead
of the body. The pre-fix `ipairs` aggregate stopped at the first hole,
so the subtree carrying the assignment was invisible to the scan and
the narrow wrongly survived into the closure.

Each shape was probe-verified to DISTINGUISH the fix, on 2026-08-27:
reversing only the `closure-assigned-scan` entry's `replace` back to its
`find` in a scratch copy of `o/3p/tl/tl.lua` and type-checking each
source under `o/3p/cosmos/lua` yields a clean check (the unsound
outcome) for all three, while the tree's `o/3p/tl/tl.lua` reports the
error above. The shape already pinned by
`test_an_assignment_anywhere_widens_at_the_boundary` — a plain
top-level `v = pick()` — errors under BOTH, which is why it does not
guard this entry.

## Non-goals
Tests only. Do not edit `3p/tl/tl_patch/closure.tl`,
`3p/tl/tl_patch/narrow.tl`, `3p/tl/tl_patch/ast_cache.tl` or
`_make/patch.tl` — no patch DATA changes here, so no `--make fetch`
step and no re-derivation of `o/3p/tl/tl.lua` is in scope. Do not
correct the `note` field or the in-`replace` comment of
`closure-assigned-scan`, even though "declaration rvalues" names a
shape less precisely than the assignment-statement rvalue probed above:
touching them is a patch-data change.

Do not touch `cosmic/teal_narrowing_test.tl` (401/500) or
`cosmic/teal_test.tl` (493/500), and do not change the `checks` helper's
signature or the file's header doc comment beyond what a new test needs.

Do not widen into the adjacent live items: `3IVQJa0b` (the closure rule
also fires at LOOP sites, undescribed and unpinned) — add no loop-site
test here; `3IVSDpFq` (the metatable is-dispatch rescue is inline-only);
`3IVL4phw` / PR #1468 (trimming `table_kinded` in `narrow.tl`).

Do not add a memoization or any other change to `assigned_anywhere`, and
do not restructure the scan: those are `3IVZsiwL`'s subject.

Do not convert this file to runner mode — the runner-mode migration is
its own batch of items (`3IU6AsZC` and siblings).

## Acceptance
- `bin/cosmic --make test cosmic/teal_closure_test.tl` ends
  `test: PASS (1 file)` and prints
  `✓ cosmic/teal_closure_test.tl (10 test functions)` — 7 today, by
  `bin/cosmic --make test cosmic/teal_closure_test.tl` on `origin/main`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/coldbuild_test.tl` passes: the new code
  is ordinary Teal calling an existing helper, so generation 1's pinned
  checker must accept it unchanged.
- `grep -c '^local function test_' cosmic/teal_closure_test.tl` prints
  `10` (7 today) and `grep -c '^test_' cosmic/teal_closure_test.tl`
  prints `10` — the call-after-define convention.
- `wc -l < cosmic/teal_closure_test.tl` prints a number `<= 500`
  (175 today).
- `git diff origin/main...HEAD --name-only` prints exactly
  `cosmic/teal_closure_test.tl` and nothing else. Use the THREE-dot
  form; the two-dot form reports unrelated files and is a known
  recurring defect (`3IVHIoAx`).

## Enablement
none needed, and no pin bump is staged ahead of this.

The cold-build rule binds any change a generation-1 build must compile
with the PINNED checker. This diff adds no new narrowing requirement:
the added Teal is three `local function` definitions calling the file's
existing `checks` helper with a long-bracket string, and the shapes
under test live INSIDE those strings, checked at test time by the tree's
own checker. Measured 2026-08-27: `o/bootstrap/cosmic --check types` and
`o/bin/cosmic --check types` return the identical error, at the identical
position, on all three sources above — the pinned release
(`bin/cosmic.pin`, `2026-08-27-555873e`) already carries the
`closure-assigned-scan` entry — so neither the compile nor the assertions
depend on a checker the pin lacks.

The conventions this diff can trip are already gated: `find-needle` on
the `msgs:find(...)` calls, the call-after-define lint on the new
`test_*` functions, and the 500-line cap — each named as an Acceptance
command above.
