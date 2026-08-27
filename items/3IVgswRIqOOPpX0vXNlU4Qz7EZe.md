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

Three confirmed defects in the SHARED grammar. Defects 1 and 2 were
reproduced against `5978f451` and are fixed on whilp/cosmic#1471's head
`844da8a9`; defect 3 was introduced by that fix and is open. Whatever
#1471 lands, the remaining work here is the machine gate below.

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

3. **`opens_body`'s `=` tell fires on a VALUE named `record`.** Found at round
   three, and INTRODUCED by the fix for defect 2: `_cli/nilreturn.tl`'s
   `opens_body` treats any `record`/`enum`/`interface` identifier whose
   previous token is `=` as opening a body, so an export table's
   `record = record` pushes a "fields" frame no `end` ever pops. Measured:
   `cosmic/shape.tl:313` (`record = record,` in the module's export table)
   leaves the walk with a residual frame today — harmless only because no
   `return nil` follows it in that file. Reproduced as a live false positive
   on type-checking source: a local function named `record`, an export table
   binding `record = record` inside a lying function, and a module-scope
   `return nil` below it is counted as a site (`844da8a9` reports 1; the same
   file with the identifier renamed reports 0; `5978f451` reports 0 for both).
   The `=` tell is reading backwards for a fact `skip_type_alias` already
   knows structurally — it lands exactly on the alias's `record` token — so
   the fix is to signal the alias body from that path instead.

Fix all three, and then close the class by machine rather than by imagination:
a differential test that generates (or enumerates) Teal type-position shapes
and cross-checks this grammar against tl's own parser — a shape where the two
disagree is a bug in the hand grammar. `_fuzz/` is the tree's existing home for
generated-input gates. Alternative if a differential harness is too big:
`cosmic/format/types.tl` already solves the same type-position problem for the
formatter, and a test asserting the two agree over every committed `.tl` file
plus a fixture corpus is a cheaper version of the same idea.

**The cheap gate, measured.** A frame-stack RESIDUAL assertion — the walk's
stack must be empty at end of file, and no `end` may arrive on an empty stack
— runs over every committed `.tl` in one pass and finds this class without any
imagination. Verified against all 602 committed `.tl` files: at `844da8a9`
exactly one file is unbalanced (`cosmic/shape.tl`, residual 1 — defect 3
above); at `5978f451` the `>>` reproduction leaves residual 1 (defect 1 would
have been caught); the alias miss (defect 2) is an under-pop, which the
matching half — counting `end`s that arrive with an empty stack — catches.
Both halves are a few lines beside the existing ratchet test and would have
caught round one, round two and round three before a reviewer did. Build this
before, or instead of, the fuller differential against tl's own parser.

## Non-goals

- Do not move `_build/nil_returns_baseline.tl` as part of this: neither defect
  reaches a committed file today (verified — the pre-fix and post-fix detectors
  produce byte-identical baselines), so a fix that moves the number means
  something else changed too.

## Acceptance

- The three reproductions above return the correct counts.
- A gate exists that would have failed on any of the three defects before
  review did; the residual assertion above is the measured minimum.
