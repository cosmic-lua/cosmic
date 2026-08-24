`next` and `move` disagree about who may hand back a rework, and the
disagreement costs a `--force` on a motion that is ordinary flow.

Hit on 2026-08-24 reworking `3IKSjEgW` (whilp/cosmopolitan#274). The
sequence, verbatim:

```
$ gitboard next
gitboard-next: finish 3IKSjEgW ... — do holds 1/5 — finish before
  pulling (rework of 931e78b5-...'s build — hand it back with
  --claim 881222fd-...)

$ gitboard move 3IKSjEgW check --pr 274 --claim 881222fd-...
gitboard-move: REFUSED: 3IKSjEgW is claimed by 931e78b5-... —
  take over a live claim with --force --why
```

`next` names the exact flag and value to use, and `move` refuses that
exact command. Omitting `--claim` (the documented way to derive the
identity from the environment) refuses identically, because the
derived value is the same one.

The refusal is right about claims in general: a live claim should not
be silently stolen, and `3IKSjEgW`'s was hours old, not the 36h the
board marks stale. What it misses is that a `request changes` verdict
already ENDED the builder's claim on the work — the item is in `do`
precisely because it was handed back, and `next` routes that rework to
whoever asks, deliberately, since rework is not a verdict and carries
no review-distance rule. So the takeover is not a takeover: it is the
rework's rightful claimant recording itself.

`--force --why` gets the move through, and that is what this session
did, with the reason recorded. But the `work` skill's hard rules say
`--force` exists for repair rather than flow, and a `--force` in the
log is a repair marker that `docs/flow-review.md`'s method excludes
from organic-flow counts (`a move subject carrying a trailing
(forced: ...) is a repair, not organic flow, and is excluded`). So
every rework handback by a session that did not build the item now
lands in the log as a repair and vanishes from the flow measurement —
the rework signal the review chapter most wants to count is the one
being erased.

Two candidate shapes, whichever the implementer judges cleaner:

- `move ID check` from `do` accepts a new claim without `--force` when
  the item's standing verdict is `request changes` and the recorded
  claim is not the mover's. The verdict is already on the item, so no
  new state is needed to decide it.
- A rework handback re-derives the claim silently, the way a move to
  `do` does, since `verdict ID "request changes"` could have cleared
  the claim when it made the move.

Acceptance: from a board where an item sits in `do` with another
session's claim and a standing `request changes` verdict, `gitboard
move ID check --pr N` succeeds with no flags, records the mover as the
claim, and its commit subject carries no `(forced: ...)`.
