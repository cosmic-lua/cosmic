## Goal

G3 — an honest type layer, no escape hatches. This is the parent
outcome's endgame: make the checker DEMAND narrowing at every non-nil
sink, not only at an index, so a `| nil` annotation stops being "a
contract with the reader that the checker only half enforces"
(`docs/guides/checking.md:236`).

`docs/design/nil-flow.md` measured the cost — 359 sites at
`e7ac1580` — and, crucially, measured how it falls: 100 sites are
guards the checker does not credit, and disappear when the narrowing
rules land, so this slice's real cost is whatever the sibling slices
leave behind. Run it LAST.

## Change

Carry the strict mode as a sixth group in `3p/tl/tl_patch.tl`. The
census's `## Method` names the two hinges and the exact prototype that
closed them:

1. `subtype_relations["union"]["*"]` and `["union"]["nominal"]` reject a
   nil-carrying union against a sink that does not admit nil. Leave
   `subtype_relations["nil"]["*"] = compare_true` alone, so bare `nil`
   stays a subtype of everything and `local x: string = nil` and every
   `x == nil` comparison keep working — the prototype confirmed that
   flipping THAT relation instead produces false positives on every
   equality guard in the tree.
2. The binary-operator path reports an operand carrying nil before
   `unite()` drops it, for the arithmetic, bitwise, concatenation and
   relational operators.

Then: flip `cosmic/teal_narrowing_test.tl`'s
`test_nil_union_is_admitted_outside_an_index` to its opposite — the
boundary moves, so the test that pins it moves with it, in this slice
and no other — and collect the doctrine dividend the census priced:

- `AGENTS.md:180-184`, the "what the checker never DEMANDS" sentence,
  deleted outright.
- `docs/guides/checking.md:198-240`, `### Where Narrowing Is Required`,
  rewritten to one sentence: a guard is required wherever a union
  reaches a non-union sink. Its current snippet's stated point is that
  it "compiles at full strictness", which stops being true here.

Whether this ALSO goes to teal-language/tl: the census recommends not.
It rejects programs that compile today, so it is a mode or a fork's
policy, and proposing it beside the four strictly-better narrowing
rules would sink both.

## Non-goals

- **Do not land this before the narrowing rules.** They remove 100
  sites, and every one of them would otherwise be closed by an
  unnecessary edit at the site.
- **Do not weaken it to fit.** A strict mode with an exemption list is
  the escape hatch G3 exists to remove. If a class genuinely cannot be
  closed, it is a census finding and a sibling slice, not a carve-out.
- **Do not bump the `tl` pin to dodge an anchor.**
- **Do not touch `whilp/cosmopolitan`.**

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS` — which is the whole point:
  the tree compiles under the strict checker.
- `bin/cosmic --make test cosmic/teal_narrowing_test.tl` ends
  `test: PASS`, with the admitting test replaced by its refusing twin.
- `bin/cosmic --make fetch && bin/cosmic --make build` from a clean `o/`
  succeeds, proving every anchor matches the pin exactly once — and
  note that a strict `o/bin/cosmic` cannot compile the tree until the
  tree is clean, so the bootstrap order the census documents applies.
- `awk '/^### Error Handling Patterns/,/^## Build System/' AGENTS.md |
  wc -l` reports at least 5 fewer than today's 92, and
  `wc -l docs/guides/checking.md` at least 40 fewer than today's 380.

## Enablement

Blocked on the narrowing-rule slice and the sweep slices; the census
(`docs/design/nil-flow.md`) is the enabling document and its `## Method`
is a working recipe for the patch. Record the `blocked_by` edges when
the siblings are placed.
