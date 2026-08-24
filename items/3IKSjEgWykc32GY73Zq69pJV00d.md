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

## Evidence

### The blocker cleared

The contract this parser copies was wrong about `\ddd` until
2026-08-24. `3IKg4hsF` landed as whilp/cosmic#1359 (squash
`585d17f9`), so `cosmic/literal.tl:108` now reads a zero-padded
decimal escape as decimal. Verified on whilp/cosmic `main` at
`585d17f9`, with a binary built from the tree, running the sweep the
blocker's spec names:

```
break: 0 []
load=11 parse=11
```

`3IKgKs34` (byte 27 spelled `\e` by the compact layout's C ENCODER)
remains open and does NOT block: it is a writer-side gap and this item
is a reader.

### No grammar subset is available: the full grammar has a live caller

Re-measured on whilp/cosmic at `585d17f9`.

```
$ find . -name "*_pin.tl" -not -path "./o/*"
./3p/cosmos/cosmos_pin.tl        flat table, strings, integers
./3p/tl/tl_pin.tl                same
$ head -3 .cosmic-coverage       nested tables, strings, integers
$ wc -l 3p/tl/tl_patch.tl
395 3p/tl/tl_patch.tl
$ grep -c '^--' 3p/tl/tl_patch.tl
54
$ grep -c '\[=====\[' 3p/tl/tl_patch.tl
22
```

`3p/tl/tl_patch.tl` is read by `_make/patch.tl` (`literal.parse_file`)
on every build, and it uses the parts of the grammar a subset parser
would drop: 54 `--` comment lines, and 22 level-5 long bracket strings
(`[=====[ … ]=====]`) whose CONTENTS contain `--[[` and `]]`, which is
why the level is 5. So "core subset first, exotica later" is not a cut
this item can take: the first slice would not serve the caller that
most needs the speed.

### The grammar and the refusals to reproduce

Read on whilp/cosmic at `585d17f9`. `cosmic/_literal_lex.tl` is 163
lines and `cosmic/literal.tl` is 441 (`wc -l`). Those two files are
the specification of what the C parser must accept and refuse, and the
implementer reads them rather than a transcription:

- **lexing** — `cosmic/_literal_lex.tl:80-150` (`lex`): a leading `#!`
  line is skipped; whitespace; `--` line comments and `--[=*[` long
  comments; long bracket strings at any `=` level; short strings in
  either quote; numerals by SHAPE (`0[xX]%x*%.?%x*` with an optional
  `[pP]` exponent, or `%d*%.?%d*` with an optional `[eE]` one);
  identifiers, with Lua's 22 reserved words (`:26-33`) lexing as
  `keyword` so `return { end = 1 }` is refused rather than read as a
  key; anything else as a one-character token. Only an unterminated
  string, long string or long comment, and a malformed number, fail
  here.
- **string values** — `cosmic/literal.tl:56-134` (`ESCAPES`,
  `escape_at`, `string_value`): the eleven single-character escapes,
  `\z`, `\xHH`, `\ddd` read as DECIMAL, and `\u{...}` bounded at
  `0x7FFFFFFF` and encoded as UTF-8; a long bracket takes no escapes
  and drops a newline immediately after its opening delimiter.
- **the grammar** — `cosmic/literal.tl:190-365` (`parse_table`,
  `parse`): `return` then one table; entries `name = <value>` or
  `["string"] = <value>`; values a nested table, a string, a numeral,
  `-` before a numeral, or `true`/`false`; separators `,` or `;`;
  a 32-table depth cap.

**The refusal CLASSES the C parser must be able to distinguish** —
seventeen, each a distinct static message except the duplicate one.
They are the `return nil, …` sites in those two ranges. Four are
lexical (`unterminated string`, `unterminated long string`,
`unterminated long comment`, `malformed number`); three are top-level
(`must be exactly \`return { … }\``, `must return a table literal`,
`ends after its table; found '<tk>'`); ten are inside a table
(`nests deeper than 32 tables`; `is a table of \`name = <literal>\`
entries; found '<tk>'`; `has a malformed string key`; `has a
malformed string value for '<key>'`; `has a malformed number value
for '<key>'`; `holds literals only; found '<tk>' (no variables, calls
or concatenation)`; the same `after a value`; `repeats the key
'<key>' (first at line <n>)`; `unexpected end of <noun>`;
`unterminated table in <noun>`).

The C parser does NOT reproduce those strings. Cosmic's messages carry
a `<file>:<line>: a <noun> ` prefix the C side cannot know, and
composing the cosmic-side wording is the sibling adoption item
(`3IKSjS8N`). What this item owes is that each class is
DISTINGUISHABLE and positioned — see Change 1.

### Where it lands, re-measured

whilp/cosmopolitan at `8dd093ce` (`master`).

```
$ wc -l tool/net/ljson.c tool/net/ljson.h tool/lua/lcosmo.c tool/net/definitions.lua
   649 tool/net/ljson.c
    15 tool/net/ljson.h
   346 tool/lua/lcosmo.c
  8250 tool/net/definitions.lua
$ grep -n "ljson.o" tool/net/BUILD.mk tool/lua/BUILD.mk
tool/net/BUILD.mk:102   tool/lua/BUILD.mk:31
$ grep -n "TOOL_LUA_TESTS" tool/lua/BUILD.mk
217:TOOL_LUA_TESTS =
254:		$(TOOL_LUA_TESTS)
$ ls tool/lua/test_*.lua | wc -l
30
$ find . -name "llua*" -o -name "lliteral*"      # the name is free
$ grep -n "lua_stringtonumber" third_party/lua/lua.h
354:LUA_API size_t   (lua_stringtonumber) (lua_State *L, const char *s);
$ grep -n "DecodeLua" tool/net/definitions.lua tool/lua/lcosmo.c   # unused name
```

`tool/lua/BUILD.mk:253` is the `o/$(MODE)/tool/lua/test` target, which
also runs `test_definitions_coverage.lua` and
`test_definitions_conformance.lua` — the annotation and return-arity
ratchets — over `definitions.lua`. A test file is registered by a
two-line rule (the pattern at `tool/lua/BUILD.mk:129-130`) plus one
entry in `TOOL_LUA_TESTS`.

**Prerequisite, cleared:** the parent recorded that any C A/B here was
unmeasurable while `o//depend` was never generated. That landed as
whilp/cosmopolitan#270 (board `3IHHJcVr`) and is an ancestor of
`8dd093ce`, so incremental C measurement is sound.

### Question 5, settled: ONE landing, and the measurement that decides it

The earlier refinement guessed "plausibly past 900 lines" and left the
cut open between one landing and a scanner-then-parser pair with a
temporary binding. Measured now, the guess was too high.

A skeleton was written to count it: the license header, the includes,
the constants, the keyword table, and every function signature this
parser needs with its body elided. That skeleton is **139 lines**. The
bodies were then estimated against `ljson.c`'s counted sections
(`Parse` spans `tool/net/ljson.c:96-616`, 521 lines, of which the
string case alone — relative 228 to 491 — is ~263):

| body | est. | calibration |
|------|-----:|-------------|
| `IsLongBracket` | 10 | — |
| `LongBracketEnd` | 15 | — |
| `SkipTrivia` (space, `--`, `--[=*[`) | 35 | — |
| `ScanShortString` (escapes) | 120 | ljson's string case is 263 WITH UTF-8 validation and UTF-16 surrogate pairing, neither of which this grammar needs |
| `ScanLongString` | 25 | — |
| `ScanNumber` | 45 | ljson's number cases are ~59; here the shape is scanned and handed to `lua_stringtonumber`, which is also what makes it agree with `load` |
| `FirstKeyAt` (cold re-scan) | 35 | — |
| `ParseTable` | 150 | ljson's `[`/`{`/`,`/`:`/literal handling is ~100 |
| `Parse`, `DecodeLua` | 45 | — |
| **bodies** | **480** | |
| **+ skeleton** | **619** | |

So the file lands near `ljson.c`'s own 649, not past 900. Two things
in the skeleton can come out and were left in the count as slack: the
46-line `kLuaChar` byte-class table is not needed (this grammar's
classes are exactly `libc/ctype.h`'s, and the hot loop branches on
structural bytes — `{`, `}`, `=`, `,`, `"` — not on classification),
and the keyword table is 8 lines.

**The decision: one landing.** Reasons, in order:

1. The number. ~620 lines is `ljson.c`'s size, in the same directory,
   for the same kind of artifact, which this repo reviewed as one file.
2. The two-landing option does not divide anything. A scanner with no
   parser parses nothing, so the first landing's only exercise is a
   binding that exists to be tested and then removed — a contract added
   and withdrawn inside one item, in a repo whose convention is that
   binding contracts at the C boundary are frozen.
3. It is also the wrong SHAPE. A standalone scanner implies a token
   stream, and materializing tokens is precisely what makes the Teal
   reader slow (lexing is ~80% of parse). The C parser scans and parses
   in one pass, pushing straight onto the Lua stack, as `ljson.c` does.
4. Every alternative cut still exceeds cosmic's ~400-line
   sizing smell, so none of them buys the thing the smell is for.

Stated plainly rather than hidden: this slice is ~2.5x that smell
threshold. Acceptance therefore carries a hard ceiling (`wc -l
tool/net/llua.c` ≤ 800) so a design that blows past the estimate fails
the gate instead of arriving as a surprise at review.

## Change

Six files in whilp/cosmopolitan. No cosmic-side file is touched.

**1. `tool/net/llua.h`** (new, ~15 lines) — mirror `tool/net/ljson.h`:

```c
#define LLUA_ERRMAX 256
struct DecodeLua {
  int rc;
  const char *p;
};
struct DecodeLua DecodeLua(struct lua_State *, const char *, size_t, char *,
                           size_t);
```

`rc` is 1 when one value was pushed, 0 for eof, -1 for an error. On
success `p` is the rest of the input, exactly as `DecodeJson` returns
it. **On -1, `p` points at the FAILING BYTE of the input** and the
message is written into the caller's buffer (the last two arguments).

That buffer is the one deviation from `DecodeJson`'s signature, and it
is deliberate. `DecodeJson` returns a STATIC message in `p`, which
cannot carry a key name; the duplicate-key refusal must. Pushing the
message onto the Lua stack instead would be worse, not better: the
parser may hold partial tables on the stack when it fails, so the
caller has to `lua_settop` back to its entry depth, which would
discard the message it was about to read. A caller-supplied buffer is
reentrant, keeps the struct pure C, and keeps the error path away from
the stack entirely. `LLUA_ERRMAX` is 256 and the message is truncated
to fit — a key longer than the buffer is truncated in the message
only, never in the refusal itself.

Reporting a byte OFFSET rather than a line is what keeps line-counting
out of the hot loop: the offset is free because the parser already
holds the cursor, and the Lua side counts newlines up to it once, on
failure.

**2. `tool/net/llua.c`** (new, ~620 lines) — the parser, in one pass,
recursive descent, no token stream. Shape it as the skeleton above:
constants (`DEPTH 32`, `MAXCODEPOINT 0x7fffffff`), the sorted
22-entry keyword table, then `IsLongBracket`, `LongBracketEnd`,
`SkipTrivia`, `ScanShortString`, `ScanLongString`, `ScanNumber`,
`FirstKeyAt`, `ParseTable`, `Parse`, `DecodeLua`. Rules:

- **Classify with `libc/ctype.h`** (`isalpha`, `isalnum`, `isdigit`,
  `isspace`), not a bespoke 256-byte table.
- **Numbers**: scan the numeral's SHAPE per `_literal_lex.tl`'s
  `numeral_at`, then hand the text to `lua_stringtonumber`
  (`third_party/lua/lua.h:354`). A shape `lua_stringtonumber` rejects
  (`0x.`, `1e`) is the "malformed number value" refusal, exactly as
  the Teal reader's `tonumber` check is.
- **Depth**: `DEPTH 32`, matching the reader, AND the real C stack
  guard `ljson.c` uses (`GetStackPointer() < bsp`). Neither is an
  option and neither is caller-supplied.
- **Duplicate keys**: refuse. Detect with `lua_rawget` before the
  `lua_rawset`; on a hit call `FirstKeyAt`, which re-scans the
  enclosing table's entries from its opening `{` for the first entry
  naming that key. That re-scan is COLD — it runs only to compose the
  refusal — so no table pays a shadow map for it. The message is
  `snprintf`ed into the error buffer as
  `repeats the key '%.*s' (first at offset %d)`; every other message is
  a distinct static string copied into the same buffer, one per refusal
  class, and reproducing cosmic's wording is the sibling item's job.
- **`\u{...}`** is bounded at `0x7FFFFFFF` and encoded as UTF-8 (up to
  six bytes), matching `utf8.char`; above the bound is a refusal, not
  a truncation.
- Keep the fork mergeable: a new file plus the entries below, and no
  edit to any neighbouring file's existing lines.

**3. `tool/lua/lcosmo.c`** (~35 lines added) — `LuaDecodeLua`,
modelled on `LuaDecodeJson` (`tool/lua/lcosmo.c:44-79`), plus one
`{"DecodeLua", LuaDecodeLua}` entry in the registration table beside
`{"EncodeLua", …}` at `:230`. It returns the value on success, and on
failure `nil, message, offset`, where it owns the `char
errbuf[LLUA_ERRMAX]` it passes down and `offset` is `r.p - p` as a
1-based byte index. Slot 2 stays the message, so cosmic's
fallible-returns shape is unaffected: the wrapper reads three and
returns two. `#include "tool/net/llua.h"` beside the `ljson.h`
include. Measured headroom: `tool/lua/lcosmo.c` is 346 lines and this
repo imposes no per-file cap.

**4. `tool/net/BUILD.mk` and `tool/lua/BUILD.mk`** — one
`o/$(MODE)/tool/net/llua.o` line beside the `ljson.o` line in each
(`tool/net/BUILD.mk:102`, `tool/lua/BUILD.mk:31`); a two-line
`o/$(MODE)/tool/lua/test_llua.ok` rule in the style of
`tool/lua/BUILD.mk:129-130`; and one `test_llua.ok` entry in
`TOOL_LUA_TESTS` (`:217`).

**5. `tool/net/definitions.lua`** (~15 lines added, same commit) —
the `cosmo.DecodeLua(source)` annotation block beside
`cosmo.EncodeLua` at `:2505`, with full `@param`/`@return` for all
three returns. The coverage and conformance ratchets in
`o//tool/lua/test` fail otherwise, and that is the gate.

**6. `tool/lua/test_llua.lua`** (new, ~250 lines) — registered as
above. Its core assertion is the module's actual contract, and it is
self-contained because `load` is in the same process:

- **agreement with `load`**: a table of source strings, each asserted
  to deep-equal `load(s)()`. Cover, at minimum: a flat table of
  strings and integers (the `*_pin.tl` shape); a nested table (the
  `.cosmic-coverage` shape); a leading `#!` line; `--` line comments
  and a `--[==[ … ]==]` long comment; a level-5 long bracket whose
  BODY contains `--[[` and `]]` (the `tl_patch.tl` shape); both quote
  forms; every escape form including `\z`, `\xHH`, `\011`, and
  `\u{...}` at the bound; negative numbers, hex numerals, hex floats
  with a `[pP]` exponent, decimal exponents; `["key"] =` and
  `name =` entries; `,` and `;` separators; `true`/`false`.
- **the byte sweep**: for `b = 0, 255`, `DecodeLua(string.format('return {x = %q}', string.char(b) .. "0"))` equals
  `load` of the same source. This is the sweep that caught the blocker
  on the Teal side.
- **the refusal classes**: one case per class from Evidence, each
  asserting `nil`, a message DISTINCT from every other class's, and
  the expected byte offset. Include a `["a"]=1, a=1` duplicate whose
  message names the key and the first offset, a 33-deep nesting, and
  `return { end = 1 }`.

## Non-goals

- **No cosmic-side change in this item.** The type regen, the wrapper
  that composes `<file>:<line>: a <noun> …` from the class and the
  offset, and the differential harness are the sibling adoption item
  (`3IKSjS8N`). This one lands in whilp/cosmopolitan and nothing else.
- **Do not change `DecodeJson`, `EncodeJson`, `EncodeLua` or any
  existing binding's contract.** Return shapes, error values and
  constants at the C boundary are frozen; cosmic's generated types and
  wrappers depend on them. Add lines to `lcosmo.c`, `definitions.lua`
  and the two `BUILD.mk`s; edit no existing line in them beyond the
  registration entries this names.
- **Do not add an evaluator.** No `load`, no chunk compilation, no
  environment, in the parser. (`load` appears only in the TEST, as the
  oracle.) The parent item records `load("return "..s, "t", {})` as
  measured and disqualified.
- **Do not add an `on_duplicate` callback or policy flag.** Settled:
  refuse-only. A C parser that calls back into Lua per duplicate key
  gives back the speed it exists to gain, and a policy flag is a second
  contract to freeze before anyone needs it. Cosmic's two callback
  callers (`_tool/floor.tl`, `_tool/coverage/baseline.tl`) keep the
  Teal reader; they read ratchet floors, which are not a defining path.
- **Do not reproduce cosmic's message WORDING.** Distinct classes and
  a correct offset are the contract here; the prose is the wrapper's.
- **Do not fix `3IKgKs34`** (byte 27 spelled `\e` by the compact
  layout's encoder). It is writer-side and a separate item.
- **Do not make the depth cap or the string-buffer size caller-supplied.**
  A cap a caller can raise is a cap that is not a safety property.
- **Keep the fork mergeable with upstream jart/cosmopolitan**: no
  reformatting, no restructuring of neighbouring files.

## Acceptance

Every command runs verbatim from the whilp/cosmopolitan repo root and
writes no committed file. A first build downloads the cosmocc
toolchain; after that it is hermetic.

- `make -j$(nproc) o//tool/lua/test` exits 0. This target includes
  `test_definitions_coverage.lua` and `test_definitions_conformance.lua`,
  so it is also the gate that `DecodeLua` is annotated and its return
  arity declared; neither may grow an allowlist entry.
- `make -j$(nproc) o//tool/lua/test_llua.ok` exits 0 — the new test on
  its own, including the byte sweep and one case per refusal class.
- `wc -l tool/net/llua.c` is ≤ 800. (The estimate is ~620; this is the
  ceiling that turns the estimate into a contract.)
- `grep -c 'DecodeLua' tool/net/definitions.lua` is ≥ 1 (it is 0 at
  `8dd093ce`).
- `grep -c 'llua.o' tool/net/BUILD.mk tool/lua/BUILD.mk` is 1 in each
  (0 in each at `8dd093ce`).
- The discriminating check, to run BEFORE the fix is complete: with
  `tool/lua/test_llua.lua` present and `tool/net/llua.c` absent,
  `make -j$(nproc) o//tool/lua/test_llua.ok` fails. A test that passes
  without the parser is not testing the parser.

## Enablement

none needed. Both blockers are cleared: `3IHHJcVr` (the `o//depend`
fix, whilp/cosmopolitan#270) landed 2026-08-23, and `3IKg4hsF` (the
`\ddd` reader fix, whilp/cosmic#1359) landed 2026-08-24 and is
re-verified in Evidence. `blocked_by` is empty.

The last open decision — question 5, the cut — is settled in Evidence
with the measurement the previous pass asked for. Nothing in `Change`
says "investigate", "explore" or "support", and every file it names
was read at the commit stated beside it.
