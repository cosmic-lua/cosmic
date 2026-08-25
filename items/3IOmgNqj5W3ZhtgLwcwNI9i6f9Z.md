## Goal
G3 — an honest type layer. This item's parent is "casts: close the 55
any-map field walk from-any sites", and this is its `cosmic.deep`
slice: 13 of the 55, closed by one signature change rather than by
declaring any record.

## Evidence

Measured 2026-08-25 against `dbca9e77` with
`grep -n -- "-- cast: " <file>`:

| file | any-map sites | file lines |
| --- | --- | --- |
| `cosmic/deep_test.tl` | 8 | 140 |
| `cosmic/deep_example.tl` | 5 | 49 |
| `cosmic/deep.tl` | 0 | 132 |

Every one of the 13 is a read off a value `cosmic.deep` handed back as
`any`. `copy` is declared `function(value: any): any`
(`cosmic/deep.tl:49`), so `deep.copy(orig)` is `any` and the caller
casts once to index it and again for each level below — 
`cosmic/deep_test.tl:8` and `:10` are the same value read twice, and
`cosmic/deep_example.tl:18-19` spends two casts on one `print`.

**The shape is the caller's, not a record.** Unlike the box slice,
nothing here is waiting for a record to be written: `deep.copy` returns
a copy of what it was given, so the honest type is the INPUT's type. A
generic `copy<T>(value: T): T` says exactly that, and every call site
then reads the type the caller already had. The same question applies
to `merge`, which the test reads through at
`cosmic/deep_test.tl:128-130`.

## Direction, not a decision

The open questions a refinement pass must settle before this is ready:

- Whether `copy<T>(value: T): T` type-checks against the pinned Teal
  under `--check types` for every existing call, including the
  `{any: any}` read at `cosmic/deep_test.tl:47` and calls that pass a
  scalar. The generic must be verified on a scratch file and the
  result written into the spec with its command, not assumed —
  `copy_impl` is internally `any`-typed and the boundary is where the
  claim has to hold.
- Whether `merge` and `equal` take the same treatment. `equal` returns
  `boolean` and costs no caller casts, so it may be out of scope;
  `merge` returns `any` and does cost them.
- Whether `cosmic/deep.tl` gains any cast of its own at the boundary
  where the generic meets `copy_impl`. A slice that trades 13 caller
  casts for 1 internal cast is still a win, but the number belongs in
  Acceptance as a `grep -c` bound, not in prose.

## What this must not do

The semantics are frozen in the module doc comment
(`cosmic/deep.tl:15-23`) and must not move: copy copies table keys as
well as values, shared references stay shared within one copy, cycles
terminate, metatables are not copied, `equal` matches table-valued
keys by identity rather than structure, and `merge` recurses only
where both sides hold tables so lists merge by index. This slice
changes types, not behaviour.

`cosmic.deep` is public API, so a signature change may move
`_build/public_surface_baseline.tl`. The closure diff lowers the
affected rows in `_build/casts_baseline.tl` and updates the per-file
table in `docs/design/casts.md`. Run exactly the regen command the
gate's failure message prints and commit the result; no gate is
weakened any other way.
