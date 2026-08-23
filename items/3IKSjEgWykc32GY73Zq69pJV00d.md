## Goal

G6 — the defining paths, ratcheted. The C half of the parent
hypothesis: a data parser for the Lua-literal grammar in
whilp/cosmopolitan, beside the JSON one, so `cosmic.literal`'s reader
can reach `json.decode`'s order of magnitude. The parent item
(`3IK8E4XF`) carries the measurement that motivates it: `literal.parse`
is 47-53x behind `json.decode` (391-404µs vs 7.5µs small; 238-257ms vs
5.2ms on a ~955KB literal, scouting numbers), lexing is ~80% of parse,
and a probed jump-scanning Teal lexer tops out at 3.0x — pure Teal
cannot close it.

**This item is in `plan`, not ready, and is now BLOCKED.** Refinement
pass 2026-08-23 settled four of the five open questions against
measured ground and found the reason it cannot be sliced yet: the
contract it would freeze in C is wrong today. What remains for the
next refinement is the cut (question 5), and it should not be made
until the blocker lands.

## Evidence

### The blocker: the contract to reproduce is not the contract as shipped

Two round-trip defects in `cosmic.literal` were found on
2026-08-23 by the literal fuzz properties (`3IKSi0JN`, PR #1347) and
are filed separately:

- **`3IKg4hsF`** — `cosmic/literal.tl:108` decodes the `\ddd` string
  escape with a base-less `tonumber`, and this fork's Lua reads a
  leading zero as an octal prefix, so `format` writes byte 11 and
  `parse` returns byte 9. Silent, for every byte in 11..31 followed by
  a digit. This runtime's own `load` reads `"\011"` as byte 11, so the
  reader is wrong against Lua, against `%q`, and against `load`.
- **`3IKgKs34`** — `cosmo.EncodeLua` spells byte 27 as `\e`, a fork
  extension `load` accepts and the reader does not, so `format_file`
  in the compact layout writes a file `parse_file` cannot read.

Why this blocks THIS item rather than merely neighbouring it: a C
parser's whole job here is to reproduce the Teal reader's contract
byte for byte, and the sibling adoption item (`3IKSjS8N`) proposes to
prove that by differentially fuzzing the two against each other. Write
the C parser against today's reader and one of two bad things happens
— it reproduces the octal bug on purpose and the bug becomes a
contract, or it reads `\011` correctly and the differential harness
reports a disagreement that is the Teal side's fault. Neither is a
thing to discover after a large C PR is written. `3IKg4hsF` is a
one-argument fix; it lands first.

`3IKgKs34` is recorded here but does NOT block: it is a writer-side
gap in the compact layout, and the C parser is a reader.

### No grammar subset is available: the full grammar has a live caller

Measured on `whilp/cosmic` at `83b4fd71`. The committed literal files
in the tree, and what each uses:

```
$ find . -name "*_pin.tl" -not -path "./o/*"
./3p/cosmos/cosmos_pin.tl        flat tables, strings, integers
./3p/tl/tl_pin.tl                same
$ ls .cosmic-coverage            nested tables, strings, integers
$ wc -l 3p/tl/tl_patch.tl
395 3p/tl/tl_patch.tl
```

`3p/tl/tl_patch.tl` is read by `_make/patch.tl:73`
(`literal.parse_file(path, {noun = "patch"})`) on every build, and it
uses the parts of the grammar a subset parser would drop:

- a 40-line block of `--` line comments at the head, and more inline
- long bracket strings at level 5 — `[=====[ … ]=====]` at lines 204,
  212, 218, 226 — whose CONTENTS contain `--[[` and `]]`, which is
  exactly why the level is 5

So "core subset first, exotica later" is not a cut this item can take:
the first slice would not serve the caller that most needs the speed.
Whatever the cut is, comments and arbitrary-level long brackets are in
the first piece.

### The grammar to reproduce, enumerated

`cosmic/_literal_lex.tl` (163 lines) and `cosmic/literal.tl` (441) at
`83b4fd71`. Tokens: identifiers, the 22 reserved words as a distinct
`keyword` kind (so `return { end = 1 }` is refused rather than read as
a key — `_literal_lex.tl:22-32`), short strings in either quote, long
bracket strings at any `=` level, `--` line comments and `--[=*[` long
comments, numerals (`0[xX]%x*%.?%x*` with an optional `[pP]` exponent,
or `%d*%.?%d*` with an optional `[eE]` exponent), and punctuation.
Anything unrecognized becomes a one-character token the parser refuses
by name; only an unterminated string, long string or long comment
fails in the lexer. A leading `#!` line is skipped.

The parser (`cosmic/literal.tl:196-311`) accepts exactly: a `return`
of one table; entries of the form `name = <value>` or
`["string"] = <value>`; values that are a nested table, a string, a
numeral, an optional `-` before a numeral, or `true`/`false`;
separators `,` or `;`; a 32-table depth cap. Its refusals, which the C
side must be able to reproduce, are these eight, all shaped
`<file>:<line>: a <noun> <what>`:

1. `is a table of \`name = <literal>\` entries; found '<tk>'`
2. `has a malformed string key`
3. `has a malformed string value for '<key>'`
4. `has a malformed number value for '<key>'` (the lexer's numeral is
   a SHAPE — `0x.` and `1e` lex and `tonumber` then returns nil)
5. `holds literals only; found '<tk>' (no variables, calls or concatenation)`
6. `holds literals only; found '<tk>' after a value (…)`
7. `repeats the key '<key>' (first at line <n>)`
8. `unexpected end of <noun>` / `unterminated table in <noun>` /
   `nests deeper than 32 tables`

### Where it lands, re-measured

whilp/cosmopolitan at `8e071ec9` (`master`).

```
$ wc -l tool/net/ljson.c tool/lua/lcosmo.c tool/net/definitions.lua
   649 tool/net/ljson.c
   346 tool/lua/lcosmo.c
  8246 tool/net/definitions.lua
$ grep -n "ljson.o" tool/net/BUILD.mk tool/lua/BUILD.mk
tool/net/BUILD.mk:102   tool/lua/BUILD.mk:31
```

`tool/lua/BUILD.mk:253` is the `o/$(MODE)/tool/lua/test` target, which
also runs `test_definitions_coverage.lua` and
`test_definitions_conformance.lua` — the annotation and return-arity
ratchets — over `definitions.lua`. There are 30 `tool/lua/test_*.lua`
files today.

**Prerequisite, cleared:** the parent recorded that any C A/B here was
unmeasurable while `o//depend` was never generated. That landed as
whilp/cosmopolitan#270 (board `3IHHJcVr`), and it is the tip of
`master` at `8e071ec9`, so incremental C measurement is sound.

## Change

### Settled — do not re-open these

**1. Return shape: the `struct DecodeJson` shape, plus a byte offset.**
`tool/net/ljson.h` declares

```c
struct DecodeJson { int rc; const char *p; };
```

where `rc` is the number of values pushed (1), `0` for eof, or `-1`
for an error with `p` as a static message; on success `p` is the rest
of the input. `LuaDecodeJson` (`tool/lua/lcosmo.c:44-79`) turns that
into `value` or `nil, msg`. The literal parser follows the same shape
and the same two-return Lua contract, with ONE addition: on `rc == -1`
it also reports the byte OFFSET at which the parse failed.

The reason, stated so it is not re-litigated: `cosmic.literal`'s
messages carry `<file>:<line>:`, and `DecodeJson`'s carry no position
at all. Counting lines in the C parser's hot loop costs the hot path
for something only the error path reads. An offset is free — the
parser already holds the cursor — and the Lua side converts offset to
line by counting newlines up to it, once, on failure. So the binding
returns `nil, message, offset` and cosmic's wrapper composes the
existing string. The offset is the THIRD return and slot 2 is still
the message, so the fallible-returns shape on the cosmic side is
unchanged: the wrapper reads all three and returns two.

**2. Duplicate keys: the C parser refuses, and offers no policy.**
`on_duplicate` is a Lua callback with exactly two callers in the
cosmic tree (`_tool/floor.tl:39` and `_tool/coverage/baseline.tl`, both
reading committed ratchet floors). A C parser that calls back into Lua
per duplicate key gives back the speed it exists to gain, and a policy
flag is a second contract to freeze before anyone needs it. The C
parser therefore behaves as the Teal reader does with no
`on_duplicate`: it refuses, reporting the repeated key and both
offsets. The two callback callers keep the Teal reader until a
follow-up item earns the policy; they read floors, which are written
once per gate run and are not on a defining path.

**3. Depth cap: a compile-time constant, 32, matching the reader.**
`ljson.c` uses `#define DEPTH 64` and also guards the real C stack
(`GetStackPointer() < bsp`). The literal parser takes both: `32` so
the refusal is identical to the Teal reader's, and the stack guard
because a recursive-descent C parser on attacker-shaped input needs
it regardless. Not an option and not caller-supplied — a cap a caller
can raise is a cap that is not a safety property.

**4. Out of grammar: the enumeration above is the list.** The C parser
refuses, by the same classification, everything in the eight refusals
enumerated in Evidence — array-style tables, non-string keys, reserved
words as bare keys, an unterminated string or long comment, a numeral
shape `tonumber` rejects, a repeated key, anything past 32 tables, and
any token that is not part of a `name = <literal>` entry. "The same
set as the Teal reader" is not an acceptable spec line and this list
replaces it.

### Open — for the next refinement, after the blocker lands

**5. The cut.** `ljson.c` is 649 lines for a strictly smaller grammar:
no comments, no long brackets, one string form, one number form, no
identifiers, no duplicate-key question. This grammar plausibly lands
past 900 lines in one file, which is a very large single C PR to
review even though this repo has no line cap. The cut by grammar
subset is measured out above (tl_patch.tl needs the whole thing), so
the candidates left are:

- scanner and parser as two landings, the scanner first with its own
  `tool/lua/test_*.lua` reaching it through a temporary binding — the
  cost being a binding that exists only to be tested and then removed
- one landing, reviewed as one large C file the way `ljson.c` was

The next refinement picks one, WITH a measured line estimate rather
than the guess above: write the token table and the parser skeleton,
count them, and decide from the number.

## Non-goals

- **No cosmic-side change in this item.** The type regen, the wrapper
  and the differential harness are the sibling adoption item
  (`3IKSjS8N`); this one lands in whilp/cosmopolitan and nothing else.
- **Do not fix `3IKg4hsF` here.** It lands on the cosmic side, on its
  own, and this item waits for it.
- **Do not change `DecodeJson`, `EncodeJson`, `EncodeLua` or any
  existing binding's contract.** Return shapes, error values and
  constants at the C boundary are frozen; cosmic's generated types and
  wrappers depend on them.
- **Do not add an evaluator.** No `load`, no chunk compilation, no
  environment. A parser with no evaluator is the point; the parent
  item records `load("return "..s, "t", {})` as measured and
  disqualified (the string metatable survives an empty env, expression
  chunks admit function literals, bare identifiers read `nil`).
- **Do not add an `on_duplicate` callback or policy flag** — settled
  above as refuse-only.
- **Keep the fork mergeable.** Surgical diff in `tool/net` plus the
  two BUILD.mk entries and `definitions.lua`; no reformatting, no
  restructuring of neighbouring files.
- **`definitions.lua` moves in the same commit** as the binding, with
  full `@param`/`@return` annotations — the coverage ratchet fails
  otherwise, and that is the gate, not a convention.

## Acceptance

Not writable until question 5 is settled: the acceptance names the
files a slice creates, and the cut decides how many there are. The
floor every candidate slice will build on, measured today:

- `make -j$(nproc) o//tool/lua/test` exits 0, with
  `test_definitions_coverage.lua` and
  `test_definitions_conformance.lua` reporting no allowlist growth.
- a new `tool/lua/test_<name>.lua` covering the grammar and each of
  the eight refusal classes enumerated in Evidence, by class.
- the four committed literal files in the cosmic tree parse to values
  equal to what the Teal reader returns for them: the two `*_pin.tl`,
  `.cosmic-coverage`, and `3p/tl/tl_patch.tl` (the one that exercises
  comments and level-5 long brackets).

## Enablement

`3IHHJcVr` (the `o//depend` fix) was the tooling blocker and landed on
2026-08-23 as whilp/cosmopolitan#270.

What blocks now is a CONTRACT, not tooling: `3IKg4hsF` must land so
the reader this parser copies is right about `\ddd`. Mirrored in
`blocked_by`.

The remaining work before `ready` is refinement, not enablement:
question 5 is a decision, and a session that implemented this today
would be inventing an answer to it and writing a 900-line C file
against a contract with a known bug in it.
