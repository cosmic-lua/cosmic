## Goal

Tighten `cosmo.re`'s contract exactness (G3, cosmo-contracts): `re.Regex:search`'s
declared slot 2 (`{string}|string|nil`) does double duty as both the
success payload (parenthesized capture groups) and the failure
message, the same shape as the settled `unix.nanosleep` deviation
(`integer|string remnanos`). A caller cannot narrow slot 2 by type
alone; today it also carries the "no-match" case as an *absent* value
(bare 1-return `nil`), so there are three outcomes sharing two slots.

## Evidence

- C source: `tool/net/lre.c:175-187` (`LuaReRegexSearch`), body in
  `LuaReSearchImpl` (`lre.c:61-93`); the error path is
  `LuaReReturnError` (`lre.c:34-40`).
- `tool/net/definitions.lua:1415-1440`. Slot 2's own doc text: "The C
  pushes at most two values: `(match, captures)`, a bare `nil` for a
  no-match, or `(nil, err)`."
- Probe (from the cosmopolitan repo root, against
  `make -j$(nproc) o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:search("xxabxx"))'
  ab	table: 0x...
  $ o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("xyz"); print(select("#", rx:search("abc")))'
  1
  ```
  (The no-match case returns exactly 1 value — no slot-2 `nil` at
  all. The engine-failure branch, `nil, err:string`, shares
  `LuaReReturnError` with `re.compile`'s error path, demonstrated
  live on that binding's own row: `re.compile("[invalid")` →
  `nil, "Missing ']'"`.)
- cosmic-side spend (`grep -rn ':search(' cosmic/` in a
  `cosmic-lua/cosmic` checkout): zero hits. `cosmic/re.tl`'s own
  comment (mirroring `definitions.lua:1442-1446`) says `:match` is
  "the charter spelling (match IS search)" and cosmic calls only
  `:match` — see the sibling capture on `re.Regex:match`, which
  documents the live guard cosmic needs for this exact deviation.

## Change

Redeclare `re.Regex:search`'s return shape so no slot serves two
purposes — e.g. split into an explicit outcome type/record, or move
the error string off slot 2 (mirroring whatever shape
`unix.nanosleep`'s companion capture settles on for its own
deviation). Update `definitions.lua`'s annotation and the C-side
comment together; a shape change here is a `LuaReSearchImpl` change,
so it also touches `re.Regex:match` and `re.search` — a single diff
is likely to resolve all three plus `re.Regex:find`'s analogous
capture, but each is filed separately per this census's
one-capture-per-binding rule; do not let filing granularity imply
four independent fixes are required.

## Non-goals

- No change to the no-match/error reachability itself, only the tuple
  shape.
- No change to `re.compile` (already exact) or `getopt.parse`/
  `argon2.hash_encoded` (separate captures/rows).
- Coordinate with the sibling `re.Regex:match` and `re.search`
  captures before landing — same C function, same annotation block
  family.

## Acceptance

- `definitions.lua`'s `re.Regex:search` annotation declares a slot 2
  that does not admit both a success-payload type and a string error
  type simultaneously (or documents, with a coverage-ratchet-visible
  rationale, why it still must).
- The `re`-module coverage/conformance test still passes.
- A downstream cosmic wrapper touching this binding needs no
  `if caps then ... else ... end`-style runtime type-sniff to
  distinguish outcomes — a plain narrow suffices.
