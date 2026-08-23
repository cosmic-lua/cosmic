## Goal

G6 — the defining paths, ratcheted. The cosmic half of the parent
hypothesis (`3IK8E4XF`): once a C literal parser exists in the fork,
adopt it behind `cosmic.literal.parse` without giving up anything the
pure-Teal reader guarantees, and show the win with the harness rather
than with a scouting loop.

**This item is in `plan`, not ready**, and it cannot become ready
before its blocker lands: the binding it adopts does not exist yet,
and the pin that carries it does not exist yet either.

## Evidence

Measured 2026-08-23 on `whilp/cosmic` at `main` `30ab0ce3`.

**What adoption touches.** `cosmic/literal.tl` is 402 lines (98 under
the cap; PR #1346, in review, adds ~39 to it) and
`cosmic/_literal_lex.tl` is 163. The pin to bump is
`3p/cosmos/cosmos_pin.tl` — version `2026.08.21-07fc94a1c` today —
and `cosmic --make fetch` reads that pin THROUGH `cosmic.literal`
itself, which is the one fact that makes this adoption unlike any
other: the reader being replaced is on the path that resolves its own
dependency.

**Callers of the reader outside the module**, so none is discovered at
implementation time:

```
$ grep -rn "literal\.parse" --include='*.tl' . | grep -v '^./cosmic/\|^./o/'
_tool/floor.tl:39,66          committed ratchet floors (on_duplicate)
cmd/cosmic/embed_gen.tl:306,347  the version and cosmos pins
_make/patch.tl:73             the tl patch file
_make/pin.tl:64               every *_pin.tl
_make/pins_test.tl:34,128     the pin tests
_eval/stage.tl:110            the eval suite
```

`_tool/coverage/baseline.tl` is the second `on_duplicate` caller named
by the parent research.

**The measurement instrument.** `_perf` has no literal scenario today
(`ls _perf/bench/`), which is why the parent's numbers are scouting
numbers and why they cannot accept or reject anything. Either this
item adds one, or the win is reported as scouting and the gate stays
silent — that is a decision for the refinement, and the `optimize`
skill's loop is what settles how it is measured.

## Change

Open questions the refinement must settle:

1. **Where the switch lives.** `parse` dispatching to the C parser
   with the Teal parser kept as a reference implementation — reachable
   how? An option, an env var for differential runs, or dead-but-built
   code the fuzz property calls directly?
2. **Error-string parity.** Every caller above reads a refusal message
   for humans, and `_make/pin.tl` labels its own noun. Are the C
   parser's messages made byte-identical to today's, or is the
   wrapper's job to reformat them? `cosmic/literal_test.tl` (421
   lines) pins many of these strings and is the measure of how much
   moves.
3. **Duplicate-key policy.** Whatever the C side settled becomes a
   wrapper problem for `_tool/floor.tl` and
   `_tool/coverage/baseline.tl`, whose `on_duplicate` callbacks
   resolve a repeat rather than refuse it.
4. **The bootstrap question.** `--make fetch` reads the cosmos pin
   with `literal.parse` before the new cosmos is on disk. Confirm the
   dispatch degrades to the Teal reader when the binding is absent,
   and that a cold clone still fetches.
5. **How the win is reported** — a `_perf` scenario, or scouting
   numbers stated as such.

The differential property is the part that is NOT open: the sibling
fuzz item leaves `_fuzz/literal_fuzz_test.tl` behind, and adoption
extends it so every generated input is parsed by BOTH implementations
and the results compared — value against value, refusal against
refusal. That is the correctness bar the parent asked for
("byte-equivalent to `literal.parse` on the full fuzz corpus, incl.
refusals"), and it is why this item is blocked by the fuzz slice as
well as by the C one.

## Non-goals

- **Do not change the grammar.** Not one value more or less than
  `parse` reads today, in either implementation.
- **Do not delete the Teal reader.** It is the reference the
  differential property compares against, and the fallback the
  bootstrap question above may require.
- **Do not change `format`/`format_file`.** The writer half is not in
  this item.
- **Do not bump the cosmos pin for anything else** in the same PR: a
  pin bump that carries an unrelated change cannot be reverted for
  this one.

## Acceptance

To be written when the questions above are settled. The floor:
`bin/cosmic --make ci` ending `ci: PASS`, the differential fuzz
property passing at a stated iteration count, and `bin/cosmic --make
fetch` working from a tree with no `o/`.

## Enablement

Blocked twice over, both recorded as `blocked_by`: the C parser item
(nothing to adopt until it lands AND ships in a cosmos release) and
the literal fuzz item (no differential harness to extend until it
lands). Neither is enablement debt — they are ordinary landing order.
