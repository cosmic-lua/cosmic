## Goal

G3 — an honest type layer, no escape hatches. Under the tl-patch gaps
container (3ISJI4Lg): `is` against a table-kinded target stops refusing
a `metatable<T>`-typed value, so the guard-and-cast dance at
`cosmic/fs/types.tl:247-252` (and every future `getmetatable` site)
becomes a plain is-guard.

## Change

Add three entries to the carried tl patch's `narrow-*` group, in
`3p/tl/tl_patch/narrow.tl` (the file 3ITo9Inv created by splitting
`3p/tl/tl_patch.tl` at its group seam; landed as #1437, main
`5062df8f`). All three carry `file = "tl.lua"`; none needs a `-tl-tl`
twin, because this is checker logic, not a stdlib type declaration —
the only three `file = "tl.tl"` entries today
(`grep -rn 'file = "tl.tl"' 3p/tl/tl_patch/` → `ast_cache.tl:20`,
`ast_cache.tl:126`, `narrow.tl:107`) all edit declared types.

Anchors re-verified 2026-08-27 at main `5062df8f` against the fetched
checker (`bin/cosmic --make fetch`, then `sha256sum o/3p/tl/tl.lua` →
`77a25cb9597956bbe76c68239b8d55c9436dfc2618b55adf5932c0a55fe2e628`).
That digest is BYTE-IDENTICAL to the one this spec was first written
against, so the entry-level validation recorded below still binds
after the split.

**Every `find` is the multi-line block quoted below, verbatim including
its leading indentation** — the fenced blocks are flush-left in this
file and their first characters are the file's own leading spaces (6,
12 and 15 respectively). `_make/patch.tl`'s `count` is a plain
substring scan (`string.find(..., true)`, `_make/patch.tl:176-180`)
with no line anchoring, and it refuses anything but exactly one match
(`_make/patch.tl:221-225`). A single-line anchor is NOT safe here: the
one line `elseif not self:is_a(f.typ, typ) then` at 12-space indent
counts TWICE in `o/3p/tl/tl.lua`, because the deeper site at 15-space
indent contains it as a suffix. Each of the three blocks below counts
exactly once, measured 2026-08-27 with a literal substring count over
that file.

**Entry 1 — `narrow-metatable-helper`.** `find` is the three lines of
`invalid_from` (`o/3p/tl/tl.lua:11490-11492`):

```
      local function invalid_from(f)
         return IsFact({ fact = "is", var = f.var, typ = a_type(f.w, "invalid", {}), w = f.w })
      end
```

`replace` is that block followed, at the same 6-space indentation, by a
`table_kinded` lookup table (`map`, `record`, `array`, `interface` →
true) and a `local function is_table_metatable(self, typ, target)`
returning true when `table_kinded[target.typename]` holds,
`self.cache_std_metatable_type` is set, and
`typ.typename == "nominal" and typ.found ~= nil and typ.found.def ==
self.cache_std_metatable_type`. Both helpers sit in the same closure as
the two call sites below, so `self` is passed explicitly and nothing
else moves.

That equality is the real resolve the sketch lacked:
`self.cache_std_metatable_type` is assigned at `o/3p/tl/tl.lua:15060`
from `env.globals["metatable"] and (env.globals["metatable"].t).def`,
and a probe at the fact-eval site printed
`found.def == self.cache_std_metatable_type` → `true` for a
`getmetatable(x)` value. No `show_type` string match.

**Entry 2 — `narrow-metatable-not`.** `find` is the four lines of the
`not_facts` guard (`o/3p/tl/tl.lua:11508-11511`):

```
            elseif not self:is_a(f.typ, typ) then
               assert(f.fact == "is")
               self.errs:add_warning("branch", f.w, f.var .. " (of type %s) can never be a %s", show_type(typ), show_type(f.typ))
               ret[var] = EqFact({ var = var, typ = a_type(f.w, "invalid", {}), w = f.w, no_infer = f.no_infer })
```

`replace` is the same four lines with only the `elseif` condition
widened to
`elseif not self:is_a(f.typ, typ) and not is_table_metatable(self, typ, f.typ) then`
— the warning and the `invalid` EqFact inside it stay byte-identical.
The negated branch then falls through to the existing final `else`,
which builds an `IsFact` with `subtract_types`: the value keeps its
metatable type where the guard failed, which is what a runtime
`type(x) == "table"` test actually tells you.

**Entry 3 — `narrow-metatable-is`.** `find` is the three lines of the
`eval_fact` refusal (`o/3p/tl/tl.lua:11606-11608`):

```
               elseif not self:is_a(f.typ, typ) then
                  self.errs:add(f.w, f.var .. " (of type %s) can never be a %s", typ, f.typ)
                  return { [f.var] = invalid_from(f) }
```

`replace` keeps the `elseif` line, then returns `{ [f.var] = f }` when
`is_table_metatable(self, typ, f.typ)` holds, and otherwise falls
through to the untouched `self.errs:add(...)` and
`return { [f.var] = invalid_from(f) }` — so the positive branch narrows
to the target instead of to `invalid`.

