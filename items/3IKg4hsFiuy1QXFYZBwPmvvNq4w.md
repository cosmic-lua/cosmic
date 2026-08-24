## Goal

G5 — adversarial verification (this item's parent is the G5
container). A fuzz property found a silent round-trip break in
`cosmic.literal`; fixing it at the reader and retiring the bound the
property had to carry is what turns the finding into a regression test
rather than a permanent workaround.

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

Re-measured on `main` at `489bba2f` on 2026-08-24, against a binary
built from the tree (`bin/cosmic --make fetch && bin/cosmic --make
build`). Write this to a scratch file OUTSIDE the repo and run it with
`o/bin/cosmic <file>` — a bare script run against a tree-built binary
resolves `cosmic.literal` from what that binary embeds, which is the
tree; running the same file under the PINNED `bin/cosmic` reads the
release's older `literal` instead and reports only byte 27, a
different defect (3IKgKs34):

```lua
local literal = require("cosmic.literal")
local bad = {}
for b = 0, 255 do
  local v = {x = string.char(b) .. "0"}
  local back = literal.parse(literal.format(v))
  if type(back) ~= "table" or back.x ~= v.x then bad[#bad + 1] = b end
end
print("break: " .. #bad .. " [" .. table.concat(bad, ",") .. "]")
print("load=" .. load('return "\011"')():byte()
  .. " parse=" .. literal.parse('return {x = "\\011"}').x:byte())
```

prints, today:

```
break: 21 [11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31]
load=11 parse=9
```

Exactly the bytes 11..31 break, each of them for every one of the ten
digits that can follow. The writer is right and the reader is wrong:
`string.format("%q", ...)` zero-pads a numeric escape to three digits
when a digit follows it, so byte 11 is written `\011` — and the Lua
manual, and this runtime, read `\ddd` as DECIMAL. Bytes 0-10 survive
because their padded form reads the same either way, and bytes above
99 need no padding, so their escape has no leading zero. Byte 13 (a
carriage return) is in the broken range, so this is not confined to
exotic input.

Byte 27 appears in that list for a second, unrelated reason
(3IKgKs34); it breaks here through the `\ddd` path like its
neighbours, and this fix removes that path's share of it.

## Cause

`cosmic/literal.tl:108`, the `\ddd` branch of `escape_at` (read at
`489bba2f`):

```teal
local n = tonumber(digits) as integer -- cast: decimal digits are integral
```

`tonumber` is called with NO base, and this fork's Lua accepts C-style
prefixes in that form: `tonumber("011")` is 9, and `tonumber("0b11")`
is 3, where stock Lua gives 11 and nil. A leading zero therefore turns
Lua's decimal string escape into an octal one. With the base given
explicitly, `tonumber("011", 10)` is 11 — confirmed by the repro above.

The `\x` and `\u{...}` branches (`cosmic/literal.tl:76`, `:100`) both
pass base 16 and are unaffected. The compact layout is unaffected too:
`cosmo.EncodeLua` writes `\xHH`, a fixed two hex digits, which the `\x`
branch reads correctly.

## Change

Three files. Measured at `489bba2f`: `wc -l cosmic/literal.tl
cosmic/literal_test.tl _fuzz/literal_fuzz_test.tl` is 441, 421, 459 —
59, 79 and 41 lines of headroom under the 500-line cap, and the fuzz
file only shrinks here.

1. **`cosmic/literal.tl:108`** — pass base 10, so the escape is read as
   the decimal the Lua manual specifies and `%q` writes:
   `local n = tonumber(digits, 10) as integer`. One argument; the
   trailing cast justification stays as it is.

2. **`cosmic/literal_test.tl`** — two tests, each called on the line
   after its `end`, per the repo's test convention:
   - `test_every_byte_round_trips_before_a_digit`: for `b = 0, 255`,
     round-trip `{x = string.char(b) .. "0"}` through
     `literal.format`/`literal.parse` and assert equality, collecting
     the failing bytes so a regression names them. This is the loop
     that found the range, kept so a future base-less `tonumber`
     cannot pass. Byte 27 goes through the default `"pin"` layout
     here, which the `\e` defect (3IKgKs34) does not reach, so no byte
     needs excluding.
   - `test_decimal_escape_agrees_with_load`: assert
     `literal.parse('return {x = "\\011"}').x` is byte 11, the same
     byte `load('return "\011"')()` returns.

