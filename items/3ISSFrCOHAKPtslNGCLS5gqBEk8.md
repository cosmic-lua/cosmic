## Goal

G3 — an honest type layer, no escape hatches. Under the tl-patch gaps
container (3ISJI4Lg): `is` against a table-kinded target stops refusing
a `metatable<T>`-typed value, so the guard-and-cast dance at
`cosmic/fs/types.tl:251-252` (and every future `getmetatable` site)
becomes a plain is-guard.

## Change

Add three entries to the carried tl patch's `narrow-*` group, in
`3p/tl/tl_patch/narrow.tl` (the file 3ITo9Inv creates by splitting
`3p/tl/tl_patch.tl` at its group seam; that split must land first — see
Enablement). All three carry `file = "tl.lua"`; none needs a `-tl-tl`
twin, because this is checker logic, not a stdlib type declaration —
the only three `file = "tl.tl"` entries today (re-measured after the
split: `grep -c 'file = "tl.tl"' 3p/tl/tl_patch/ast_cache.tl
3p/tl/tl_patch/narrow.tl`) all edit declared types.

Anchors verified 2026-08-27 against the fetched checker at main
`6b88a0db` (`bin/cosmic --make fetch`, then
`sha256sum o/3p/tl/tl.lua` →
`77a25cb9597956bbe76c68239b8d55c9436dfc2618b55adf5932c0a55fe2e628`).
Each of the three `find` strings occurs EXACTLY ONCE in that file,
checked with a literal substring count.

1. `narrow-metatable-helper` — anchor the three lines of
   `local function invalid_from(f) ... end` (`o/3p/tl/tl.lua:11490-11492`)
   and append after them, at the same indentation, a `table_kinded`
   lookup table (`map`, `record`, `array`, `interface` → true) and a
   `local function is_table_metatable(self, typ, target)` returning true
   when `table_kinded[target.typename]` holds, `self.cache_std_metatable_type`
   is set, and `typ.typename == "nominal" and typ.found ~= nil and
   typ.found.def == self.cache_std_metatable_type`. Both helpers sit in
   the same closure as the two call sites below, so `self` is passed
   explicitly and nothing else moves.

   That equality is the real resolve the sketch lacked:
   `self.cache_std_metatable_type` is assigned at
   `o/3p/tl/tl.lua:15060` from `env.globals["metatable"].t.def`, and a
   probe at the fact-eval site printed
   `found.def == self.cache_std_metatable_type` → `true` for a
   `getmetatable(x)` value. No `show_type` string match.

2. `narrow-metatable-not` — in `not_facts`
   (`o/3p/tl/tl.lua:11508-11511`), widen the guard
   `elseif not self:is_a(f.typ, typ) then` to
   `elseif not self:is_a(f.typ, typ) and not is_table_metatable(self, typ, f.typ) then`,
   leaving the warning and the `invalid` EqFact inside it untouched. The
   negated branch then falls through to the existing final `else`, which
   builds an `IsFact` with `subtract_types` — the value keeps its
   metatable type where the guard failed, which is what a runtime
   `type(x) == "table"` test actually tells you.

3. `narrow-metatable-is` — in `eval_fact`
   (`o/3p/tl/tl.lua:11606-11608`), before
   `self.errs:add(f.w, f.var .. " (of type %s) can never be a %s", typ, f.typ)`,
   return `{ [f.var] = f }` when `is_table_metatable(self, typ, f.typ)`
   holds, so the positive branch narrows to the target instead of to
   `invalid`.

Then pin the behaviour with two tests in
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

Both were validated 2026-08-27 against a scratch copy of the fetched
`tl.lua` carrying exactly the three edits above, driven by
`tl.process` under `o/3p/cosmos/lua`: the guarded-index file reported
zero errors and zero warnings (unpatched it reports
`cannot resolve a type for mt here` plus the
`mt (of type metatable<<any type>>) can never be a {string : <any type>}`
branch warning), the positive form `if mt is {string: any} then ... end`
checked as well, and `mt is integer` still reported
`can never be a integer`.

Capacity, re-measured 2026-08-27 at pull (post-split main, PR #1437
merged):

- `wc -l 3p/tl/tl_patch/narrow.tl` → 344 with 15 entries
  (`grep -c '^  \["' 3p/tl/tl_patch/narrow.tl`), so 156 lines of
  headroom under the 500 cap; these three entries are ~60 lines
  against that.
- `wc -l cosmic/teal_narrowing_test.tl` → 438, 62 lines under the cap.
  The two tests must fit inside it; the shortest existing test in that
  file is 18 lines (`test_mixed_pack_keeps_n_integer`, lines 421-438).

## Non-goals

- Do NOT retire the cast at `cosmic/fs/types.tl:251-252`
  (`local idx = (mt as {string: any}).__index` and its
  `type(mt) ~= "table"` guard). The cold-build rule recorded as
  3ISKgfS6 applies: source that depends on a new checker rule may only
  land once a pin carries the rule. That retire is its own follow-up
  after the next pin bump, and this slice must not touch
  `cosmic/fs/types.tl`.
- Do NOT split, reorder, or reformat `3p/tl/tl_patch.tl` or the files
  3ITo9Inv creates from it. Existing entries stay byte-identical; this
  slice only adds three named entries.
- Do NOT touch `_make/patch.tl` or `_make/fetch.tl`. The mechanism is
  frozen by PR #1424; this slice is data for it.
- Do NOT add a `file = "tl.tl"` twin, and do NOT regenerate
  `_types/tlast_gen` output by hand — the build owns it.
- Do NOT widen the allowance beyond the std `metatable` nominal. A
  nominal that merely resolves to some record must keep failing, and
  `mt is integer` must keep failing.
- Do NOT raise the 500-line file cap or add an exemption for patch
  data; capacity comes from 3ITo9Inv's split.

## Acceptance

Run from the repo root.

- `bin/cosmic --make fetch` ends `fetch: PASS` — the three new edits
  apply exact-once to the freshly unpacked `tl.lua`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic --make test cosmic/teal_narrowing_test.tl` passes, with
  `test_metatable_is_table_narrows` and
  `test_metatable_is_scalar_is_refused` among the cases it names.
- `grep -c '^  \["narrow-metatable' 3p/tl/tl_patch/narrow.tl` → `3`.
- `wc -l 3p/tl/tl_patch/narrow.tl` → at most 500.
- `wc -l cosmic/teal_narrowing_test.tl` → at most 500.
- `o/bin/cosmic --check lint 3p/tl/tl_patch/narrow.tl cosmic/teal_narrowing_test.tl`
  passes.

## Enablement

none needed — re-verified at pull, 2026-08-27: 3ITo9Inv's split is
landed (PR #1437), `bin/cosmic.pin` is `2026-08-27-6b88a0d` whose tag
commit carries the directory mechanism, and a fresh
`rm -rf o/3p/tl && bin/cosmic --make fetch` reproduces
`sha256sum o/3p/tl/tl.lua` →
`77a25cb9597956bbe76c68239b8d55c9436dfc2618b55adf5932c0a55fe2e628`,
with all three anchor sites present as described (invalid_from at
o/3p/tl/tl.lua:11490-11492, the not_facts guard at 11508, eval_fact's
can-never-be arm at 11606-11608).
