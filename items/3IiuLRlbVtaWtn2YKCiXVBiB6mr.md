## Goal

Same deviation as `re.Regex:search` (capture `3IiuEB99`) — `re.Regex:match` is
the *same C function* (`LuaReRegexSearch`) under cosmic's
charter-preferred name, and it is the one cosmic actually calls, so
this is the binding whose deviation cosmic pays for today.

## Evidence

- C source: `tool/net/lre.c:225-230` — `kLuaReRegexMeth[]` maps both
  `"search"` and `"match"` to `LuaReRegexSearch`
  (`lre.c:175-187`/`61-93` for the body).
- `tool/net/definitions.lua:1442-1462`.
- Probe (from the cosmopolitan repo root, against
  `make -j$(nproc) o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:match("xxabxx"))'
  ab	table: 0x...
  ```
- cosmic-side spend (`grep -n 'regex:match(' cosmic/re.tl` in a
  `cosmic-lua/cosmic` checkout) — `cosmic/re.tl:188`, with the live
  guard the deviation forces:
  ```
  local m, caps = regex:match(text)
  if not m then
    if caps then
      -- Engine failure: the binding reports nil, err.
      return nil, tostring(caps)
    end
    -- No match is not an error.
    return nil
  end
  ```
  This `if caps then` is a runtime type-sniff standing in for a type
  narrow the binding's declared shape cannot express.

## Change

Same shape fix as the `re.Regex:search` capture (they are the same C
function); land together. Once slot 2 no longer double-duties,
`cosmic/re.tl:184-203` (`match`) can drop the `if caps then` runtime
disambiguation for a plain type narrow.

## Non-goals

Same as the `re.Regex:search` capture (`3IiuEB99`).

## Acceptance

Same as `3IiuEB99`, plus: `cosmic/re.tl`'s `match` function (the
`cosmic.re` module-level convenience, not the binding method) can be
simplified to drop its `if caps then` branch — filed as a follow-up on
the cosmic side once this binding's shape lands, not part of this
capture.
