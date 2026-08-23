## Evidence

`literal.format(v, {layout = "compact"})` writes source that
`literal.parse` then REFUSES, for any string — key or value — holding
byte 27 (ESC). One byte, and only that one:

```
compact value bytes broken: 27 (parse: literal:1: a literal has a malformed string value)
compact key   bytes broken: 27
```

Measured on `main` at `83b4fd71` by formatting `{x = string.char(b)}`
and `{[string.char(b)] = 1}` for every b in 0..255 in the compact
layout and reading each back. Found by the literal fuzz properties
(board item 3IKSi0JN) at `FUZZ_ITERS=5000`, seed 1, iteration 327,
property `round_trip`: "parse refused what format wrote: literal:1: a
literal has a malformed string value".

```lua
cosmo.EncodeLua({x = "\27"}, {sorted = true})   -- {x="\e"}
literal.format({x = "\27"})                     -- return {   ["x"] = "\27", }  (pin, reads back)
literal.parse('return {x="\\e"}')               -- nil, "malformed string value"
```

`\e` is a fork extension, not Lua: this runtime's own `load` accepts it
and returns byte 27, so `cosmo.EncodeLua` is self-consistent with the
compiler beside it. `cosmic/literal.tl`'s `ESCAPES` table
(`cosmic/literal.tl:56-58`) has the ten escapes the Lua manual defines
and not this one, so the reader refuses what that writer produced.

This is a hole in the guard PR #1346 added with the compact layout.
That guard's stated promise is that a value the C encoder cannot spell
the way the reader reads comes back in the pin layout instead — it
covers a reserved word as a key and `math.mininteger`, and byte 27 is
the third member of that set, missed because the probe that found the
first two went value-kind by value-kind rather than byte by byte.
Severity is a loud refusal rather than silent corruption, but
`format_file` in the compact layout writes a file `parse_file` cannot
read back, which is the same contract break.

## Change

Two fixes are defensible and the refinement should settle which:

- **(a) the writer turns it down**, which is this item's recommendation:
  `is_compact_scalar` / `is_compact_writable` in
  `cosmic/_literal_format.tl` refuse a string containing byte 27, so
  the value takes the same handoff to the pin layout that a reserved
  key and `math.mininteger` already take. `pin` writes `\27`, which
  reads back everywhere. Keeps what `literal` writes readable by stock
  Lua, which is the point of a pin.
- **(b) the reader accepts it**: add `e = "\27"` to `ESCAPES`. Cheaper,
  and it makes `parse` agree with this runtime's `load` — but it also
  makes a file this module writes depend on a fork extension, so a pin
  would stop being stock-Lua-readable. Recommend against.

## Acceptance

- a test in `cosmic/_literal_format_test.tl` walking all 256 byte
  values through both layouts, as key and as value, asserting each
  round-trips — the loop that found this, kept as a regression test,
  so the next byte the encoder spells its own way is caught by name.
- `bin/cosmic --make ci` ends `ci: PASS`.
- the bound this defect forced on `_fuzz/literal_fuzz_test.tl`'s string
  generator (byte 27 is never drawn) comes off in the same PR, and the
  fuzz file's domain-bounds comment loses that entry.
