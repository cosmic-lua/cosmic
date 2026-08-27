## Goal

G3 — an honest type layer, no escape hatches. Under the tl-patch gaps
container (3ISJI4Lg): `is` against a table-kinded target stops refusing
a `metatable<T>`-typed value, so the guard-and-cast dance at
`cosmic/fs/types.tl:251-252` (and every future `getmetatable` site)
becomes a plain is-guard.

## Change

Add three entries to the carried tl patch's `narrow-*` group, in
`3p/tl/tl_patch/narrow.tl` (the split landed: PR #1437, main
`5062df8f`; measured 2026-08-27 post-split,
`wc -l < 3p/tl/tl_patch/narrow.tl` → 344, so ~156 lines of headroom
under the 500 cap — these three entries are ~60 lines against it).
All three carry `file = "tl.lua"`; none needs a `-tl-tl` twin, because
this is checker logic, not a stdlib type declaration — the only three
`file = "tl.tl"` entries today
(`grep -rn 'file = "tl.tl"' 3p/tl/tl_patch/` →
`ast_cache.tl:20,126`, `narrow.tl:107`) all edit declared types.

Anchors verified 2026-08-27 (post-split re-check) against the fetched
checker (`bin/cosmic --make fetch`, then `sha256sum o/3p/tl/tl.lua` →
`77a25cb9597956bbe76c68239b8d55c9436dfc2618b55adf5932c0a55fe2e628` —
unchanged by the split, so all line numbers below hold). CAUTION on
uniqueness: the bare line `elseif not self:is_a(f.typ, typ) then`
occurs TWICE in that file (11508 in `not_facts` at 12-space indent,
11606 in `eval_fact` at 15-space indent). The mechanism requires an
exact-once `find`, so entries 2 and 3 MUST anchor the multi-line
blocks quoted below (each block occurs exactly once), never the bare
guard line.

