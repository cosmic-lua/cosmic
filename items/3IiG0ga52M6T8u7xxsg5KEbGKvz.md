## Goal

Decide whether `cosmo.DecodeLua`'s third return slot — a parse byte
offset, not an OS `errno` — should be normalized to the boundary's
canonical `T|nil, err string, errno?` shape, or explicitly documented
as an accepted, distinct variant — part of G3's "the boundary is
exact" inventory (parent: cosmo-contracts container, census item
3IR2TQdUPE14YWg2XOZBljh1iL7, slice "top-level cosmo surface").

## Evidence

- C source: `tool/lua/lcosmo.c:87` (`LuaDecodeLua`):
  ```c
  static int LuaDecodeLua(lua_State *L) {
    ...
    r = DecodeLua(L, p, n, err, sizeof(err));
    if (r.rc == -1) {
      lua_pushnil(L);
      lua_pushstring(L, err);
      lua_pushinteger(L, (lua_Integer)(r.p - p) + 1);
      return 3;
    }
    return 1;
  }
  ```
- `tool/net/definitions.lua:2288-2293`:
  ```
  ---@param input string
  ---@return table<string, any>|nil
  ---@return string? error
  ---@return integer? offset
  ---@nodiscard
  function cosmo.DecodeLua(input) end
  ```
  Slot 3 is a 1-based byte offset into the parsed source, not
  `unix.Errno` — this is not a syscall failure at all, so there is no
  OS errno to report; the archetype's canonical third slot type does
  not apply literally here.
- Probe transcript, from the cosmopolitan repo root against
  `o//tool/lua/lua` built by `make -j$(nproc) o//tool/lua/lua`:
  ```
  $ o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.DecodeLua("return {x=}"))'
  nil	holds literals only	11
  ```
- Cosmic-side spend (`grep -rn 'DecodeLua' cosmic/` in a
  `cosmic-lua/cosmic` checkout): `cosmic/literal.tl:29,276-281`:
  ```teal
  local decode_lua = cosmo.DecodeLua
  ...
  -- A C refusal is discarded, message and byte offset both, and the read
  -- falls through to the lexer for the answer: every refusal is written
  -- once, in the `<file>:<line>: <detail>` shape callers read, at the
  -- cost of reading a refused source twice — the rare path, unmeasured.
  if decode_lua and engine ~= "teal" and (engine == "c" or not on_duplicate) then
    local decoded = decode_lua(source)
    if decoded then
      return decoded
    end
  end
  local lexed, lex_err = lex(source, where)
  ```
  The wrapper's ONLY use of `decode_lua(source)` discards both the
  error string and the offset entirely on refusal, re-parsing with its
  own Teal lexer instead — direct evidence that today's one consumer
  finds the C reader's error/offset channel not worth wiring through
  directly.

## Change

Decide one of:
1. Accept the shape as a deliberate, documented exception (the offset
   is genuinely useful for a caller that DOES want it, and re-deriving
   a line number from a byte offset without an offset would cost every
   caller a full re-scan) — record this in the binding-contract-shape
   rule in `AGENTS.md`; no code change; or
2. Normalize: fold the offset into the error string itself (e.g.
   `"<offset>: <message>"`, parsed by a caller that wants structure) so
   slot 3 is dropped and the tuple returns to 2 slots uniformly with
   the rest of the codec/parse family (`DecodeJson`, `DecodeHex`, etc).

## Non-goals

- No change to `DecodeLua`'s parse grammar or its `literal`-domain
  refusal set.
- No bundling with the `cosmo.Fetch`/`FetchStream` capture (a
  different, arity-level deviation).

## Acceptance

- A decision is recorded (accept-as-exception, or fold-into-message)
  with the binding-contract-shape rule in this repo's `AGENTS.md`
  updated to reflect it.
- If normalized: `definitions.lua` updated in the same commit; a
  matching cosmic-side type regen + wrapper simplification at
  `cosmic/literal.tl:276-281` (the discard-and-relex path might then be
  worth revisiting, but that revisit is this capture's own scope to
  decide, not assumed here) lands as its own PR.
