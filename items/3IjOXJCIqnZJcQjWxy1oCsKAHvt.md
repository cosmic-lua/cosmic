## Goal

Close one exactness gap surfaced by the `re`/`getopt`/`argon2` census
(item YloP_x1CX, sibling of #276/#277 under the cosmo-contracts
container): `getopt.parse`'s `nil, err` failure path is reachable only
by an argument-shape violation of the function's own contract, never by
valid input data or an environmental condition — the `path.join(nil)`
class this repo's own contract convention treats as a raise candidate
(`luaL_argerror`/`luaL_error` at the point the shape is detected), not
a fallible tuple. This is a DIFFERENT fix family from the four `re.*`
tuple-deviation siblings filed alongside it: a C-code change to
`lgetopt.c`, not a `definitions.lua`-only annotation fix.

## Evidence

**C source**: `tool/net/lgetopt.c:59-251` (`LuaGetoptParse`). Its
`FAIL` macro (`lgetopt.c:30-36`):

```c
// Push `nil, <message>` and return 2 from the calling C function.
#define FAIL(...)                     \
  do {                                \
    lua_pushnil(L);                   \
    lua_pushfstring(L, __VA_ARGS__);  \
    return 2;                         \
  } while (0)
```

All 11 call sites (`lgetopt.c:71,73,75,81,86,93,96,100,102,106,115`),
each rejecting an argument-shape violation:

| line | message |
|---|---|
| 71 | `args must be a table` |
| 73 | `optstring must be a string` |
| 75 | `longopts must be a table` |
| 81 | `args table too large (max %d)` |
| 86 | `longopts table too large (max %d)` |
| 93 | `longopt[%d] must be a table` |
| 96 | `longopt[%d][1] (name) must be a string` |
| 100 | `longopt[%d][2] (has_arg) must be a string` |
| 102 | `longopt[%d][2] must be 'none', 'required', or 'optional'` |
| 106 | `longopt[%d][3] (short) must be a string or nil` |
| 115 | `args[%d] must be a string` |

Every message names a TYPE or SHAPE violation of an argument (wrong
Lua type, wrong table shape, an out-of-range size, a bad enum string)
— none is a value a correct caller could plausibly hold as live input
data or an environmental condition (there is no ENOENT/EINTR-shaped
row in this list). `getopt_long()` itself is called only after all 11
checks pass; its own runtime outcomes (unknown option, missing
argument) are reported through the SUCCESS path's
`result.unknown`/`result.missing` fields, never through this nil slot
— confirmed by reading `LuaGetoptParse`'s body past line 115, where the
function commits to always returning a populated result table once
argument validation clears.

**`tool/net/definitions.lua:1601-1634`** (current, at
`cosmic-lua/cosmopolitan` master `fd0884d9` — re-confirm line numbers
before editing):

```
---@param args string[] Command-line arguments (typically `arg`)
---@param optstring string Short options string (e.g., "hvo:")
---@param longopts? table[] Long option definitions: {{name, has_arg, short}, ...}
---@return getopt.Result|nil result
---@return string? error
function getopt.parse(args, optstring, longopts) end
```

The declared shape does not distinguish "this can fail on bad input
data" from "this can only fail on a malformed call" — after this
capture's fix, a correct caller passing well-typed arguments (a
`string[]`, a `string`, and `nil` or a well-formed `table[]`) can no
longer observe a `nil` first return at all, and the annotation should
say so.

**Probe** (from the cosmopolitan repo root, against
`o//tool/lua/lua` built via `make -j$(nproc) o//tool/lua/lua`):

```
$ o//tool/lua/lua -e 'local getopt=require("cosmo.getopt"); print(getopt.parse("not-a-table", "h"))'
```

(from YloP_x1CX's own transcript, demonstrating the current `nil, err`
return for a type-shape violation; re-run and paste fresh output when
picking this up, and also capture the POST-fix behavior — the same
call should raise a Lua error instead.)

**Cosmic-side spend**: `cosmic/flags/getopt.tl:89-95`
(function `parse`) and `cosmic/flags/parse.tl:117-120` both
defensively guard the fallible return:

```
-- cosmic/flags/getopt.tl
local function parse(args: {string}, optstring: string, longopts?: {LongOpt}): Result | nil, string
  local raw_longopts = to_raw_longopts(longopts)
  local res, err = cosmo_getopt.parse(args, optstring, raw_longopts)
  if not res then
    return nil, err
  end
  return res
end
```

