# Decomposing an outcome

an outcome root in `docs/goals.md` never carries work itself: it is
worked by the items filed under it, and intake (`gitboard next`,
`_work/intake.tl`) offers the highest-placed open root with no live
work as the thing to decompose next. two parts of that procedure are
recorded here, because they are what moves an outcome from "worked"
to "held" and back: the VERIFICATION item, and what a held root does
at intake. everything else — the spec bar, `take`, review, landing —
is the same for these items as for any other, and `gitboard help
<topic>` serves it.

## the VERIFICATION item

a claim that an outcome's win condition holds is itself a slice of
work, filed under the root like any other:

```bash
gitboard new "<title>" --parent <root-id> --spec-file <spec.md>
```

its spec has the ordinary sections, with the content fixed by the
outcome it verifies:

- `## Change` runs every `measured by:` command `docs/goals.md` names
  for that outcome, against the current tree, and quotes the actual
  output — the numbers, the verdict lines, the table — so the PR
  carries the evidence, not a summary of it.
- `## Acceptance` is the outcome's `win condition:` line, quoted
  verbatim from goals.md. nothing weaker, nothing paraphrased: the
  bar being judged is the one the goals file states.

it is pulled, built, and reviewed exactly like any other slice — the
spec bar at `take`, a PR joined to the item by its `Board:` line, a
fresh-context review before it lands — with no special-casing, which
is the point: the session that did the goal's own work is never the
one judging whether the claim holds. a review that finds the quoted
output short of the win condition rejects the item the same way it
rejects any PR that misses its acceptance.

## a held root at intake

once the VERIFICATION item is accepted and merged, a session marks
the root held:

```bash
gitboard hold <root-id> --reason '<why the win condition holds>'
```

`hold` refuses on a non-root (only an outcome's win condition holds),
a done item (a finished root is not held), an already-held one, and a
blank reason; the reason rides in the commit subject and the verdict
line, so the board's log is the record. the marker is `is_held` on
the item — distinct from `resolution`, which is what `done` means.

a held root stays OPEN. `gitboard show` (bare, the board-wide status)
and `gitboard show <root-id>` still find it, it keeps every `beats`
edge and its place in the derived order, and every gate treats it as
the open root it is. what changes is intake alone: `_work/intake.tl`'s
walk over `flow.roots` skips a held root exactly as it skips one with
live work, so intake moves to the next-ranked open root with no hand
edit to goals.md and no re-rank. the goals file records the hold in
its `## Holding` section.

filing or attaching a new item under a held root — fresh evidence
that the win condition slipped — clears the hold in the same commit
as the child (`gate.containered`, the hook that already clears a
parent's claim and reviewer when it gains a child), so the outcome is
live again automatically and intake offers it once its new work is
done. that is the normal reopen path. `gitboard unhold <root-id>` is
the correction for an erroneous hold with no new child to file —
never the way an outcome with real evidence against it reopens.
