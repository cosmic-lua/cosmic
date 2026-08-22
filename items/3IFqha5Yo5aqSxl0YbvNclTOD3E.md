## Goal

Serves `3I9mIYjY` (the fuzz driver's budget and `cosmo.cov` contend for
the VM's one debug-hook slot), under the `cosmic.fuzz` epic
`3I1j7yQA`. This is the C half: give the collector's own hook an
optional instruction budget, so a caller that needs one no longer has
to take the slot away from the collector. The cosmic half — the fuzz
driver using it — is the sibling slice and is blocked on this landing
and being pinned.

## Measurement (2026-08-22, whilp/cosmopolitan master `07fc94a1`)

Read from the source, not inferred.

- `tool/net/lcov.c` is **233 lines** (`wc -l tool/net/lcov.c`). The
  hook is `CovHook` (`:91`), armed by `LuaCovStart` (`:129`) as
  `lua_sethook(L, CovHook, LUA_MASKLINE, 0)` and by `LuaCovArm`
  (`:159`) the same way on another thread. `CovHook`'s first statement
  is `if (ar->event != LUA_HOOKLINE) return;`, so a count event is
  already ignored rather than mishandled.
- `kLuaCov[]` (`:219`) holds **6 entries**, alphabetically ordered:
  `arm`, `reset`, `running`, `snapshot`, `start`, `stop`.
- `tool/net/definitions.lua` documents the same six
  (`grep -c '^function cov\.' tool/net/definitions.lua` → **6**),
  under the `### COVERAGE` heading at `:2044`.
- `tool/lua/test_cov.lua` is **150 lines**; `tool/lua/BUILD.mk:145`
  runs it as `o/$(MODE)/tool/lua/test_cov.ok` and `:205` runs the
  annotation ratchet `test_definitions_coverage.ok`, which reads
  `kLuaCov` out of `tool/net/lcov.c` (`test_definitions_coverage.lua:314`)
  and fails on any registered function without an annotation.

Why the caller cannot do this itself: a Lua VM has one debug-hook slot
per thread, `lua_sethook` replaces whatever is there, and
`debug.gethook()` reports a C hook as the uncallable string
`"external hook"` — so Lua can neither call the collector's hook nor
reinstall it. Composition has to come from the side that owns the hook.

## Change

Add one function to `cosmo.cov` and teach `CovHook` the count event.
All of it is in `tool/net/lcov.c`, `tool/net/definitions.lua`, and
`tool/lua/test_cov.lua`.

**`tool/net/lcov.c`.**

- Add a `long budget` field to the existing `g_cov` state struct, 0
  meaning "no budget".
- Add `LuaCovBudget` and register it in `kLuaCov[]` as `{"budget",
  LuaCovBudget}` — first entry, keeping the table's alphabetical order.
  Its contract:

  ```
  // cov.budget(n) -> boolean
  //
  // Arms an instruction budget on the calling thread's collection: the
  // hook raises "cosmo.cov: instruction budget exceeded" once n VM
  // instructions have executed. n nil or 0 clears it. Returns false,
  // changing nothing, when this thread's hook is not the collector's —
  // the caller then falls back to its own debug.sethook budget.
  ```

  Implementation: `luaL_optinteger(L, 1, 0)`; if
  `lua_gethook(L) != CovHook`, push false and return 1. Otherwise store
  the value in `g_cov.budget` and re-arm the calling thread with
  `lua_sethook(L, CovHook, LUA_MASKLINE | (n > 0 ? LUA_MASKCOUNT : 0),
  (int)n)`. Re-arming is what restarts Lua's internal instruction
  counter, which is why each call gives a fresh budget rather than
  continuing the last one. Push true and return 1.
- In `CovHook`, replace the leading
  `if (ar->event != LUA_HOOKLINE) return;` with: on `LUA_HOOKCOUNT`,
  re-arm the thread line-only (`lua_sethook(L, CovHook, LUA_MASKLINE,
  0)`) so the budget is one-shot and does not fire again while the
  error unwinds, clear `g_cov.budget`, then
  `lua_pushliteral(L, "cosmo.cov: instruction budget exceeded")` and
  `lua_error(L)`; on any other non-line event, return as before.
  Counting a line hit is unchanged.
- Extend the file's header comment block (`:25-40`) with a sentence on
  the budget: the collector's hook can carry one so a caller that needs
  an instruction budget does not have to take the slot.

**`tool/net/definitions.lua`.** Add the `cov.budget` annotation beside
the other six, in the same style: a `@param n integer?` (VM
instructions until the hook raises; nil or 0 clears), a
`@return boolean` (false when this thread's hook is not the
collector's), and a line naming the raised string verbatim —
downstream compares it, so it is a frozen value like any other error
string at this boundary.

**`tool/lua/test_cov.lua`.** Add three cases, in the file's existing
plain-`assert` style:

- a budget arms and fires: `cov.start()`, `cov.budget(10000)`, then
  `pcall` a chunk that loops forever; assert the pcall returned false
  and the caught value is exactly
  `"cosmo.cov: instruction budget exceeded"`.
- collection survives it: after that pcall, `cov.running()` is still
  true and `cov.snapshot()` holds hits for the looping chunk — the
  budget is one-shot, not a stop().
- it refuses a foreign slot: with a `debug.sethook` Lua hook installed
  instead of the collector's, `cov.budget(10000)` returns false and
  `debug.gethook()` still reports that foreign hook.

## Non-goals

- **No change to any existing `cosmo.*` return shape, error string, or
  constant.** The six existing `cov` functions keep their signatures
  exactly; this slice is additive. `arm`, `reset`, `running`,
  `snapshot`, `start`, `stop` are not touched.
- No change outside `tool/net/lcov.c`, `tool/net/definitions.lua`, and
  `tool/lua/test_cov.lua`. In particular do not edit
  `tool/lua/test_definitions_coverage.lua` — the ratchet is supposed to
  notice the new function on its own; if it fails, the missing piece is
  the annotation, not the ratchet.
- No line-hook composition API (`cov` accepting a Lua callback, hook
  chaining, a general "compose two hooks" facility). One optional
  budget is what the downstream need is; anything more is a bigger
  contract to freeze.
- No change on the cosmic side and no pin bump: that is the sibling
  slice, and it cannot start until a release carries this.
- Keep the diff surgical and upstream-mergeable — no reformatting of
  `lcov.c` beyond the lines this touches.

## Acceptance

```
make -j$(nproc) o//tool/lua/test
```

- the target builds and every `.ok` under it passes, including
  `o//tool/lua/test_cov.ok` (the three new cases) and
  `o//tool/lua/test_definitions_coverage.ok` (the annotation ratchet
  seeing the new `budget` entry in `kLuaCov[]`).
- the new budget cases fail against master's `tool/net/lcov.c` — same
  test file, `lcov.c` reverted — and that run is shown in the PR
  description.
- `grep -c '^function cov\.' tool/net/definitions.lua` returns **7**
  (6 today).
- `grep -c '{"' tool/net/lcov.c` counts the `kLuaCov[]` entries; it
  returns **7** (6 today).
- `wc -l tool/net/lcov.c` stays under 300.

## Enablement

none needed — the hook, its two arming sites, the registration table
and the annotation block are named by `file:line`; the test file, its
style and the make target that runs it are named; and the one design
decision (a one-shot budget on the collector's own hook, refusing a
foreign slot rather than seizing it) is stated rather than left open.
