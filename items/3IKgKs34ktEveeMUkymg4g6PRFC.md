## Goal

G5 — adversarial verification, whose win condition is that findings
become regression tests. This is one: the literal fuzz properties
(board item `3IKSi0JN`) found a real round-trip break, and the file
had to bound its own domain to stop re-reporting it. Landing this
turns the finding into a named regression test AND gives the fuzzer
back the byte it is currently forbidden from drawing, so the
verification surface grows rather than shrinks.

## Evidence

`literal.format(v, {layout = "compact"})` writes source that
`literal.parse` then REFUSES, for any string — key or value — holding
byte 27 (ESC). One byte, and only that one.

**Re-measured 2026-08-24 on `main` at `585d17f9`**, with a binary
built from the tree, formatting `{x = string.char(b)}` and
`{[string.char(b)] = 1}` for every b in 0..255 in both layouts and
reading each back:

```
pin     value bytes broken: (none)   key bytes broken: (none)
compact value bytes broken: 27       key bytes broken: 27

compact source for byte 27: return {x="\e"}
parse: nil / literal:1: a literal has a malformed string value for 'x'
```

Originally found by the literal fuzz properties at `FUZZ_ITERS=5000`,
seed 1, iteration 327, property `round_trip`.

`\e` is a fork extension, not Lua: this runtime's own `load` accepts
it and returns byte 27, so `cosmo.EncodeLua` is self-consistent with
the compiler beside it. `cosmic/literal.tl:55-58`'s `ESCAPES` table
holds the ten escapes the Lua manual defines plus the escaped
newline, and not this one, so the reader refuses what that writer
produced.

This is a hole in the guard PR #1346 added with the compact layout.
That guard's promise is that a value the C encoder cannot spell the
way the reader reads comes back in the pin layout instead — it covers
a reserved word as a key and `math.mininteger`, and byte 27 is the
third member of that set, missed because the probe that found the
first two went value-kind by value-kind rather than byte by byte.
Severity is a loud refusal rather than silent corruption, but
`format_file` in the compact layout writes a file `parse_file` cannot
read back, which is the same contract break.

### The decision, settled: the WRITER turns it down

The earlier pass left two fixes open. Settled on (a), the writer:

- **(a) the writer turns it down.** `is_compact_scalar` and
  `is_compact_writable` in `cosmic/_literal_format.tl` refuse a string
  containing byte 27, so the value takes the handoff to the pin layout
  that a reserved key and `math.mininteger` already take
  (`cosmic/_literal_format.tl:379`, `return format(value)`). `pin`
  writes `\27`, which the sweep above shows reads back for all 256
  bytes.
- **(b) the reader accepts it** — add `e = "\27"` to `ESCAPES`.
  Rejected. It is cheaper and it would make `parse` agree with this
  runtime's `load`, but it makes a file this module writes depend on a
  fork extension. `cosmic.literal` exists to write files that are
  stock Lua data — the pins in `3p/**/*_pin.tl` and the carried patch
  `3p/tl/tl_patch.tl` are read on every build by `_make/patch.tl`, and
  the trust root's whole point is that a pin is inert, ordinary source.
  A pin only stock-Lua-with-fork-escapes can read is a worse artifact
  than one the writer declines to spell compactly.

(a) also costs nothing a caller can see: the compact layout is an
optimization over the pin layout, and declining it for one byte is
exactly what the existing guard already does twice.

### Where it lands, measured

`main` at `585d17f9`:

```
$ wc -l cosmic/_literal_format.tl cosmic/_literal_format_test.tl \
        cosmic/literal.tl _fuzz/literal_fuzz_test.tl
  421 cosmic/_literal_format.tl        (79 under the 500-line cap)
  209 cosmic/_literal_format_test.tl   (291 under)
  441 cosmic/literal.tl
  434 _fuzz/literal_fuzz_test.tl       (66 under)
$ grep -n 'is_compact_scalar\|is_compact_writable' cosmic/_literal_format.tl
66:local function is_compact_scalar(v: any): boolean
323:local function is_compact_writable(t: {any: any}, depth: integer): boolean
335:      if not is_compact_writable(v, depth + 1) then
338:    elseif not is_compact_scalar(v) then
378:    if not is_compact_writable(value, 1) then
$ grep -n 'ESCAPE_TRAP' _fuzz/literal_fuzz_test.tl
93:local ESCAPE_TRAP = 27
94:local ESCAPE_TRAP_SUBSTITUTE = 26
104:    if b == ESCAPE_TRAP then
105:      b = ESCAPE_TRAP_SUBSTITUTE
```

Both guards are needed and neither substitutes for the other:
`is_compact_scalar` sees VALUES (`cosmic/_literal_format.tl:338`),
while keys are checked in `is_compact_writable`'s loop, which today
tests only `k is string` and `RESERVED[k]`
(`cosmic/_literal_format.tl:327-333`) and never looks at the key's
bytes. The sweep breaks in both positions, so both need the check.

