## Goal

G3 — an honest type layer, no escape hatches. This is the parent
outcome's endgame: make the checker DEMAND narrowing at every non-nil
sink, not only at an index, so a `| nil` annotation stops being "a
contract with the reader that the checker only half enforces"
(`docs/guides/checking.md:262`, re-measured 2026-08-26).

`docs/design/nil-flow.md` measured the cost — 359 sites at
`e7ac1580` — and, crucially, measured how it falls: 100 of those sites
were guards the checker did not credit. **Those 100 are gone**: the
narrow-* patch group has landed (`3p/tl/tl_patch.tl`, 499 lines today,
14 `narrow-*` entries carrying truthiness, `assert` in statement and
expression position, `x and x.field`, `== nil`/`~= nil`,
`break`/`goto`/`error`/`os.exit` block exits, `x or fallback`, and the
two shared helpers). So this slice's remaining cost is whatever the
sibling sweeps leave behind, which is why it is blocked on all four of
them and runs LAST.

## Change

Carry the strict mode as a NEW patch group in `3p/tl/tl_patch.tl`,
beside the two that exist today. Re-measured 2026-08-26: the file's
header comment says "Two groups of edits" and the groups are
`ast-cache-*` (5 entries) and `narrow-*` (14 entries);
`grep -c 'note =' 3p/tl/tl_patch.tl` reports 19 and
`wc -l 3p/tl/tl_patch.tl` reports 499. Name the new group `strictnil-*`
and extend that header comment to describe three groups, the way the
narrow-* paragraph describes its own.

The census's `## Method` names the two hinges and the exact prototype
that closed them:

1. `subtype_relations["union"]["*"]` and `["union"]["nominal"]` reject a
   nil-carrying union against a sink that does not admit nil. Leave
   `subtype_relations["nil"]["*"] = compare_true` alone, so bare `nil`
   stays a subtype of everything and `local x: string = nil` and every
   `x == nil` comparison keep working — the prototype confirmed that
   flipping THAT relation instead produces false positives on every
   equality guard in the tree.
2. The binary-operator path reports an operand carrying nil before
   `unite()` drops it, for the arithmetic, bitwise, concatenation and
   relational operators. `and`, `or`, `==` and `~=` stay excluded: they
   are how a nil is disposed of, not a place it leaks to.

Every entry is an ANCHORED edit like the others — each `find` must match
the pinned `tl.lua` exactly once, so a pin bump fails the fetch loudly
rather than silently dropping the mode.

Then: flip `cosmic/teal_narrowing_test.tl`'s
`test_nil_union_is_admitted_outside_an_index` to its opposite — the
boundary moves, so the test that pins it moves with it, in this slice
and no other — and collect the doctrine dividend the census priced.
Both passages are re-measured 2026-08-26:

- `AGENTS.md:187-190`, the "And what the checker never DEMANDS: an
  unnarrowed `T | nil` passes into a non-nil parameter, a declared
  non-nil local, arithmetic and concatenation — only an index refuses
  it, so an unguarded union becomes a runtime nil downstream (pinned in
  `cosmic/teal_narrowing_test.tl`)" sentence, deleted outright.
  (`grep -n 'never DEMANDS' AGENTS.md` reports line 187; `AGENTS.md` is
  468 lines.)
- `docs/guides/checking.md:224-265`, `### Where Narrowing Is Required`,
  rewritten to one sentence: a guard is required wherever a union
  reaches a non-union sink. Its current 20-line snippet's stated point
  is that it "compiles at full strictness", which stops being true here,
  so the snippet goes with it. (`grep -n '### Where Narrowing Is
  Required' docs/guides/checking.md` reports line 224; the section runs
  to the `### Record Types` heading; the file is 406 lines.)

Whether this ALSO goes to teal-language/tl: the census recommends not.
It rejects programs that compile today, so it is a mode or a fork's
policy, and proposing it beside the four strictly-better narrowing
rules would sink both.

## Non-goals

- **Do not land this before the sibling sweeps.** The four `blocked_by`
  edges are the machine-checked form of that rule; every site they
  close would otherwise be closed by an unnecessary edit at the site.
- **Do not weaken it to fit.** A strict mode with an exemption list is
  the escape hatch G3 exists to remove. If a class genuinely cannot be
  closed, it is a census finding and a sibling slice, not a carve-out.
- **Do not touch `subtype_relations["nil"]["*"]`.** The prototype
  measured what flipping it costs: a false positive on every equality
  guard in the tree.
- **Do not bump the `tl` pin to dodge an anchor.** A moved anchor means
  the patch needs re-auditing, which is the point of carrying it.
- **Do not re-derive the census.** `docs/design/nil-flow.md`'s totals
  are a record of `e7ac1580`, not an input to this slice; `ci: PASS`
  under the strict checker is the only count that matters here.
- **Do not touch `whilp/cosmopolitan`.**

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS` — which is the whole point:
  the tree compiles under the strict checker.
- `bin/cosmic --make test cosmic/teal_narrowing_test.tl` ends
  `test: PASS`, with the admitting test replaced by its refusing twin.
- `bin/cosmic --make clean && bin/cosmic --make fetch && bin/cosmic
  --make build` succeeds from a clean `o/`, proving every anchor matches
  the pin exactly once — and note that a strict `o/bin/cosmic` cannot
  compile the tree until the tree is clean, so the bootstrap order the
  census documents (`docs/design/nil-flow.md`, `## Method`, "The build
  order is itself a result") applies.
- `grep -c 'note =' 3p/tl/tl_patch.tl` reports more than today's `19`,
  and `grep -c 'strictnil-' 3p/tl/tl_patch.tl` reports at least `2` —
  the new group exists and is anchored like the others.
- `grep -c 'never DEMANDS' AGENTS.md` reports `0` (today `1`).
- `awk '/^### Error Handling Patterns/,/^## Build System/' AGENTS.md |
  wc -l` reports at least 4 fewer than today's `102`, and
  `wc -l docs/guides/checking.md` reports at least 20 fewer than today's
  `406`.

## Enablement

The four blockers are recorded as `blocked_by` edges and are the whole
of the enablement: 3IPXQ1Zw (the 179-site `check.must` sweep),
3IPXQuYu (the 109-site library latent-nil sweep), 3IPXQcgW
(`cosmic.time`'s five clock readers) and 3IPktATw
(`cosmo.path.join`'s 26 sites). Nothing else: the narrow-* group has
already landed, `docs/design/nil-flow.md` is the enabling document, its
`## Method` is a working recipe for the patch including the bootstrap
order, and `_make/patch.tl` is the carrying mechanism.