1. `narrow-metatable-helper` — anchor the three lines of
   `local function invalid_from(f) ... end` (`o/3p/tl/tl.lua:11490-11492`,
   occurs once) and append after them, at the same indentation, a
   `table_kinded` lookup table (`map`, `record`, `array`, `interface`
   → true) and a `local function is_table_metatable(self, typ, target)`
   returning true when `table_kinded[target.typename]` holds,
   `self.cache_std_metatable_type` is set, and
   `typ.typename == "nominal" and typ.found ~= nil and
   typ.found.def == self.cache_std_metatable_type`. Both helpers sit in
   the same closure as the two call sites below, so `self` is passed
   explicitly and nothing else moves.

   That equality is the real resolve the sketch lacked:
   `self.cache_std_metatable_type` is assigned at
   `o/3p/tl/tl.lua:15060` from `env.globals["metatable"] and
   (env.globals["metatable"].t).def` (note the `and`: it can be nil,
   which the helper's is-set condition guards), and a probe at the
   fact-eval site printed
   `found.def == self.cache_std_metatable_type` → `true` for a
   `getmetatable(x)` value. No `show_type` string match.

2. `narrow-metatable-not` — in `not_facts`, anchor this exact
   four-line block (`o/3p/tl/tl.lua:11508-11511`, occurs once):

   ```
            elseif not self:is_a(f.typ, typ) then
               assert(f.fact == "is")
               self.errs:add_warning("branch", f.w, f.var .. " (of type %s) can never be a %s", show_type(typ), show_type(f.typ))
               ret[var] = EqFact({ var = var, typ = a_type(f.w, "invalid", {}), w = f.w, no_infer = f.no_infer })
   ```

   (the fenced block reproduces the file's bytes exactly: the
   `elseif` sits at 12 spaces, the body at 15). Replace it with the
   same block whose guard reads
   `elseif not self:is_a(f.typ, typ) and not is_table_metatable(self, typ, f.typ) then`,
   warning and `invalid` EqFact untouched. The negated branch then
   falls through to the existing final `else`, which builds an
   `IsFact` with `subtract_types` — the value keeps its metatable
   type where the guard failed, which is what a runtime
   `type(x) == "table"` test actually tells you.

3. `narrow-metatable-is` — in `eval_fact`, anchor this exact
   three-line block (`o/3p/tl/tl.lua:11606-11608`, occurs once; the
   `elseif` sits at 15 spaces, the body at 18 — the fenced block
   reproduces the file's bytes exactly):

   ```
               elseif not self:is_a(f.typ, typ) then
                  self.errs:add(f.w, f.var .. " (of type %s) can never be a %s", typ, f.typ)
                  return { [f.var] = invalid_from(f) }
   ```

   Replace it with a block that first returns `{ [f.var] = f }` when
   `is_table_metatable(self, typ, f.typ)` holds, and otherwise keeps
   the error-and-invalid path byte-identical — so the positive branch
   narrows to the target instead of to `invalid`.

Then pin the behaviour with two tests in
`cosmic/teal_narrowing_test.tl` (measured 2026-08-27,
`wc -l < cosmic/teal_narrowing_test.tl` → 438, 62 lines under the
cap; the shortest existing test in that file is 18 lines,
`test_mixed_pack_keeps_n_integer`), each written in that file's
existing shape (`fs.write` a source into `TEST_TMPDIR`,
`teal.check_file`, assert on `result.ok`, and call the function on
the line after its `end`):

- `test_metatable_is_table_narrows` — a file where
  `local mt = getmetatable(x)` is guarded by
  `if not (mt is {string: any}) then return false end` and then indexes
  `mt.__index` must check.
- `test_metatable_is_scalar_is_refused` — a file where
  `if mt is integer then` must NOT check.

Both were validated 2026-08-26 against a scratch copy of the fetched
`tl.lua` carrying exactly the three edits above, driven by
`tl.process` under `o/3p/cosmos/lua`: the guarded-index file reported
zero errors and zero warnings (unpatched it reports
`cannot resolve a type for mt here` plus the
`mt (of type metatable<<any type>>) can never be a {string : <any type>}`
branch warning), the positive form `if mt is {string: any} then ... end`
checked as well, and `mt is integer` still reported
`can never be a integer`.

## Non-goals

- Do NOT retire the cast at `cosmic/fs/types.tl:251-252`
  (`local idx = (mt as {string: any}).__index` and its
  `type(mt) ~= "table"` guard). The cold-build rule (AGENTS.md, Build
  System; enforced by `_build/coldbuild_test.tl`) applies: source that
  depends on a new checker rule may only land once a pin carries the
  rule. That retire is its own follow-up after the next pin bump, and
  this slice must not touch `cosmic/fs/types.tl`.
- Do NOT split, reorder, or reformat the files under `3p/tl/tl_patch/`.
  Existing entries stay byte-identical; this slice only adds three
  named entries to `narrow.tl`.
- Do NOT touch `_make/patch.tl` or `_make/fetch.tl`. The mechanism is
  frozen by PR #1424; this slice is data for it.
- Do NOT add a `file = "tl.tl"` twin, and do NOT regenerate
  `_types/tlast_gen` output by hand — the build owns it.
- Do NOT widen the allowance beyond the std `metatable` nominal. A
  nominal that merely resolves to some record must keep failing, and
  `mt is integer` must keep failing.
- Do NOT raise the 500-line file cap or add an exemption for patch
  data; capacity exists (156 lines of headroom in `narrow.tl`).

## Acceptance

Run from the repo root.

- `bin/cosmic --make fetch` ends `fetch: PASS` — the three new edits
  apply exact-once to the freshly unpacked `tl.lua`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic --make test cosmic/teal_narrowing_test.tl` passes, with
  `test_metatable_is_table_narrows` and
  `test_metatable_is_scalar_is_refused` among the cases it names.
- `grep -c '^  \["narrow-metatable' 3p/tl/tl_patch/narrow.tl` → `3`
  (today: 0).
- `wc -l < 3p/tl/tl_patch/narrow.tl` → at most 500.
- `wc -l < cosmic/teal_narrowing_test.tl` → at most 500.
- `o/bin/cosmic --check lint 3p/tl/tl_patch/narrow.tl cosmic/teal_narrowing_test.tl`
  passes.

## Enablement

none needed — both walls fell 2026-08-27: the split landed (3ITo9Inv,
PR #1437, `3p/tl/tl_patch/narrow.tl` exists at 344 lines) and the pin
carries the directory mechanism (3ITpcO21, PR #1434,
`bin/cosmic.pin` → 2026-08-27-6b88a0d). Anchors, the std-metatable
resolve, and both test shapes were validated against the fetched
checker during refinement (re-verified post-split: tl.lua sha
unchanged).
