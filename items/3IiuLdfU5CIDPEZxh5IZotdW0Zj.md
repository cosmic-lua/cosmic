## Goal

Tighten `cosmo.re`'s contract exactness (G3, cosmo-contracts):
`re.Regex:find` declares slot 2 as `integer|string|nil` — the match's
absolute stop offset on success, the error string on failure, one
slot for two purposes (the `unix.nanosleep`-class deviation).

## Evidence

- C source: `tool/net/lre.c:189-210` (`LuaReRegexFind`), body in
  `LuaReFindImpl` (`lre.c:102-131`); error path is
  `LuaReReturnError` (`lre.c:34-40`).
- `tool/net/definitions.lua:1464-1492`. Slot 2's own doc text:
  "absolute 1-based offset of the last matched character (an error
  string when start is nil)".
- Probe (from the cosmopolitan repo root, against
  `make -j$(nproc) o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:find("xxabxx"))'
  3	4	table: 0x...
  $ o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("zzz"); print(select("#", rx:find("xxabxx")))'
  1
  ```
  (No-match: exactly 1 return value, no slot-2 nil at all. The
  engine-failure branch shares `LuaReReturnError` with `re.compile`'s
  demonstrated `nil, err` path.)
- cosmic-side spend (`grep -n 'regex:find(' cosmic/re.tl` in a
  `cosmic-lua/cosmic` checkout) — `cosmic/re.tl:280` and `:326`, both
  guarding the shared slot:
  ```
  local s, e, caps = regex:find(text, sflags, pos)
  if s == nil then
    if e is string then
      return false, e
    end
    break
  end
  ```

## Change

Redeclare `re.Regex:find`'s return shape so slot 2 does not admit both
an integer offset and a string error simultaneously. This is a
distinct C function (`LuaReRegexFind`) from the `search`/`match`
captures' `LuaReRegexSearch`, so it is not automatically fixed by
their diff — land as its own change, though the shape decision (how
to represent "no error" vs "an error" alongside a success payload)
should match whatever the `re.Regex:search` capture (`3IiuEB99`)
settles on for consistency across `cosmo.re`.

## Non-goals

- No change to the no-match/error reachability itself, only the tuple
  shape.
- No change to `re.compile` (already exact).

## Acceptance

- `definitions.lua`'s `re.Regex:find` annotation declares a slot 2
  that does not admit both an integer and a string type
  simultaneously (or documents, with a coverage-ratchet-visible
  rationale, why it still must).
- The `re`-module coverage/conformance test still passes.
- `cosmic/re.tl`'s `scan_matches`/`find` (lines 270-292, 318-335) can
  drop their `if e is string then` runtime type-sniff for a plain
  narrow — filed as a follow-up on the cosmic side, not part of this
  capture.
