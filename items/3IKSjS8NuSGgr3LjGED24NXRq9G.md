## Goal

G6 — the defining paths, ratcheted. The cosmic half of the parent
hypothesis (`3IK8E4XF`): now that `cosmo.DecodeLua` exists in the fork
and ships in a cosmos release, adopt it behind `cosmic.literal.parse`
without giving up anything the pure-Teal reader guarantees, and prove
the two readers agree on the fuzz corpus.

## Evidence

Both blockers landed. `3IKSjEgW` (the C parser) is
`whilp/cosmopolitan` commit `354c17e0` — "DecodeLua: a Lua-literal
data parser in C, beside the JSON one (#274)" — and it ships in
release `2026.08.24-354c17e08`, published 2026-08-24T19:53Z.
`3IKSi0JN` (the fuzz properties) left `_fuzz/literal_fuzz_test.tl`
behind, which is what this item extends.

**The C parser's contract, measured 2026-08-24** by unpacking that
release's `cosmos.zip` and running its `lua` directly (`local c =
require("cosmo")`), so none of the parity claims below is inferred
from the annotation:

```
DecodeLua("return {a = 1, b = {c = \"x\"}}")   -> table, .b.c == "x"
DecodeLua("return {a = 1, a = 2}")             -> nil, "repeats the key 'a' (first at offset 9)", 16
DecodeLua("return {a = foo}")                  -> nil, "holds literals only", 13
DecodeLua("{a = 1}")                           -> nil, "must be exactly `return { ... }`", 1
DecodeLua("return 1")                          -> nil, "must return a table literal", 8
DecodeLua("return {a=1} x")                    -> nil, "ends after its table", 14
DecodeLua("return {x = \"\\27\"}")             -> byte 27 decoded
DecodeLua("-- c\nreturn {a = [[long]]}")       -> "long"   (comments and long brackets admitted)
32 nested tables                               -> accepted
33 nested tables                               -> refused
```

The `cosmos.zip` of that release is 8,507,086 bytes, sha256
`eae5513bc5283b684e51e6524080985505836f76c5a398f0c8c5ee68cedde380`
(`curl -sSL <url> | sha256sum`), which is the sha the pin needs.

**Grammar parity holds on the cases that could have diverged.** Both
readers cap at 32 tables, admit comments and long-bracket strings,
refuse a repeated key by default, refuse a non-literal expression, and
refuse the two escapes worth checking: `\e` (the fork extension
`cosmo.EncodeLua` writes and neither reader admits) and `\z`, which
real `load` accepts and BOTH refuse — measured side by side on
`return {a = "x\z\ny"}`, C answering `unterminated string` and the
Teal reader `literal:1: unterminated string`.

**The three differences that decide the design:**

1. the C parser has no `on_duplicate` hook — it refuses a repeat,
   full stop;
2. its refusals are a bare message plus a 1-based BYTE OFFSET, with
   no file label and no line number, where every cosmic caller reads
   `<file>:<line>: <detail>`;
3. it takes no options at all.

**Callers, so none is discovered at implementation time.** Every use
of the reader outside `cosmic/`:

```
_tool/floor.tl:39,66             committed ratchet floors
cmd/cosmic/embed_gen.tl:306,347  the version and cosmos pins
_make/patch.tl:73                the tl patch file
_make/pin.tl:64                  every *_pin.tl
_make/pins_test.tl:34,128        the pin tests
_eval/stage.tl:110               the eval suite
_fuzz/literal_fuzz_test.tl:324,355,387  the fuzz properties
```

Exactly one of them passes `on_duplicate`:
`_tool/coverage/baseline.tl:182-192`, through `_tool/floor.tl`. That
is the whole population the duplicate-key question touches.

```facts
$ wc -l < cosmic/literal.tl
441
$ wc -l < cosmic/literal_test.tl
453
$ wc -l < cosmic/_literal_lex.tl
163
$ grep -c DecodeLua cosmic/literal.tl
0
$ grep -c engine cosmic/literal.tl
0
$ grep -c 2026.08.21-07fc94a1c 3p/cosmos/cosmos_pin.tl
1
$ ls _perf/bench/ | grep -c literal
0
$ ls cosmic/ | grep -c literal_engine_test
0
```

### The five questions, settled

**1. Where the switch lives.** Inside `parse`, and nowhere else.
`parse` uses the C reader when the binding is present AND no
`on_duplicate` was supplied; otherwise the Teal reader. `Options`
gains one field, `engine`, so a caller can pin an implementation:
`"auto"` (the default and what every existing caller gets), `"teal"`,
or `"c"`. The field earns its place by being what makes the
differential property possible at all — `_fuzz/` cannot require
`cosmic._literal_lex` (no module outside `cosmic/` requires a
`cosmic._*` module today, and AGENTS.md forbids it), so holding both
readers in one process needs a door on the public module. It is also
the revert path if the C reader is ever wrong in the field.

**2. Error-string parity.** Not solved in C and not reformatted in
the wrapper: on ANY refusal from the C reader, `parse` DISCARDS the C
message and re-parses the same source with the Teal reader, returning
that reader's message. Today's strings are then byte-identical by
construction, `cosmic/literal_test.tl`'s pinned messages do not move,
and no message exists in two languages. The cost is stated: a refused
input is parsed twice. Refusals are the rare path, nothing measures
them, and the alternative is a second copy of every message.

**3. Duplicate-key policy.** `on_duplicate` present ⇒ Teal reader,
always, because the C parser cannot resolve a repeat. `_tool/floor.tl`
and `_tool/coverage/baseline.tl` are untouched and keep working. With
`on_duplicate` absent both readers refuse a repeat, and the message
comes from the Teal re-parse per question 2, so the refusal is
identical either way.

**4. The bootstrap.** The dispatch reads the binding once at module
load (`local decode_lua = cosmo.DecodeLua`) and falls back to the Teal
reader when it is nil, so a cosmic built against an older cosmos
degrades instead of crashing. A cold clone is safe for a second
reason worth writing down: `bin/cosmic` on a cold start is the PINNED
cosmic release, carrying its own older embedded `literal.lua`, and it
is that binary which reads `cosmos_pin.tl` to fetch the new cosmos —
the new dispatch is not on the bootstrap path at all. The presence
check covers the case a cosmos pin is rolled back without reverting
the source.

**5. How the win is reported.** Scouting numbers in the PR
description, not a gate. `_perf/bench/` has no literal scenario (fact
above), and adding one is a separate slice — filed as its own board
item — because it is the instrument, not the adoption. The PR reports
the method and the numbers as scouting, and says so in those words, so
nobody reads them as a ratchet.

## Change

Four files.

**1. `3p/cosmos/cosmos_pin.tl`** — `version` to
`2026.08.24-354c17e08` and the `*` platform `sha` to
`eae5513bc5283b684e51e6524080985505836f76c5a398f0c8c5ee68cedde380`
(both measured above). Nothing else in the file moves.

**2. `cosmic/literal.tl`** (+~35 lines; 441 today, 59 under the cap,
so the file stays under 490 — an Acceptance bound below) —

- bind the C entry point once at module scope, beside the existing
  `cosmo` require: `local decode_lua = cosmo.DecodeLua`, with a doc
  comment saying it may be nil under an older cosmos and what happens
  then;
- add `engine: string` to the `Options` record, documented in the
  record's own comment style as `"auto"` (default), `"teal"`, `"c"`,
  and add it to `parse`'s `@param` line beside `file`, `noun` and
  `on_duplicate`;
- in `parse`, before the lexer runs: choose the C reader when
  `engine` is `"auto"` and `decode_lua` is non-nil and `on_duplicate`
  is nil, or when `engine` is `"c"`; choose the Teal reader
  otherwise. `engine = "c"` with `decode_lua` nil returns
  `nil, "<file>: the C literal reader is not in this build"` — a
  refusal, never a silent fallback, because a caller that pinned an
  implementation asked to know. `engine` set to anything but those
  three strings returns a refusal naming the three, in the shape
  `format`'s layout refusal already uses
  (`cosmic/_literal_format.tl`'s `a layout is "pin" or "compact",
  not "..."`);
- the C path calls `decode_lua(source)`; on a table it returns it; on
  a refusal it DISCARDS the C message and offset and returns the
  result of the Teal reader on the same source, which is where the
  message comes from (question 2).

**3. `cosmic/literal_engine_test.tl`** (new, ≤ 120 lines) — the
dispatch's own tests, in a new file rather than in
`cosmic/literal_test.tl`, which is 453 lines and has no room. Each
`test_*` called on the line after its `end`. Cover:
`engine = "c"` and `engine = "teal"` return equal values for a nested
payload; a refusal under `"c"` has the same message, byte for byte, as
the same refusal under `"teal"` (a non-literal expression, a repeated
key, junk after the table, a missing `return`), including the `<file>:`
prefix a `file` option sets; `on_duplicate` still resolves a repeat
under `"auto"`; an unknown `engine` string is refused and the message
names the three.

**4. `_fuzz/literal_fuzz_test.tl`** — one new property,
`differential`, in the file's established property shape: every
generated source is parsed by BOTH engines and the two results
compared — value against value with the file's existing deep
comparison, refusal against refusal by message equality. Do not widen
the alphabet, the iteration count, or the generators.

The PR description carries the scouting numbers from question 5,
labelled as scouting: the wall time of 10,000 `literal.parse` calls
over the text of `3p/cosmos/cosmos_pin.tl` under `engine = "teal"` and
under `engine = "c"`, timed with `cosmic.time` through `bin/cosmic
--make run`, best of five runs each, with the script inlined in the
description so the number can be re-taken.

## Non-goals

- **Do not change the grammar.** Not one value more or less than
  `parse` reads today, in either implementation. The parity table in
  Evidence is the contract, and the differential property is what
  holds it.
- **Do not delete or bypass the Teal reader.** It is the reference the
  differential property compares against, the resolver `on_duplicate`
  needs, and the source of every refusal message.
- **Do not touch `whilp/cosmopolitan`.** `cosmo.DecodeLua`'s messages,
  offsets and return shape are a frozen C boundary; if one is wrong,
  that is a separate item in that repo, not a patch inside this one.
- **Do not change `format`, `format_file`, or `cosmic/_literal_format.tl`.**
  The writer half is not in this item.
- **Do not change any existing refusal message, the `<file>:<line>:`
  shape, or `parse`/`parse_file`'s return shapes.**
  `cosmic/literal_test.tl` pins many of these and must pass unedited.
- **Do not edit `_tool/floor.tl`, `_tool/coverage/baseline.tl`, or any
  caller listed in Evidence.** Adoption that needed a caller edit
  would not be adoption behind the existing contract.
- **Do not add a `_perf` scenario here**, and do not gate on the
  compare. Question 5 settled that as its own item.
- **Do not bump the cosmos pin for anything else** in the same PR: a
  pin bump carrying an unrelated change cannot be reverted for this
  one.

## Acceptance

Every command runs verbatim from the repo root and writes no committed
file.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/literal_engine_test.tl` passes.
- `bin/cosmic --make test cosmic/literal_test.tl` passes with that
  file unedited (`git diff --stat cosmic/literal_test.tl` is empty).
- `FUZZ_ITERS=5000 FUZZ_SEED=1 bin/cosmic --make test
  _fuzz/literal_fuzz_test.tl` passes, including the new `differential`
  property.
- From a tree with no `o/`: `bin/cosmic --make clean && bin/cosmic
  --make fetch && bin/cosmic --make build` ends `build: PASS` — the
  bootstrap question, run rather than argued.
- `grep -c 2026.08.24-354c17e08 3p/cosmos/cosmos_pin.tl` is 1 (0 at
  `a2937536`) and `grep -c 2026.08.21-07fc94a1c
  3p/cosmos/cosmos_pin.tl` is 0 (1 at `a2937536`).
- `grep -c DecodeLua cosmic/literal.tl` is ≥ 1 (0 at `a2937536`).
- `wc -l cosmic/literal.tl` is ≤ 490 (441 at `a2937536`).
- `wc -l cosmic/literal_engine_test.tl` is ≤ 120 (the file does not
  exist at `a2937536`).

## Enablement

Both original blockers have landed — the C parser is in
`whilp/cosmopolitan` `354c17e0` and in release
`2026.08.24-354c17e08`, and the fuzz properties are in
`_fuzz/literal_fuzz_test.tl`. One landing-order blocker remains and is
recorded in `blocked_by`: `3IKgKs34` is in `check` on PR #1361 and
edits `_fuzz/literal_fuzz_test.tl`, the same file this slice's
differential property lands in. It is ordinary landing order, not
enablement debt. Nothing else is needed: the C contract was measured
against the shipped release rather than read off an annotation, the
caller population is enumerated above, and the three design questions
that could have been improvised are settled in Evidence.