3. **`_fuzz/literal_fuzz_test.tl`** — retire domain bound 4, which
   exists only for this defect:
   - delete the numbered entry (the `-- 4.` block, lines 57-64 at
     `489bba2f`) and renumber the byte-27 entry from `5.` to `4.`;
   - change the comment's opening count (line 33) from "Five domain
     bounds ... Two of them (4 and 5) are known defects" to four
     bounds, one of them (4) a known defect, keeping the rest of that
     sentence's shape;
   - update the cross-reference in the `ESCAPE_TRAP` doc comment (line
     100) from "domain bound 5 above" to "domain bound 4 above";
   - delete `OCTAL_TRAP_LO`/`OCTAL_TRAP_HI` and their doc comment
     (lines 121-124);
   - in `random_string`, delete the `prev` variable, the `b` local and
     the substitution guard, so the loop is `out[i] =
     random_char(src)`; rewrite its doc comment's first sentence to
     "Draw a string of alphabet characters." and drop the sentence
     about the fixed-byte substitute, which no longer describes it.

   Bound 5 (byte 27, item 3IKgKs34) lives in `random_char` and is
   independent — it stays.

## Non-goals

- **The number-token reader does not change.** `literal.parse("return
  {a = 010}")` returns 8, and so does `load("return 010")` in this
  runtime, so the reader AGREES with the runtime there — a fork
  divergence from stock Lua, not a contract break. Leave
  `cosmic/literal.tl:258` and `:270` (`tonumber(v.tk)`,
  `tonumber(toks[i + 1].tk)`) exactly as they are; adding a base to
  either would make the reader disagree with `load` and break the
  module's stated contract in the other direction.
- No change to `literal`'s public API, its `Options`/`FormatOptions`
  records, its error strings, or either layout's output bytes. This
  fixes the READER only; `format` is already correct.
- Do not touch domain bound 5 (byte 27 / `\e`) or file the fix for it:
  that is item 3IKgKs34, and taking it here would mix two subjects.
- Do not widen the fuzz alphabet, the iteration default, or
  `MAX_STRING_LEN`; the only fuzz change is the bound's removal.

## Acceptance

Every command runs verbatim from the repo root and writes no committed
file.

- `bin/cosmic --make ci` ends `ci: PASS (5 stages)`.
- `bin/cosmic --make test cosmic/literal_test.tl` ends `test: PASS (1
  file)`, including both new tests.
- `FUZZ_ITERS=5000 bin/cosmic --make test _fuzz/literal_fuzz_test.tl`
  ends `test: PASS (1 file)` — the whole alphabet now drawn in every
  position. ~10s wall (3599ms reported by the runner at `489bba2f`).
  This gate discriminates, verified at `489bba2f` during refinement:
  with bound 4's code removed and the fix absent, the same command
  ends `test: FAIL (1 of 1 file)` on `round_trip`'s
  `check.truthy` (`expected truthy, got false`); adding only the base
  10 turns it back to `test: PASS (1 file)`, and the byte sweep above
  then prints `break: 0 []` and `load=11 parse=11` — byte 27 included,
  since the `\e` defect is compact-layout-only and the sweep uses the
  default `"pin"` layout.
- `grep -c OCTAL_TRAP _fuzz/literal_fuzz_test.tl` is 0 (it is 4 at
  `489bba2f`).
- `grep -n 'tonumber(digits' cosmic/literal.tl` shows base 10 (it
  shows a base-less call at `489bba2f`).

## Enablement

none needed — the fix is one argument, the tests use the assertion
pattern already in `cosmic/literal_test.tl`, and the fuzz property that
proves it is already written and running. No blocker items; nothing in
`blocked_by`.
