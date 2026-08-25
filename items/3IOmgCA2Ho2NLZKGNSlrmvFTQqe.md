## Goal
G3 — an honest type layer. This item's parent is "casts: close the 55
any-map field walk from-any sites", and this is its box-configuration
slice: 20 of the 55, the largest single shape and the one whose record
already exists.

## Evidence

Measured 2026-08-25 against `dbca9e77` with
`grep -n -- "-- cast: " <file>`:

| file | any-map sites | file lines |
| --- | --- | --- |
| `cosmic/quicksand/box/merge.tl` | 4 | 140 |
| `cosmic/quicksand/box/merge_test.tl` | 14 | 153 |
| `cosmic/quicksand/box/init_test.tl` | 2 (of 9 `from any` in the file) | 139 |

`cosmic/quicksand/box/init_test.tl` carries 9 `-- cast: from any`
lines; only lines 118-121 belong to this class. The other 7 are
`deliberate invalid input` probes and error-string narrowing, which
belong to sibling classes of the census and are NOT this slice's work.

**The record already exists.** `record BoxOptions` is declared at
`cosmic/quicksand/types.tl:82` and is what `Box.new`, `validate` and
`preflight` already take (`cosmic/quicksand/box/init.tl:57`, `:130`).
What is untyped is the merge path: `merge` is declared
`function(...: {string: any}): {string: any}`
(`cosmic/quicksand/box/merge.tl:117`), so every field a caller reads
off a merged policy is an index into `any`. That is where all 14
`merge_test.tl` sites and both `init_test.tl` sites come from — e.g.
`cosmic/quicksand/box/merge_test.tl:22`, which spends two casts on one
line reading `out.fs.ro`.

The 4 sites inside `merge.tl` itself are a different problem from the
16 in the tests. `merge_section` is a generic dotted-path walk driven
by the `schema` table (lists, maps, scalars, unknown keys defaulting to
scalar), so it is dynamic ON PURPOSE — the module doc comment states
that unknown keys are treated as scalars "which is the right default
for forward-compatible additions". A slice that types `merge` over
`BoxOptions` closes the 16 caller sites; whether the 4 internal ones
become `is {string: any}` dispatch or stay as justified casts is a
decision this item must settle before it is ready, not one to leave to
the implementing session.

## Direction, not a decision

Type the merge boundary so callers read declared fields. The open
questions a refinement pass must settle:

- Does `merge` return `BoxOptions`, or does the box configuration get
  its own `Policy` record separate from the constructor's options?
  `BoxOptions` is what `Box.new` consumes, which argues for reuse.
- What happens to the 4 internal sites in `merge_section`. Note the
  module's forward-compatibility promise: a change that makes unknown
  keys a type error would break a stated contract and belongs in
  `Non-goals` unless deliberately reopened.
- `merge` is a public-surface function reached through
  `cosmic.quicksand`; check whether a signature change moves
  `_build/public_surface_baseline.tl`.

## What this must not do

The merge semantics are frozen: scalar-later-wins, list concat with
first-seen dedup, map shallow per-key merge, and the explicit
nil-checked indexing that keeps a stored `false` from collapsing to
nil (`cosmic/quicksand/box/merge.tl:78-86` — the comment there names
the security opt-out it protects). A retype must not touch them.

The closure diff lowers the affected rows in
`_build/casts_baseline.tl` and updates the per-file table in
`docs/design/casts.md`. Run exactly the regen command the gate's
failure message prints and commit the result; no gate is weakened any
other way.
