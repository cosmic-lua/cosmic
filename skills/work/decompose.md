# Decomposing an outcome

an outcome root in `docs/goals.md` never carries work itself: it is
worked by the items filed under it, and intake (`gitboard next`,
`_work/intake.tl`) offers the highest-placed open root with no live
work as the thing to decompose next. three parts of that procedure
are recorded here, because they are what places an outcome and moves
it from "worked" to "held" and back: the paired-comparison tournament
that ranks the outcomes intake reads, the VERIFICATION item, and what
a held root does at intake. everything else — the spec bar, `take`,
review, landing — is the same for these items as for any other, and
`gitboard help <topic>` serves it.

## the paired-comparison tournament

the order intake reads is never asserted: it is derived from
comparisons committed on the board, one per pair asked. a comparison
is `gitboard compare A B` — "A outranks B", recorded as one `beats`
entry on A — and the derived order is the transitive closure over
every such edge (`_work/priority.tl`), so `A beats B` and `B beats
C` settle A against C with nobody asked. age is the last word among
items no comparison separates. an item no edge reaches, at any
height, is unplaced: invisible to every queue and refused by `take`
until it is compared in or attached under a placed outcome.
`gitboard help system` carries that ordering in full and `gitboard
help compare` the verb; this section is the procedure around them.

**the question.** every pair answers one question, always the same
one: "if only one of these could hold, which cosmic is better?"
nothing about effort, readiness, or who is around to build it —
those are the spec bar's and the queue's concerns, and the order is
what they rank within.

**when to run one.** a tournament is asked, never scheduled:

- an outcome enters `docs/goals.md` — a dormant one activates, a new
  one is added — and has no position yet.
- evidence moves against the committed order: a root's distance from
  holding changes, or a session cannot say why the root above it
  should be worked first.
- a captured finding is promoted to a root and needs a place.

it is never run to make an item pullable, and a re-rank that moves
nothing is a fine outcome — the order was right.

**which pairs to ask.** only the contested ones. the closure already
answers every pair reachable through committed edges, and `compare`
refuses a duplicate and a reversal that would close a cycle several
comparisons built (a direct contrary edge is reversed in one
commit). so:

- a new outcome is compared against its neighbours: walk down the
  committed order until it loses once and up until it wins once —
  two or three pairs usually place it.
- a re-rank asks the adjacent pairs of the current order plus every
  pair the new evidence puts in question, and stops when the closure
  is total again.
- the outcome nearest to holding takes a bye: finishing beats
  starting, so it is not debated, only finished.
- a cycle is never averaged away. it means the question was
  ambiguous for that pair; restate the pair and re-ask it.

**who answers.** a comparison that would put NEW work above existing
work belongs to the goal owner — it answers "which is the better
cosmic", and that is not the session's call. post the pair (in chat,
or in the session's report when nobody is watching) and keep
working; the answer lands as a `compare` whenever it arrives. when
nobody is around to rank a new item, attach it under the
lowest-placed outcome it plausibly serves and say so, so the item is
placed today and the comparison can still be asked later.

**how the result lands.** each answer is one commit on the board
branch, `gitboard compare WINNER LOSER`, and every rendered order
derives from it at once — no ranking is written anywhere else.
`docs/goals.md` lists the outcome order written out for a reader, so
a tournament that changes the order of outcomes lands twice: the
comparisons on the board, and a PR that rewrites the list and names
each pair it asked and how it fell. the PR is the record of the
matches; the board is the order.

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
