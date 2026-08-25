## Goal

G3 — an honest type layer. `docs/design/nil-flow.md` censused 359
unguarded `T | nil` sinks and found that **100 of them are guarded
already** — the author wrote a correct guard and the checker does not
credit it. This slice teaches the checker the four guards it ignores,
which removes those 100 sites from the census without touching one
line of the tree they are in, and cuts the strict-mode slice's real
cost by 28% before it is ever attempted.

Each of the four is a strictly-better inference: it makes the checker
accept MORE correct programs, and no program that compiles today stops
compiling. That is the shape the census recommends proposing upstream
(`docs/design/nil-flow.md`, `## Upstream or carried patch`).

## Change

Four narrowing behaviours, added as edit keys in
`3p/tl/tl_patch.tl` beside the five that are there
(`narrow-assert-decl`, `narrow-truthiness`, `narrow-and-operand`,
`narrow-assert`, `narrow-eq-nil`), applied by `_make/patch.tl` against
the pinned `tl` 0.24.8. Each edit needs its `-tl-tl` twin if it lands
in code that `tl.tl` also carries, and each anchor must match exactly
once.

1. **A branch that cannot fall through terminates, not just `return`.**
   `if not x then break end` must narrow `x` after the guard, as
   `return` already does. Same for `goto <label>`, `error(...)` and
   `os.exit(...)`. 25 census sites; `_docs/publish.tl` 4,
   `cosmic/fs/tree.tl` 2.
2. **`a or b` is non-nil when `b` is.** `fs.read(p) or ""` must type as
   `string`, not `string | nil`. 55 sites; `_tool/testrun_test.tl` 8,
   `cosmic/codec_test.tl` 6. Leave the both-operands-are-unions case
   (`out or qerr`) alone: it stays a union, correctly.
3. **A disjunctive guard distributes.** `if x == nil or x == "" then
   return end` must narrow `x` in the fall-through branch, because
   every arm of an `or` guard is false there. 12 sites.
4. **`and`-operand argument position.** `narrow-and-operand` already
   narrows `x and x.field` and `x and #x`; extend it to the whole right
   operand, so `x and f(x)` narrows too. 8 sites.

Then delete the four probe programs' worth of doctrine that described
these as gaps, and add one test per behaviour to
`cosmic/teal_narrowing_test.tl` alongside the existing narrowing tests.

## Non-goals

- **No strict mode.** This slice does not make any sink refuse a nil
  union. `test_nil_union_is_admitted_outside_an_index` must still pass
  unchanged — the four positions it pins still admit a union after this
  lands, because none of its five sinks carries a guard.
- **Do not bump the `tl` pin.** 0.24.8; the anchors are matched against
  it.
- **Do not fix a census site.** Every site this removes, it removes by
  the checker learning something, never by an edit at the site. A diff
  that touches `cosmic/fs/tree.tl` or `_tool/testrun_test.tl` is out of
  scope.
- **Do not open the upstream PRs here.** Land the carried patch first;
  proposing them to teal-language/tl is separate work with its own
  review.
- **Do not rewrite `docs/design/nil-flow.md`'s totals.** It is dated
  against `e7ac1580`; a later census re-derives it.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/teal_narrowing_test.tl` ends
  `test: PASS`, with four more `test_*` functions than today.
- `grep -o '^  \["[a-z0-9-]*"\]' 3p/tl/tl_patch.tl | wc -l` reports at
  least `15` (today `11`).
- Re-running the census's Method (`docs/design/nil-flow.md`,
  `## Method`) over the tree reports **at most 259** sites, down from
  359. State the number reached in the PR; the 100-site delta is the
  contract, and a shortfall names which of the four did not land.
- `bin/cosmic --make fetch && bin/cosmic --make build` succeeds from a
  clean `o/`, proving every anchor still matches the pin exactly once.

## Enablement

none needed. `_make/patch.tl` is the mechanism and carries 11 edits
already; `3p/tl/tl_patch.tl`'s header documents the anchor rules. The
four probes that pin each behaviour are quoted in
`docs/design/nil-flow.md`'s class sections and can be copied into the
narrowing test verbatim.
