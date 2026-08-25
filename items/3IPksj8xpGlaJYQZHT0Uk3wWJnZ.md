## Goal

G3 — an honest type layer. `docs/design/nil-flow.md` measured 358
unguarded `T | nil` sinks in the tree and found that **69 of them — 19%
— are not work at all**: they are a narrowing rule tl does not have.
Landing that rule before any site-fixing slice keeps 69 guards from
being written by hand and then unwound.

## Evidence

`x or fallback` cannot be nil when `fallback` is not nil, but tl types
the expression as the left union whole: in the `or` branch of the
binary-operator path, when the right operand is a subtype of the left
union, the result takes the left type unchanged.

The census measured the effect directly. Re-running the same strict
scan with one further prototype edit — drop the nil member from the
left operand's union at the top of the `or` branch, before the
expression's type is inferred — reported **289 errors instead of 358**,
and the 289 are a strict subset:

```text
comm -23 <(sort A.tsv) <(sort B.tsv) | wc -l   ->  69
comm -13 <(sort A.tsv) <(sort B.tsv) | wc -l   ->   0
```

The rule closes sites and creates none. By class the 69 are: 29
`operand`, 23 `argument`, 8 `return`, 5 `assignment`, 2 `table-field`,
1 `table-item`, 1 `or-expected`. The shape is the one every Lua
programmer writes — `_build/size.tl:155` `local cbin = cur.binary_bytes
or 0`, spent at `:162` and still typed `integer | nil`.

`3p/tl/tl_patch.tl` already carries five narrowing edits against pinned
tl 0.24.8 (`grep -n '^-- - narrow-' 3p/tl/tl_patch.tl`); the mechanism
is `_make/patch.tl` (190 lines), which anchors each edit against the
pinned source exactly once.

## Change

Add a sixth narrowing edit, `narrow-or-fallback`, to
`3p/tl/tl_patch.tl`: in tl's `or` handling, when the left operand's
resolved type is a union carrying nil and the right operand is not
`nil`, replace the left type with the union minus its nil member before
the branch chain that infers the expression's type.

Pin the behaviour with a test in `cosmic/teal_narrowing_test.tl`
alongside the existing narrowing tests: `local s: string = f() or ""`
where `f(): string | nil` must type-check, and the negative twin must
still refuse where it should.

Then open the upstream proposal to teal-language/tl carrying the
69-site measurement as evidence — it is soundness-neutral, needs no new
syntax and benefits every Teal user.

## Non-goals

- Do not fix any of the 69 sites by hand; the rule is the fix.
- Do not touch the two strict-mode hinges (`forall_are_subtype_of`,
  `unite`). That is the parent outcome's own work.
- Do not bump the `tl` pin.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c '^-- - narrow-' 3p/tl/tl_patch.tl` reports `6`, and the
  comment above the bullets says "Six edits".
- The new test in `cosmic/teal_narrowing_test.tl` fails when the edit
  key is removed from `3p/tl/tl_patch.tl` and passes with it.
- A note in `docs/design/nil-flow.md` records that the 69 closed; the
  census total and `nil-flow-sites.tsv` are re-derived, not hand-edited.