**Then pin the behaviour** with two tests in
`cosmic/teal_narrowing_test.tl`, each written in that file's existing
shape (`fs.write` a source into `TEST_TMPDIR`, `teal.check_file`,
assert on `result.ok`, and call the function on the line after its
`end`):

- `test_metatable_is_table_narrows` — a file where
  `local mt = getmetatable(x)` is guarded by
  `if not (mt is {string: any}) then return false end` and then indexes
  `mt.__index` must check.
- `test_metatable_is_scalar_is_refused` — a file where
  `if mt is integer then` must NOT check.

Both were validated against a scratch copy of the fetched `tl.lua`
carrying exactly the three edits above, driven by `tl.process` under
`o/3p/cosmos/lua`: the guarded-index file reported zero errors and zero
warnings (unpatched it reports `cannot resolve a type for mt here` plus
the
`mt (of type metatable<<any type>>) can never be a {string : <any type>}`
branch warning), the positive form `if mt is {string: any} then ... end`
checked as well, and `mt is integer` still reported
`can never be a integer`. That validation was run against the same
`77a25cb9…` checker digest measured above.

Capacity, re-measured 2026-08-27 at main `5062df8f`:

- `wc -l 3p/tl/tl_patch/narrow.tl` → 344, so 156 lines under the
  500-line cap. `grep -c '^  \["' 3p/tl/tl_patch/narrow.tl` → 15
  entries today. These three entries are ~60 lines against that
  headroom.
- `wc -l cosmic/teal_narrowing_test.tl` → 438, 62 lines under the cap.
  The two tests must fit inside it; the shortest existing test in that
  file is 18 lines (`test_mixed_pack_keeps_n_integer`, lines 421-438).

## Non-goals

- Do NOT retire the cast at `cosmic/fs/types.tl:247-252`
  (`local idx = (mt as {string: any}).__index` and its
  `type(mt) ~= "table"` guard). The cold-build rule recorded as
  3ISKgfS6 applies: source that depends on a new checker rule may only
  land once a pin carries the rule. That retire is its own follow-up
  after the next pin bump, and this slice must not touch
  `cosmic/fs/types.tl`.
- Do NOT split, reorder, or reformat `3p/tl/tl_patch/narrow.tl` or
  `3p/tl/tl_patch/ast_cache.tl`. Existing entries stay byte-identical;
  this slice only adds three named entries.
- Do NOT touch `_make/patch.tl` or `_make/fetch.tl`. The mechanism is
  frozen by PR #1424; this slice is data for it.
- Do NOT add a `file = "tl.tl"` twin, and do NOT regenerate
  `_types/tlast_gen` output by hand — the build owns it.
- Do NOT widen the allowance beyond the std `metatable` nominal. A
  nominal that merely resolves to some record must keep failing, and
  `mt is integer` must keep failing.
- Do NOT raise the 500-line file cap or add an exemption for patch
  data; capacity comes from 3ITo9Inv's landed split.

## Acceptance

Run from the repo root.

- `bin/cosmic --make fetch` ends `fetch: PASS` — the three new edits
  apply exact-once to the freshly unpacked `tl.lua`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic --make test cosmic/teal_narrowing_test.tl` passes, with
  `test_metatable_is_table_narrows` and
  `test_metatable_is_scalar_is_refused` among the cases it names.
- `grep -c '^  \["narrow-metatable' 3p/tl/tl_patch/narrow.tl` → `3`
  (it is `0` today).
- `wc -l 3p/tl/tl_patch/narrow.tl` → at most 500 (344 today).
- `wc -l cosmic/teal_narrowing_test.tl` → at most 500 (438 today).
- `o/bin/cosmic --check lint 3p/tl/tl_patch/narrow.tl cosmic/teal_narrowing_test.tl`
  passes.

## Enablement

none needed — both blockers have landed. `3p/tl/tl_patch/narrow.tl`
exists (3ITo9Inv, #1437, main `5062df8f`), so the entries have a file
to go in, and the pinned bootstrap reads a `<stem>_patch/` directory:
`bin/cosmic.pin` is `2026-08-27-6b88a0d` (3ITpcO21, #1434) and
`git merge-base --is-ancestor 6b88a0db c9ecd10b` succeeds for that
release's tag commit — confirmed directly by
`o/bootstrap/cosmic -e 'print(require("_make.patch").paths_of_pin)'`
returning a function, the #1424 mechanism.

The cold-build rule does not bite here. This slice adds checker RULES
but no source that depends on them: the two new tests write their
subject source into `TEST_TMPDIR` and run `teal.check_file` on it at
run time, so generation 1 still type-checks
`cosmic/teal_narrowing_test.tl` itself under the pinned checker. That
is the whole reason `cosmic/fs/types.tl` is walled off in Non-goals —
retiring its cast is the part that must wait for the next pin bump.
