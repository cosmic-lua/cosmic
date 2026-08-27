## Goal

`cosmo.DecodeLua` ACCEPTS a raw carriage return inside a short string,
where `load` refuses it. Lua's lexer ends a short string at either line
terminator — `read_string`'s `case '\n': case '\r':` both raise
"unfinished string" — but `ScanShortString` in `tool/net/llua.c` checks
only `ch == '\n'` at the top of its scan, so a lone `\r` is copied into
the string body as byte 13.

This is a FALSE ACCEPT, which is the dangerous direction: cosmic's
`literal.tl` dispatches to the C engine first and falls back to the Teal
lexer only on a REFUSAL, so a wrong acceptance is returned to the caller
rather than corrected. `DecodeLua` then yields a value for source `load`
would never run.

Measured 2026-08-27 against `o//tool/lua/lua` built from
whilp/cosmopolitan `13977f2e` merged with whilp/cosmopolitan#283
(`c9583448`); the divergence is present identically before and after
that PR, so it is pre-existing and not #283's doing:

```
src=return {a = "x\ry"}
  load       -> REFUSED (oracle:1: unfinished string near '"x')
  DecodeLua  -> ACCEPT "x\13y"
```

A CRLF pair is already handled correctly (the `\r` is copied, then the
`\n` ends the string, so the whole literal is refused, as `load` refuses
it) — only a LONE `\r` diverges.

## Change

`tool/net/llua.c`, the top of `ScanShortString`'s scan loop: the raw
line-terminator check `if (ch == '\n')` becomes `if (ch == '\n' || ch ==
'\r')`, so a lone carriage return fails with `kErrString` exactly as a
newline does. The `\z` skip is unaffected — `\r` behind `\z` is
whitespace `load` skips too, and `isspace` already skips it.
`tool/lua/test_llua.lua` pins the refusal and pins that `\z\r` still
skips.

## Non-goals

No long-string change (`ScanLongString` normalizes line endings on
purpose, per whilp/cosmopolitan#284, and that is correct). No other
escape changes. No binding contract shape change — `DecodeLua`'s
signature and error channel stand — so no `definitions.lua` change, no
type regen, no cosmic wrapper fix.

## Acceptance

`make -j$(nproc) o//tool/lua/test` PASS with the added case. A probe
comparing `load` and `cosmo.DecodeLua` on `return {a = "x\ry"}` reports
both REFUSED. `return {a = "x\r\ny"}` stays refused by both, and
`return {a = "x\z\r\n   y"}` stays ACCEPT "xy" under both.

## Enablement

Found by the review of `3IV8zs31` (whilp/cosmopolitan#283) while probing
that fix's boundaries against `load`. The countermeasure that would have
found it earlier is the differential one already in flight: the engine
corpus in cosmic that runs every literal under both engines has no
lone-`\r` case. Adding one is the cheap half of this item.