`_fuzz/literal_fuzz_test.tl:33-62` is the four-entry domain-bounds
comment; entry 4 (`:56-62`) is this defect and names this item.

## Change

Three files.

**1. `cosmic/_literal_format.tl`** — refuse byte 27 in a string the
compact writer would spell.

- Add one file-local predicate beside the existing guards, in their
  style, testing a string for the byte the C encoder spells its own
  way: a `find` for `"\27"` with `, 1, true` (the `find-needle` lint
  requires the plain-substring flag). Give it the doc comment shape
  its neighbours have, naming WHY — `cosmo.EncodeLua` writes byte 27
  as `\e`, a fork extension `literal.parse`'s `ESCAPES` does not
  admit, so a string holding it is written by the pin layout instead.
- Call it from `is_compact_scalar`'s `v is string` branch
  (`:67-69`), which today returns `true` unconditionally.
- Call it on the KEY in `is_compact_writable`'s loop, beside the
  existing `RESERVED[k]` test (`:331-333`).

Do not change `format`, the pin layout, `MAX_DEPTH`, `RESERVED`, or
any refusal message. The handoff at `:379` already routes a refused
value to the pin layout and needs no edit.

**2. `cosmic/_literal_format_test.tl`** (+~30 lines) — one
`test_every_byte_round_trips` in the file's established shape, called
on the line after its `end`. For each of the 256 byte values, in both
layouts (`pin` and `compact`), as a value (`{x = string.char(b)}`) and
as a key (`{[string.char(b)] = 1}`): format, parse the result back,
and assert the parsed value equals what went in. On failure the
assertion message names the byte, the layout and the position, so the
next byte an encoder spells its own way is reported by name rather
than as a generic mismatch. This is the loop from Evidence, kept.

**3. `_fuzz/literal_fuzz_test.tl`** — remove the bound this defect
forced, in the same PR:

- delete `ESCAPE_TRAP` and `ESCAPE_TRAP_SUBSTITUTE` (`:93-94`) and
  the substitution branch that reads them (`:104-105`), so byte 27 is
  drawn like every other byte;
- delete entry 4 from the domain-bounds comment (`:56-62`) and change
  its opening line (`:33`) from "Four domain bounds" to "Three", so
  the count matches the list.

## Non-goals

- **Do not add `e` to `cosmic/literal.tl`'s `ESCAPES`.** Settled
  above: the reader stays stock Lua. `cosmic/literal.tl` is not
  edited by this item at all.
- **Do not touch whilp/cosmopolitan.** `cosmo.EncodeLua` spelling
  byte 27 as `\e` is a frozen C-boundary behaviour and is
  self-consistent with the `load` beside it; the fix is on the cosmic
  side of the boundary.
- **Do not change the pin layout.** It round-trips all 256 bytes in
  both positions today (Evidence) and must keep doing so.
- **Do not change any refusal message or return shape** in
  `cosmic/_literal_format.tl`. A value the compact writer declines is
  handed to the pin layout, not refused to the caller — that is the
  existing behaviour and it does not move.
- **Do not fix `3ICDKhO3`** (the depth-33 inline-render break, domain
  bound 1 in the same comment). It is a separate item and its bound
  stays.
- **Do not widen the fuzz alphabet or iteration count.** The only
  fuzz edit is removing bound 4 and its two constants.

## Acceptance

Every command runs verbatim from the repo root and writes no
committed file.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/_literal_format_test.tl` passes,
  including the new `test_every_byte_round_trips`.
- `FUZZ_ITERS=5000 FUZZ_SEED=1 bin/cosmic --make test
  _fuzz/literal_fuzz_test.tl` passes — the run that originally found
  this, with byte 27 now drawable.
- `grep -c ESCAPE_TRAP _fuzz/literal_fuzz_test.tl` is 0 (it is 4 at
  `585d17f9`).
- `grep -c 'Four domain bounds' _fuzz/literal_fuzz_test.tl` is 0 and
  `grep -c 'Three domain bounds' _fuzz/literal_fuzz_test.tl` is 1
  (1 and 0 respectively at `585d17f9`).
- `wc -l cosmic/_literal_format.tl` is ≤ 460 (421 at `585d17f9`; the
  cap is 500 and this bound is the slice's own).
- `wc -l cosmic/_literal_format_test.tl` is ≤ 260 (209 at
  `585d17f9`).
- The discriminating check, to run BEFORE the fix is complete: with
  the new test in place and `cosmic/_literal_format.tl` unchanged,
  `bin/cosmic --make test cosmic/_literal_format_test.tl` FAILS,
  naming byte 27 in the compact layout. A test that passes without
  the writer fix is not testing it.

## Enablement

none needed. The defect reproduces in seconds against a binary built
from the tree (Evidence, re-measured at `585d17f9`), both call sites
to edit are named with their line numbers, and the handoff the fix
relies on already exists and is already exercised by two other
refusals. `blocked_by` is empty: `3IKSi0JN` (the fuzz properties that
found this) is landed, and `3ICDKhO3` is a sibling defect behind its
own domain bound, which this item leaves alone.
