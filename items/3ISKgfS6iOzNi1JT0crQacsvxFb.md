## Goal

G3, under the tl-patch gaps container: the smallest of the four
narrowing gaps, closed with a one-line patch entry proven end to end
at refinement (2026-08-26, main `b4ad036b`): the edited checker
type-checks the probe AND the whole tree — `bin/cosmic --make ci` →
`ci: PASS (5 stages)` with the edit in place.

## Evidence

Measured 2026-08-26 at main `b4ad036b`, from the repo root.

- tl's embedded stdlib declares `table.pack` twice (`o/3p/tl/tl.lua`,
  lines 384–385 of the stdlib text; identically in `o/3p/tl/tl.tl`):

  ```
  pack: function<T>(T...): PackTable<T> --[[needs_compat]]
  pack: function(any...): {any:any} --[[needs_compat]]
  ```

  `PackTable<A> is {A}` carries `n: integer` (lines 371–376). Uniform
  arguments resolve the generic overload, so `table.pack(1, 2, 3).n`
  is `integer`; MIXED returns (`table.pack(coroutine.resume(t))`)
  fall to the second overload's bare `{any:any}`, and `.n` erases to
  `any` — probed both ways. That erasure is why
  `cosmic/coverage/init.tl:133` carries the tree's one pack-n cast
  (`return table.unpack(results, 2, results.n as integer)`, reason
  "table.pack's n field is an integer by contract").

- **The fix is proven.** Applied to both `o/` copies and validated:
  the fallback returning `PackTable<any>` makes `.n` `integer` for
  every call shape, elements stay `any`, and nothing in the 529-file
  tree objects — a converged rebuild passed the full ci gate.

- **The anchor is unique and its indentation is six spaces.**
  `grep -nF '      pack: function(any...): {any:any} --[[needs_compat]]' o/3p/tl/tl.lua`
  → exactly line 385; `grep -cF 'pack: function(any...): {any:any}'`
  reports 1 in each of `o/3p/tl/tl.lua` and `o/3p/tl/tl.tl`.

- **`tl.lua` alone is the right target — settled.** `_make/patch.tl`
  applies each entry to the file its `file` field names, and entries
  for both exist (`ast-cache-envoptions-tl-tl` carries
  `file = "tl.tl"`). That twin exists because `_types/gentl.tl`
  verifies the `EnvOptions` record against the Teal source
  (`_types/gentl.tl:189`); gentl reads nothing of the Lua-stdlib text
  where `pack` is declared, and the checker the tree runs loads the
  patched `tl.lua`. So this slice patches `tl.lua` only, and `tl.tl`'s
  copy staying upstream is correct, not an oversight.

- **The 500-line cap binds — the file must shed lines first.**
  `wc -l 3p/tl/tl_patch.tl` → **499**, the cap is enforced by
  `file-length` in `_tool/lint.tl:31-44` with only `.d.tl` exempt
  (`_cli/lint.tl:335`), and the entry below is 6 lines. The header
  comment is lines 1–28; the compressed 22-line version below
  preserves every claim and frees 6 lines, landing the file at 499.

- `cosmic/teal_narrowing_test.tl` is 415 lines (85 of headroom);
  `cosmic/coverage/init.tl` is 369 lines, its casts-baseline row
  `= 6` (`_build/casts_baseline.tl:30`). PR #1408 (in `check`) adds a
  trailing comment on `cosmic/coverage/init.tl:129`, three lines
  above this slice's edit — re-measure line numbers at pull if it has
  landed; the edit's shape is unchanged either way.

## Change

