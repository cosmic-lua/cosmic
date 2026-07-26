# 046 — `.gen.tl` marks two different unit kinds, split by basename prose

severity: medium (design coherence; the collision is live in the model)
type: design / feature
area: docs/design/make.md units; `_make/project.tl:182`, `_make/artifact.tl`

## observation

the suffix `.gen.tl` denotes two concepts with different scope, runner,
and output semantics:

| | generation unit (`*.gen.tl` in D) | binary payload generator (`embed.gen.tl`) |
|---|---|---|
| scope | D's subtree | the **binary's** scope (root packages + `cmd/<n>/**`) |
| run by | `regen` (planned) | `build`, every time |
| output | `o/D/**` | `o/<unit>/{embed/,base}` |

the model cannot tell them apart: `classify()` returns kind `gen` for
both (`project.tl:182` matches the suffix), and the distinction lives
in prose — make.md says outright "it is not a generation unit" — plus
`artifact.generate_unit` matching the exact basename. the design's own
units section records that this row **falsified the unit table's scope
prediction** ("a binary's payload generator reads the *binary's* scope
rather than its own subtree").

two consequences waiting downstream:

1. a user who writes `cmd/foo/data.gen.tl` (a generation unit inside a
   binary directory — nothing forbids it) gets a file that is kind
   `gen`, compiled, and run by *neither* mechanism today; when `regen`
   lands, its sweep must know to skip `embed.gen.tl` by name or it will
   run the payload generator under generation-unit scope — the wrong
   fence.
2. a user who names their generation unit `embed.gen.tl` because the
   examples do gets binary-generator semantics they did not ask for.

## proposal

pick one of two coherent shapes:

1. **distinct marker** — keep `embed.gen.tl` as a reserved basename,
   but make the model say so: a distinct kind (`payload-gen`) from
   `classify()`, a validator rule for a stray `embed.gen.tl` outside a
   binary unit, and a defined answer for ordinary `*.gen.tl` inside
   `cmd/<n>/` (most likely: a normal generation unit, subtree-scoped).
2. **unify** — a binary's payload generator *is* a generation unit
   whose directory is the binary's; accept subtree scope for it and
   have `build` depend on the unit's output like any other input. this
   restores the falsified table row but changes what the payload
   generator may read (today: the whole binary scope).

option 1 is the smaller change and keeps the measured behavior; either
is better than the basename carve-out living only in prose while the
model sees one kind.
