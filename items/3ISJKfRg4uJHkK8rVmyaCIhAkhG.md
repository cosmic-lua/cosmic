## Goal

G3: the last two `from any` casts no other open item claims, closed —
one by fixing our own type generator, one by the standard is-guard.
Both shapes validated at refinement (2026-08-26, main `b4ad036b`):
applied, `bin/cosmic --make ci` → `ci: PASS (5 stages)`,
`bin/cosmic --make test cosmic/teal_test.tl cosmic/surface_test.tl` →
`test: PASS (2 files)`.

## Evidence

- **`cosmic/teal.tl:166`** (`local f = fd as FILE`): tl's own source
  declares `search_module: function(string, boolean): string, FILE,
  {string}` (`o/3p/tl/tl.tl:7434`), but the generated
  `o/_types/types_gen/tl.d.tl:65` reads `string, any, {string}` — the
  erasure is OURS: `_types/gentl.tl`'s `erase()` keeps only the types
  in its `KEEP` set (lines 17–20: string/boolean/integer/number/any/
  nil), and `FILE` — Teal's own builtin io handle type, valid in any
  scope with no declaration needed — is not in it, so it falls to the
  `return "any"` default. Adding `FILE = true` to KEEP regenerates
  the honest signature (verified: the d.tl line becomes
  `string, FILE, {string}` on the next build).
- **`cosmic/surface_test.tl:92`** (`require("cosmic." .. name) as
  {string: any}`): a genuinely dynamic require inside the
  published-surface walk; the is-guard shape every other
  dynamic-require site adopted closes it and upgrades the failure
  message.
- Baseline rows before: the regen at refinement wrote 211 casts in 86
  files with both sites closed (from 213/87-equivalent; re-run at
  pull).

## Change

1. **`_types/gentl.tl:17–20`**: add `FILE = true` to `KEEP`. Nothing
   else in the generator moves; `FILE` needs no NAMED/TO_STRING
   handling because Teal predeclares it globally.
2. **`cosmic/teal.tl:164–167`**: the guard keeps its shape and the
   cast goes:

   ```teal
   if fd ~= nil then
     fd:close()
   end
   ```

3. **`cosmic/surface_test.tl:92`**:

   ```teal
   local mod = require("cosmic." .. name)
   assert(mod is {string: any}, name .. ": module did not yield a table")
   ```

4. **Ratchet**: run exactly
   `bin/cosmic --make run _build/casts.tl --baseline` and commit the
   regenerated `_build/casts_baseline.tl`.

## Non-goals

- No other KEEP/NAMED/TO_STRING changes — the curation stays narrow;
  widening the tl surface is its own decision.
- No tl_patch or pin changes; the generator edit regenerates
  `o/_types/types_gen/tl.d.tl` on any build, nothing committed under
  `o/`.
- The remaining `from any` casts belong to their filed owners
  (overload splits, constant maps, the census's Fetch classification)
  and do not close here.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -n "search_module" o/_types/types_gen/tl.d.tl` shows
  `string, FILE, {string}` (today `string, any, {string}`) — run
  after `bin/cosmic --make build`.
- `grep -c -- "-- cast: .*from any" cosmic/teal.tl cosmic/surface_test.tl`
  prints `0` for both (today `1`, `1`).
- `bin/cosmic --make test cosmic/teal_test.tl cosmic/surface_test.tl`
  ends `test: PASS (2 files)`.
- `git diff --stat origin/main...HEAD` names exactly four files:
  `_types/gentl.tl`, `cosmic/teal.tl`, `cosmic/surface_test.tl`,
  `_build/casts_baseline.tl`.

## Enablement

none needed — validated end to end at refinement, and the generator
regenerates on every build so there is no drift to manage.
