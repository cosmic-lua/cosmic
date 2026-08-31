## Change

Write a decision record that bounds D10 (`docs/decisions/d10-right-to-break.md`)
with a stated compatibility commitment for the `cosmic.*` standard library, using
the `decide` skill's form and H1 grammar.

D10 currently reserves the right to break. That is the correct posture for a
distribution whose only consumers are its own tree and its own users' scripts,
because every break lands on code that can be re-checked by `bin/cosmic --make ci`.
It stops being correct the moment cosmic modules are distributed between projects:
a break then lands in a dependency the breaker does not own, in a build the breaker
never runs.

The record settles, at minimum:

- What the commitment covers. `cosmic.*` module surfaces are the candidate; `cosmo.*`
  is already frozen at the C boundary by the cosmopolitan fork's own conventions, and
  `_`-prefixed trees are internal by position and cannot be covered.
- What a compatible change is, in terms the type checker can decide: added optional
  fields and new modules versus changed return shapes, removed functions, and the
  `T | nil, string` fallible contracts in `docs/stdlib.md`.
- The version line that carries it. Releases are tagged `YYYY.MM.DD-<short-sha>`
  today (`release.yml`), which encodes no compatibility information at all. A
  commitment needs a number a consumer can compare, or an explicitly stated
  "compatible until announced" window.
- How a break is announced and how long the overlap is.
- Whether the commitment is enforced by a gate. An API-surface ratchet over
  `cosmic/**` public modules is the mechanism this repo would reach for
  (`_build/` holds the existing ratchets); decide whether it is in scope here or
  its own item.

Amend or supersede per the `decide` skill's rule — this bounds D10's scope rather
than reversing it, so amendment is the likely shape, but that is the record's call.

## Non-goals

- No API changes. This item produces a decision record, not a stdlib edit.
- No package system. That is the item this one blocks.
