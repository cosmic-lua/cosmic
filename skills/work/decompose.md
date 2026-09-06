# Decomposing an outcome

an outcome in `docs/goals.md` never carries work itself: it is worked
by the items filed under it, and intake (`gitboard next`,
`_work/intake.tl`) offers the highest-ranked open outcome with no live
work as the thing to decompose next. three parts of that procedure are
recorded here, because they are what places an outcome and moves it
from "worked" to "verified" and back: ranking an outcome among its
siblings, the VERIFICATION item, and what a verified outcome does at
intake. everything else — the spec bar, `take`, review, landing — is
the same for these items as for any other, and `gitboard help <topic>`
serves it.

## ranking an outcome

the order intake reads is never asserted: it is a position in the
board's own `order` list, the same list any parent holds for its
children (`gitboard help order`). an outcome absent from that list is
unranked among its siblings and is triage — invisible to every queue
and refused by `take` — until it is ranked or attached under a ranked
outcome's subtree.

**placing a new outcome.** `rank ID --before X | --after X | --last`
edits the board's list in one commit. walk the current order down from
the top until the new outcome loses once — until a session judges the
outcome above it the better cosmic to hold — and rank it below the
first outcome it loses to; two or three comparisons usually place it.
it stays triage, invisible to intake, until that first `rank` lands.

**re-ranking.** evidence moves against the committed order — an
outcome's distance from verified changes, or a session cannot say why
the outcome above it should be worked first — and `rank` moves it
directly; a re-rank that moves nothing is a fine outcome, the order
was right. the outcome nearest to verified takes no re-rank at all:
finishing beats starting, so it is finished, not debated.

**who answers.** a rank change that would put NEW work above existing
work belongs to the goal owner — it answers "which is the better
cosmic", and that is not the session's call. post the pair (in chat,
or in the session's report when nobody is watching) and keep working;
the answer lands as a `rank` whenever it arrives. when nobody is
around to place a new outcome at all, attach it under the
lowest-ranked outcome it plausibly serves and say so, so the item is
placed today and the rank can still be asked later.

**how the result lands.** `docs/goals.md` lists the outcome order
written out for a reader, so a re-rank that changes the order of
outcomes lands twice: the `rank` on the board, and a PR that rewrites
the list and names what moved and why. the PR is the record of the
reasoning; the board is the order.

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

## a verified outcome

once the VERIFICATION item is accepted and merged, a session ends the
outcome by that evidence:

```bash
gitboard done <outcome-id> --reason completed --by <verification-id>
```

`done` refuses this on an outcome with an open child (nothing may
still be in flight), a `--by` that is not the outcome's own completed
child, or no `--by` at all — an outcome cannot be verified by
assertion. the child's id rides in the commit subject and the verdict
line, so the board's log names the evidence.

a verified outcome is DONE, the same resolution any other finished
item carries, and every derived-order view treats it exactly as it
treats any done item: intake skips it with no rule of its own, and
`gitboard show` (bare, the board-wide status) and `gitboard show
<outcome-id>` still find it and render it as done, since it is the
record of what holds. the goals file records the graduation in its
`## Holding` section.

filing or attaching a new item under a done outcome — fresh evidence
that the win condition slipped — clears its resolution in the same
commit as the child (`gate.containered`, the hook that already clears
a parent's claim and reviewer when it gains a child), so the outcome
is open again automatically and intake offers it once its new work is
done. that is the only reopen path: a done outcome carries no separate
marker to correct by hand, so evidence under it is the whole of how
it reopens.