1. **`3p/tl/tl_patch.tl`, header**: replace the header comment
   (lines 1–28) with exactly these 22 lines — same content, 6 lines
   freed for the entry:

   ```
   -- The carried patch riding 3p/tl/tl_pin.tl; _make/patch.tl is the
   -- mechanism. Each entry's `note` says what it does; a multi-line
   -- replacement also carries its reasoning at the lines it changes.
   --
   -- The ast-cache-* group (whilp/cosmic#967) lets an embedder skip tl's
   -- parse of its embedded prelude/stdlib d.tl sources — ~11 of the ~16 ms
   -- a fresh process pays in its first tl.new_env(). `ast-cache-hooks-*`
   -- exposes the node/type metatables and the typeid allocator a thawed AST
   -- needs; `ast-cache-new-env` (plus the -tl-tl twin for gentl's ground
   -- truth) accepts pre-parsed programs in EnvOptions, byte-identical when
   -- absent — generated in _types/tlast_gen.tl, thawed in cosmic/_teal_ast.tl.
   --
   -- The narrow-* group teaches the checker that a nil union narrows
   -- through the guards Lua programmers actually write — truthiness,
   -- `assert`, `x and x.field`, `== nil`, exiting branches, disjunctive
   -- guards, `x or fallback` with a non-nil fallback — each strictly
   -- better: more correct programs check, none stop. `narrow-nil-union`
   -- installs the shared helpers; the census is docs/design/nil-flow.md.
   --
   -- Carried, not forked: each anchor must match the pinned source exactly
   -- once, so a tl pin bump that moves this code fails the fetch loudly
   -- until the patch is re-audited (or dropped, once upstream lands it).
   ```

2. **`3p/tl/tl_patch.tl`, entry**: add one 6-line entry to the
   `narrow-*` group (beside `narrow-nil-union` at what is today line
   383), the reasoning carried by `note` since the replacement is a
   one-line type-declaration swap:

   ```
     ["narrow-pack-n"] = {
       file = "tl.lua",
       note = "mixed-arity table.pack fallback returns PackTable<any>: .n stays integer",
       find = [=====[      pack: function(any...): {any:any} --[[needs_compat]]]=====],
       replace = [=====[      pack: function(any...): PackTable<any> --[[needs_compat]]]=====],
     },
   ```

   Copy the six-space indentation inside the brackets byte-exactly —
   the find must match once.

3. **`cosmic/coverage/init.tl:131–133`**: the pack-n cast and its
   two-line comment come out — the line returns to
   `return table.unpack(results, 2, results.n)`. (Keep the other
   comment line, "Packing resume's mixed returns erases the element
   type to any", only if it still reads true; with `.n` typed it does
   not, so both comment lines go.)

4. **`cosmic/teal_narrowing_test.tl`**: pin the moved boundary with
   one test — a mixed `table.pack(coroutine.resume(t))` whose `.n`
   assigns into a declared `integer` — called after its `end`.

5. **Ratchet**: `bin/cosmic --make run _build/casts.tl --baseline`,
   commit; `cosmic/coverage/init.tl` row `= 6` → `= 5`. If any other
   ratchet complains, run exactly the regen command its failure
   message prints and commit the result.

## Non-goals

- The other three gaps (or-fallback shapes, closure carry-through,
  metatable<any>) are the research sibling's (3ISKgwfn).
- No other tl_patch entry moves; no pin bump; no `tl.tl` entry (the
  Evidence settles why).
- No behaviour change: the patch edits a TYPE declaration only; the
  compat-generated Lua for pack is untouched (`needs_compat` stays).
- No header content is dropped — the compression rewords, it does not
  delete claims; the entry-form contract (`find` matches exactly
  once) and `_make/patch.tl` are untouched.

## Acceptance

Run from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "narrow-pack-n" 3p/tl/tl_patch.tl` reports 1 (today 0).
- `wc -l < 3p/tl/tl_patch.tl` prints at most `500` (today 499; 22-line
  header plus 6-line entry lands it at 499).
- `grep -c -- "-- cast:" cosmic/coverage/init.tl` reports 5 (today 6).
- `grep -n '"cosmic/coverage/init.tl"' _build/casts_baseline.tl` shows
  `= 5` (today `= 6`).
- `bin/cosmic --make test cosmic/teal_narrowing_test.tl cosmic/coverage/init_test.tl`
  ends `test: PASS (2 files)`.
- `o/bin/cosmic --make coverage` ends `coverage: PASS` — the resume
  wrapper still instruments.

## Enablement

none needed. The edit was applied to the `o/` copies and the full ci
gate passed during refinement; the two mechanics that were open —
whether the patch also targets `tl.tl` (no: gentl verifies none of the
stdlib text, and the checker loads `tl.lua`) and whether the 500-line
cap admits the entry (no: the file is 499, so the header compression
above is part of the slice, with its replacement text given verbatim)
— are both settled in Evidence with the commands that settled them.
