## Change

Settle whether cosmic will make any compatibility commitment for its standard
library, and record the answer.

The obstacle is larger than one decision record. API stability is not merely
unpromised — it is a **stated non-goal** in `docs/goals.md`:

```
$ sed -n '/^## Non-goals/,/^- \*\*cross-OS/p' docs/goals.md
## Non-goals

- **adoption.** see mission.
- **API stability.** cosmic keeps a perpetual right to break. releases
  are date-versioned; changelogs note breakage; users pin a release
  binary they trust. honest types make breakage loud, which is the
  point ([D10](decisions/d10-right-to-break.md)).
```

So this is a goals change with a decision record behind it, not a decision record
alone. That posture is correct while every consumer of `cosmic.*` is either this
tree or a user script the user can re-check with `bin/cosmic --make ci`: a break
lands on code its author can rebuild. It stops being correct once cosmic modules
are distributed between projects, because a break then lands in a dependency the
breaker does not own, in a build the breaker never runs.

Two shapes are available, and picking between them is the work:

- **A bounded commitment.** The non-goal stands for the stdlib generally, and the
  commitment covers only the surface a distributed module can depend on — which
  requires that surface to be a named, smaller thing than "all of `cosmic.*`".
- **A general commitment.** The non-goal is replaced by a compatibility promise
  with a version line behind it, and D10 is amended or superseded accordingly.

Whichever is chosen, the record settles:

- What the commitment covers. `cosmo.*` is already frozen at the C boundary by the
  cosmopolitan fork's conventions; `_`-prefixed trees are internal by position and
  cannot be covered; `cosmic.*` public modules are the surface in question, and
  `cosmic/doc/visibility.tl` already decides which those are.
- What a compatible change is, in terms the type checker can decide: added optional
  fields and new modules versus changed return shapes, removed functions, and the
  `T | nil, string` fallible contracts in `docs/stdlib.md`.
- The version line that carries it. Releases are tagged `YYYY.MM.DD-<short-sha>`
  (`release.yml`), which encodes no compatibility information at all. A commitment
  needs either a number a consumer can compare or an explicit "compatible until
  announced" window.
- How a break is announced, and the overlap before it lands.
- Whether a gate enforces it. G9 already commits to "a per-PR ratchet on the public
  module surface (committed baseline of public names)" — if that ratchet exists or
  is planned, the commitment should be defined in terms of it rather than inventing
  a second mechanism. Check its state before specifying one.

Use the `decide` skill for the record's form and the amend-versus-supersede rule.
Amendment is the likely shape for D10 since this bounds its scope rather than
reversing it, but that is the record's call.

## Non-goals

- No API changes. This item produces a decision record and a goals edit, not a
  stdlib edit.
- No package system. That is the item this one blocks.
