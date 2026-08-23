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

**This item is in `plan`, not ready.** What follows is the measured
ground and the decisions still open; the refinement that takes it to
the bar has to settle them and write the `Change` as files and shapes.

## Evidence

Measured 2026-08-23 in `whilp/cosmopolitan` at `0980e033` (`master`).

**Where it lands, and what it sits beside:**

```
$ wc -l tool/net/ljson.c tool/lua/lcosmo.c tool/net/definitions.lua
   649 tool/net/ljson.c
   346 tool/lua/lcosmo.c
  8192 tool/net/definitions.lua
```

`DecodeJson` is registered in `tool/lua/lcosmo.c:222` and implemented
over `DecodeJsonEx` (`:47-73`); `EncodeLua` is registered at `:230`.
The object is wired into two build lists — `tool/net/BUILD.mk:102` and
`tool/lua/BUILD.mk:31` — so a new `tool/net/l<name>.c` needs an entry
in both. Binding tests are `tool/lua/test_*.lua`, run by `make
o//tool/lua/test`, which also runs the annotation-coverage and
return-arity ratchets over `definitions.lua`; AGENTS.md there names
that target as the correctness gate before any PR.

**The contract to reproduce** is `cosmic/literal.tl` (402 lines) plus
`cosmic/_literal_lex.tl` (163) on `whilp/cosmic` at `30ab0ce3`: quoted
and bracketed keys, nested tables, string/number/boolean scalars, Lua
string escapes including `\x`, `\u{…}`, `\z` and decimal, long
strings, comments, a 32-table depth cap, duplicate-key policy
(`on_duplicate`, used by `_tool/floor.tl` and
`_tool/coverage/baseline.tl`), and `nil, "<file>:<line>: <what>"` for
everything else. Never-execute stops being a property of a lexer that
refuses and becomes a property of a parser with no evaluator.

**Prerequisite, now cleared:** the parent recorded that any C A/B here
was unmeasurable while `o//depend` was never generated (header edits
rebuilt nothing). Board item `3IHHJcVr` landed that fix on
2026-08-23 as whilp/cosmopolitan#270, so incremental C measurement in
this tree is sound again.

## Change

Open questions the refinement must settle before this is a slice, in
the order they bite:

1. **Return shape.** `DecodeJson` returns value-or-`nil, err`. Does
   the literal parser return the same, and how does the line number
   reach the message so `cosmic.literal`'s existing error strings can
   be reproduced (`<file>:<line>: <what>`) without the wrapper
   re-deriving them?
2. **Duplicate keys.** `on_duplicate` is a Lua callback in the Teal
   reader with two real callers. A C parser either takes a policy flag
   (refuse/first/last), collects duplicates for the wrapper to
   resolve, or calls back into Lua. Pick one and say why.
3. **Depth cap.** 32 today, enforced by the recursive-descent parser
   in Teal. Is it a compile-time constant in C, an option, or read
   from the caller?
4. **What is out of grammar.** The Teal reader refuses array-style
   tables, non-string keys, and anything that is not a value. The C
   parser must refuse the same set, and the spec has to enumerate it
   rather than say "the same".
5. **Size.** `ljson.c` is 649 lines for a smaller grammar. If the
   answer lands well past that, this item is itself two slices (the
   scanner and the parser, or the parser and the duplicate-key
   policy), and the refinement should cut it rather than hand over one
   very large C PR.

## Non-goals

- **No cosmic-side change in this item.** The type regen, the wrapper
  and the differential harness are the sibling adoption item; this one
  lands in whilp/cosmopolitan and nothing else.
- **Do not change `DecodeJson`, `EncodeJson`, `EncodeLua` or any
  existing binding's contract.** Return shapes, error values and
  constants at the C boundary are frozen; cosmic's generated types and
  wrappers depend on them.
- **Do not add an evaluator.** No `load`, no chunk compilation, no
  environment. A parser with no evaluator is the point; the parent
  item records `load("return "..s, "t", {})` as measured and
  disqualified (the string metatable survives an empty env, expression
  chunks admit function literals, bare identifiers read `nil`).
- **Keep the fork mergeable.** Surgical diff in `tool/net` plus the
  two BUILD.mk entries and `definitions.lua`; no reformatting, no
  restructuring of neighbouring files.
- **`definitions.lua` moves in the same commit** as the binding, with
  full `@param`/`@return` annotations — the coverage ratchet fails
  otherwise, and that is the gate, not a convention.

## Acceptance

To be written when the questions above are settled. The floor it will
build on, measured today:

- `make -j$(nproc) o//tool/lua/test` exits 0 and ends `PASS`, with the
  definitions-coverage and return-arity ratchets reporting no
  allowlist growth.
- a new `tool/lua/test_<name>.lua` covering the grammar and every
  refusal class the Teal reader has.

## Enablement

`3IHHJcVr` (the `o//depend` fix) was the one blocker and it landed on
2026-08-23. What remains is refinement, not enablement: this item is
in `plan` precisely because the five questions above are decisions,
and a session that implemented it today would be inventing answers to
them.
