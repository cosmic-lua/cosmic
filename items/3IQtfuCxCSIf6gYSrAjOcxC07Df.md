## Goal

G3, via the cosmo-contracts container: delete the single largest
degenerate-input union at its source. `path.join`'s `string?` return
produced 26 of the 358 sites in cosmic's nil-flow census; the cosmic
side disposed of it with one licensed assert (cosmic PR #1386), and
this slice makes even that unnecessary by making the C contract exact.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `3c36bc35`.

The two degenerate shapes diverge today (`tool/net/lpath.c`,
`LuaPathJoin`, lines 78–116): calling with zero arguments raises
`luaL_error(L, "missing argument")` (line 114), while calling with
exclusively nil arguments returns nil (`lua_pushnil(L)`, line 110 —
the `gotstr == false` branch). Same caller error, two behaviors, and
the second forces the annotation to `string?` for every caller.

Probed against the built binary:

```text
o//tool/lua/lua -e 'local p = require("cosmo.path")
  print(p.join("a", nil))      -- a
  print(p.join(""))            -- "" (empty string, NOT nil)
  print(p.join(nil))           -- nil        <- the shape this slice removes
  print(pcall(p.join))         -- false  missing argument'
```

The annotation (`tool/net/definitions.lua` lines 1670–1690):
`---@param str string?`, `---@param ... string?`,
`---@return string?` (line 1688), prose lines 1682–1685: "Specifying
no arguments will raise an error. If `nil` arguments are specified,
then they're skipped over. If exclusively `nil` arguments are passed,
then `nil` is returned. ..."

Callers: `grep -rn "path\.join" --include='*.lua' tool/ third_party/`
finds only the annotation itself and the happy-path probe
`tool/lua/test_definitions_conformance.lua:252` — no code in this repo
can observe the change. Downstream, cosmic's sole raw caller is the
`cosmic.fs.path.join` wrapper (its PR #1386), which passes `...:
string` non-nil and asserts the result — behaviorally invisible there.

## Change

1. **`tool/net/lpath.c`** (172 lines): make the all-nil branch raise
   exactly what the zero-arg branch raises. In `LuaPathJoin`, replace
   the `else { lua_pushnil(L); }` arm of the `gotstr` check (line
   108–111) so the function becomes:

   ```c
   if (gotstr) {
     luaL_pushresult(&b);
     return 1;
   }
   luaL_error(L, "missing argument");
   __builtin_unreachable();
   ```

   Interior-nil skipping and empty-string coercion are untouched — the
   loop above the branch does not change.

2. **`tool/net/definitions.lua`**, same commit: line 1688
   `---@return string?` becomes `---@return string`; rewrite the prose
   sentence pair (lines 1682–1685) to: "Specifying no arguments, or
   exclusively `nil` arguments, raises an error. `nil` arguments are
   otherwise skipped over. Empty strings behave similarly to `nil`,
   but unlike `nil` may coerce a trailing slash." `---@param str
   string?` and `---@param ... string?` stay — per-argument nil
   skipping remains part of the contract.

3. **`tool/lua/test_definitions_conformance.lua`** (515 lines), in the
   `=== failure shapes ===` section (line 372): add the raise-shape
   pins beside the existing failure probes:

   ```lua
   assert(not pcall(path.join), "join() must raise")
   assert(not pcall(path.join, nil), "join(nil) must raise")
   assert(not pcall(path.join, nil, nil), "join(nil, nil) must raise")
   assert(path.join("") == "", "join('') stays the empty string")
   assert(path.join("a", nil) == "a", "interior nil still skipped")
   ```

   The happy-path probe at line 252 stays and now verifies a plain
   `string` slot. No slot-observation entry is needed: the binding no
   longer declares an error slot to fill.

## Non-goals

- No other `lpath.c` function moves: `basename`, `dirname`, the
  `CheckPath` family keep their contracts.
- No change to interior-nil skipping or empty-string coercion — the
  probes above pin both.
- No cosmic-side edit and no cosmos pin bump: that is the sibling
  consumption slice, blocked on this one.
- No drive-by edits in `definitions.lua` outside the join block, and
  no reformatting in `lpath.c` — the fork stays surgically mergeable.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0 (binding tests, the
  annotation coverage ratchet, and the conformance probes).
- `o//tool/lua/lua -e 'local p = require("cosmo.path") assert(not pcall(p.join, nil)) assert(not pcall(p.join)) assert(p.join("a","b") == "a/b") assert(p.join("a", nil) == "a")'`
  exits 0.
- `grep -B8 '^function path.join' tool/net/definitions.lua | grep -c '@return string?'`
  reports 0 (today 1).
- `grep -c 'lua_pushnil' tool/net/lpath.c` reports 0 (today 1).

## Enablement

none needed. The container spec carries the doctrine; the sibling
clock_gettime slice also edits `definitions.lua` and the conformance
file at distant anchors (~line 5848 and its own probe lines) — no
ordering constraint, but land whichever merges second via rebase, not
by widening either diff.
