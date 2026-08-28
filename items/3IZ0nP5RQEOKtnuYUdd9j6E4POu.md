## Goal

G3 — honest nil. `_cli/returns.tl` carries a hand-rolled Teal type grammar
(`parse_atom`/`parse_type`/`parse_list`/`params_open`/`skip_balanced`) that two
invariants now depend on: the `fallible-returns` lint and the `nil_return_lines`
ratchet. A shape that grammar mis-reads is silently wrong in both directions —
a missed diagnostic, or a false accusation on correct code — and nothing in the
tree finds those shapes. Both rounds of review on 3IVHXoDw found one by hand:
round 1 a token blacklist (`{function(): T}`, `Box<function(): T>`, a function
type after `,` in a return list), round 2 a lexer artifact (`>>`). The same
wrong turn twice is the trigger for a countermeasure.

## Change

Two confirmed defects, both in the SHARED grammar, both reproduced against
`5978f451`:

1. **`>>` is one token.** `skip_balanced(tokens, i, "<", ">")` never closes a
   nested generic, so `Box<Wrap<integer>>` is not a type to this parser.
   Measured: `local function f(): Box<Wrap<integer>> | nil, string, integer`
   is NOT flagged by `fallible-returns` while the same signature with one
   generic level is; and `local b: Box<Box<function(): string>> = nil` inside a
   body declared `string | nil, string` makes `nil_return_lines` charge the
   honest `return nil, "e"` to a frame no `end` pops. A space between the
   angles makes both correct.

2. **`local type X = record ... end` opens no frame.** `skip_type_alias` hands
   the right-hand side to `parse_type`, which consumes `record` as an
   identifier atom, so the body's `end` pops the enclosing function and every
   later site in it goes unseen — the same class as the `local record` miss
   5978f451 fixed for the other spelling.

Fix both, and then close the class by machine rather than by imagination:
a differential test that generates (or enumerates) Teal type-position shapes
and cross-checks this grammar against tl's own parser — a shape where the two
disagree is a bug in the hand grammar. `_fuzz/` is the tree's existing home for
generated-input gates. Alternative if a differential harness is too big:
`cosmic/format/types.tl` already solves the same type-position problem for the
formatter, and a test asserting the two agree over every committed `.tl` file
plus a fixture corpus is a cheaper version of the same idea.

## Non-goals

- Do not move `_build/nil_returns_baseline.tl` as part of this: neither defect
  reaches a committed file today (verified — the pre-fix and post-fix detectors
  produce byte-identical baselines), so a fix that moves the number means
  something else changed too.

## Acceptance

- The two reproductions above return the correct counts.
- A gate exists that would have failed on either defect before review did.