```
-- cosmic/flags/parse.tl
local r0, gerr = getopt.parse(argv, optstring, longopts)
if not r0 then
  return nil, tostring(gerr)
end
```

By construction, cosmic's own call sites always pass a typed
`LongOpt` record list and an `args` value that is always `{string}`
(sourced from `proc`) — so this guarded branch is UNREACHABLE from
cosmic's own code today, the archetypal raise-candidate shape: a
defensive check standing guard over a condition a correct caller
cannot actually trigger.

## Change

This is a C-code change, NOT a docs-only fix (unlike its four `re.*`
sibling captures) — it is not blocked on `0YFj_out2` and can proceed
independently, since it belongs to fix class 1 (degenerate-input-only
→ raise candidate), not class 2 (tuple deviation).

1. In `tool/net/lgetopt.c`, convert each of the 11 `FAIL(...)` sites
   (lines 71, 73, 75, 81, 86, 93, 96, 100, 102, 106, 115 at
   `fd0884d9` — re-verify current line numbers before editing, since
   this file has not been touched by this census effort and may have
   drifted) from the `FAIL` macro (push `nil, msg`, return 2) to a
   raise: `luaL_argerror(L, <arg index>, "<message>")` or
   `luaL_error(L, "<message>")`, matching this repo's own contract
   convention for argument-shape violations (see this repo's own
   `AGENTS.md`, and the already-settled `path.join` precedent, #276).
   Pick `luaL_argerror` with the correct 1-based argument index where
   the violation names a specific parameter (most of the 11 do:
   `args` is argument 1, `optstring` argument 2, `longopts` argument
   3, and the per-entry longopt checks should still cite argument 3);
   fall back to `luaL_error` only where no single argument index
   applies.
2. Decide whether the `FAIL` macro itself should be removed (if
   `getopt.parse` was its only caller — check with
   `grep -rn 'FAIL(' tool/net/lgetopt.c`) or left in place for future
   use; state which, and why, in this item's own record.
3. Update `tool/net/definitions.lua`'s `getopt.parse` annotation
   (current lines 1628-1634, re-verify before editing) to drop the
   `nil, string? error` failure tuple entirely — after this fix, a
   well-typed call always returns a populated `getopt.Result`, so the
   honest signature is `@return getopt.Result result` with no nil
   admitted, per this repo's own AGENTS.md contract-shape rule ("when
   slot 1 of a declared return admits nil, slot 2 is the error — an
   annotation that deviates is a bug, and a contract change to conform
   is made deliberately, definitions.lua same commit").
4. Run `make -j$(nproc) o//tool/lua/test` and confirm it passes; add or
   extend a test exercising at least one of the 11 raise sites (e.g.
   the `args must be a table` and `longopts table too large` cases) to
   assert it now raises rather than returning `nil, err`.
5. Re-run the probe above; it should now raise a Lua error instead of
   printing `nil\t<message>`. Paste the new output.
6. Leave a note on this item naming `cosmic/flags/getopt.tl:89-95` and
   `cosmic/flags/parse.tl:117-120` as cosmic-side sites a follow-up item
   (filed separately, in the `cosmic-lua/cosmic` repo) can simplify
   once the binding can no longer return `nil` for these inputs — do
   not make that edit here, since it is a different repo, and cosmic's
   own guards are currently harmless dead code, not broken behavior.

## Non-goals

- No change to any `re.*` binding — those are the four sibling
  captures filed alongside this one, a different fix family (tuple
  deviation, not raise-candidate), each blocked on `0YFj_out2`
  independently of this item.
- No change to `re.compile` or `argon2.hash_encoded` — census-verified
  tuple-exact, out of scope.
- Does not change `getopt_long()`'s own runtime outcome reporting
  (`result.unknown`/`result.missing`) — those already report through
  the success path and are untouched by this fix.
- No edit to `cosmic/flags/getopt.tl` or `cosmic/flags/parse.tl` in
  this item — that is `cosmic-lua/cosmic`, a different repo; note the
  follow-up, don't make it here.

## Acceptance

- All 11 `FAIL(...)` sites in `lgetopt.c` raise a Lua error
  (`luaL_argerror`/`luaL_error`) instead of returning `nil, err`.
- `getopt.parse`'s `definitions.lua` annotation no longer admits `nil`
  in its first return slot for a well-typed call, and states the
  raise behavior in prose.
- The probe above, re-run against the rebuilt binary, now raises
  instead of returning a fallible tuple — pasted with its actual
  output.
- `make -j$(nproc) o//tool/lua/test` passes, including a new or
  extended test exercising at least one raise site.
