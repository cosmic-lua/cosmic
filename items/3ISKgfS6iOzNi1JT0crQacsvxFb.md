## Goal

G3, under the tl-patch gaps container: the smallest of the four
narrowing gaps, closed with a one-line patch entry proven end to end
at refinement (2026-08-26, main `b4ad036b`): the edited checker
type-checks the probe AND the whole tree — `bin/cosmic --make ci` →
`ci: PASS (5 stages)` with the edit in place.

## Evidence

tl's embedded stdlib declares `table.pack` twice (`o/3p/tl/tl.lua`,
lines 384–385 of the stdlib text; identically in `o/3p/tl/tl.tl`):

```
pack: function<T>(T...): PackTable<T> --[[needs_compat]]
pack: function(any...): {any:any} --[[needs_compat]]
```

`PackTable<A> is {A}` carries `n: integer` (lines 371–376). Uniform
arguments resolve the generic overload, so `table.pack(1, 2, 3).n` is
`integer`; MIXED returns (`table.pack(coroutine.resume(t))`) fall to
the second overload's bare `{any:any}`, and `.n` erases to `any` —
probed both ways. That erasure is why `cosmic/coverage/init.tl:133`
carries the tree's one pack-n cast
(`return table.unpack(results, 2, results.n as integer)`, reason
"table.pack's n field is an integer by contract").

The fix, applied to both `o/` copies and validated: the fallback
returns `PackTable<any>` instead of `{any:any}`. `.n` is then
`integer` for every call shape, elements stay `any`, and nothing in
the 529-file tree objects (the one compile error seen mid-validation
was stale `o/` state from a pre-fetch build; a converged rebuild
passed).

Measured now: `grep -c 'pack: function(any...): {any:any}'` reports
exactly 1 in each of `o/3p/tl/tl.lua` and `o/3p/tl/tl.tl` — a unique
anchor. `3p/tl/tl_patch.tl` is 499 lines, 19 entries;
`cosmic/teal_narrowing_test.tl` is 415 lines;
`cosmic/coverage/init.tl` is 369 lines, baseline row `= 6`.

## Change

1. **`3p/tl/tl_patch.tl`**: add one entry to the `narrow-*` group, in
   the existing entry form:

   ```
   ["narrow-pack-n"] = {
     file = "tl.lua",
     note = "table.pack's mixed-arity fallback keeps n: integer",
     find = [=====[      pack: function(any...): {any:any} --[[needs_compat]]]=====],
     replace = [=====[      -- cosmic carried patch: the mixed-arity fallback returns
      -- PackTable<any> so `.n` stays integer whatever the elements
      pack: function(any...): PackTable<any> --[[needs_compat]]]=====],
   }
   ```

   (Copy the indentation from the pinned file byte-exactly — the find
   must match once. Check whether the mechanism also patches `tl.tl`;
   existing entries say `file = "tl.lua"` only, and `_make/patch.tl`
   is the authority.)
2. **`cosmic/coverage/init.tl:131–133`**: the pack-n cast and its
   two-line comment come out — the line returns to
   `return table.unpack(results, 2, results.n)`.
3. **`cosmic/teal_narrowing_test.tl`**: pin the moved boundary with
   one test — a mixed `table.pack(coroutine.resume(t))` whose `.n`
   assigns into a declared `integer` — called after its `end`.
4. **Ratchet**: `bin/cosmic --make run _build/casts.tl --baseline`,
   commit; `cosmic/coverage/init.tl` row `= 6` → `= 5`.

## Non-goals

- The other three gaps (or-fallback shapes, closure carry-through,
  metatable<any>) are the research sibling's.
- No other tl_patch entry moves; no pin bump.
- No behaviour change: the patch edits a TYPE declaration only; the
  compat-generated Lua for pack is untouched (`needs_compat` stays).

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "narrow-pack-n" 3p/tl/tl_patch.tl` reports 1 (today 0).
- `grep -c -- "-- cast:" cosmic/coverage/init.tl` reports 5 (today 6).
- `grep -n '"cosmic/coverage/init.tl"' _build/casts_baseline.tl` shows
  `= 5` (today `= 6`).
- `bin/cosmic --make test cosmic/teal_narrowing_test.tl cosmic/coverage/init_test.tl`
  ends `test: PASS (2 files)`.
- `o/bin/cosmic --make coverage` ends `coverage: PASS` — the resume
  wrapper still instruments.

## Enablement

none needed. The edit was applied to the `o/` copies and the full ci
gate passed during refinement; the only open mechanic (whether the
patch mechanism also applies to `tl.tl`) is answered by reading
`_make/patch.tl` at pull.
