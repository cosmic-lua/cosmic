## Evidence

`literal.parse(literal.format(v))` returns DIFFERENT DATA than `v` —
silently, with no refusal — for any string holding one of the bytes 11
through 31 immediately followed by a digit. The reader also disagrees
with what executing the same source would return, which is the one
thing `cosmic/literal.tl:117-121` says the module exists to make
impossible ("a reader that quietly returns different data is the
failure this exists to make impossible").

Found by the literal fuzz properties (board item 3IKSi0JN) on their
first run, at `_fuzz/driver`'s default seed:

```
round_trip: seed=1 iteration=18
input(base64)=cmV0dXJuIHsKICBbIiJdID0gIiIsCiAgWyJcMVwxIl0gPSBmYWxzZSwKICBbIlwxXDFcMVwwMTEwXDFcMVwxYVwxXDEiXSA9IHRydWUsCn0K
draws=40: parsed value differs from the value formatted
```

Reduced to one value, on `main` at `83b4fd71`:

```lua
local v = {x = "\11" .. "0"}                 -- bytes 11, 48
local text = literal.format(v)               -- return { ["x"] = "\0110", }
local back = literal.parse(text)             -- back.x is bytes 9, 48
```

The writer is right and the reader is wrong. `string.format("%q", ...)`
zero-pads a numeric escape to three digits when a digit follows it, so
byte 11 is written `\011` — and the Lua manual, and this runtime,
read `\ddd` as DECIMAL:

```
load('return "\011"')  -> byte 11
literal.parse of the same source -> byte 9
```

**Exactly the bytes 11..31 break**, each of them for every one of the
ten digits that can follow:

```
bytes that break round trip when followed by "0": 21
11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
byte 11 followed by digit: 0=BAD 1=BAD ... 9=BAD
```

Bytes 0-10 survive because their padded form reads the same either way,
and bytes above 99 need no padding, so their escape has no leading zero.
Byte 13 (a carriage return) is in the broken range, so this is not
confined to exotic input.

## Cause

`cosmic/literal.tl:108`, the `\ddd` branch of `escape_at`:

```teal
local n = tonumber(digits) as integer -- cast: decimal digits are integral
```

`tonumber` is called with NO base, and this fork's Lua accepts C-style
prefixes in that form: `tonumber("011")` is 9, and `tonumber("0b11")`
is 3, where stock Lua gives 11 and nil. A leading zero therefore turns
Lua's decimal string escape into an octal one. With the base given
explicitly, `tonumber("011", 10)` is 11.

The `\x` and `\u{...}` branches (`cosmic/literal.tl:76`, `:100`) both
pass base 16 and are unaffected. The compact layout is unaffected too:
`cosmo.EncodeLua` writes `\xHH`, a fixed two hex digits, which the `\x`
branch reads correctly.

## Not a defect, but worth knowing

`literal.parse("return {a = 010}")` returns 8, and so does
`load("return 010")` in this runtime — the fork's Lua reads a
leading-zero integer as octal in source too. The reader AGREES with the
runtime there, so it is a fork divergence from stock Lua rather than a
contract break, and it is out of this item's scope. Only the string
escape has the writer and the reader disagreeing.

## Change

`cosmic/literal.tl:108`: pass base 10, so the escape is read as the
decimal the Lua manual specifies and `%q` writes.

## Acceptance

- a test in `cosmic/literal_test.tl` asserting the round trip holds for
  every byte 0..255 followed by a digit — the loop that found the
  range, kept as a regression test, so a future `tonumber` without a
  base cannot pass.
- a test asserting `literal.parse` agrees with `load` on `"\011"`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- the bound this defect forced on `_fuzz/literal_fuzz_test.tl`'s string
  generator (a digit is never emitted directly after a byte in 11..31)
  comes OFF in the same PR, and the fuzz file's domain-bounds comment
  loses that entry. The fuzz run at `FUZZ_ITERS=5000` is what shows the
  fix holds over the whole alphabet.
