## Evidence

2026-08-20, hit live in a scheduled (unattended) session. The session
prompt assigned designated development branches:

    whilp/cosmic:        claude/zealous-hypatia-dji1my
    whilp/cosmopolitan:  claude/amazing-ride-dji1my

with the instruction "NEVER push to a different branch without
explicit permission". The board then handed that session two REWORK
actions in a row — `finish 3IBFBWtc` (PR #1297, head branch
`claude/zealous-hypatia-uiab8f`) and `finish 3I1J9Xhg` (PR #1295, head
branch `claude/peaceful-bohr-yv5jl8-coverage-floor`) — neither on the
assigned branch, both opened by earlier sessions.

The `work` skill's slice loop is unambiguous about the outcome it
wants ("address the quoted gaps on that PR and hand it over again"),
which requires pushing to the PR's OWN head branch. It never says so
in those words, because on `main` the skill has no reason to know a
session might arrive with a branch assignment.

Obeying the branch assignment literally would have: pushed the rework
to a branch the PR does not track, left #1295/#1297 sitting at their
reviewed heads with the `request changes` verdict unaddressed, and
opened a SECOND pull request for an item whose `pr` field already
names the first — splitting one item's review across two PRs and
stranding the reviewer's comments on the abandoned one.

This session resolved it by pushing to each PR's own branch, which is
right, but it resolved it by reasoning rather than by reading a rule.
An unattended session that resolves it the other way produces exactly
the damage above with no one watching, and the `pr` field on the item
makes the mistake durable.

## Why the board is the right place to state it

The board already holds the fact that decides this: an item in `do`
carrying a `pr` is REWORK of an existing PR, and its head branch is
discoverable from that number. The rule follows mechanically — if the
item names a PR, the work goes to that PR's branch; a branch
assignment applies only when the item names none (a fresh pull, where
the session is opening the first PR).

## Fix shapes (not chosen here)

- **Skill prose (cheapest)**: `SKILL.md`'s slice loop, at the rework
  step, says the push target is the PR's own head branch — explicitly
  outranking any branch a session was assigned, and says why (the item
  names one PR; a second would split its review).
- **Mechanical**: `gitboard show` prints the PR's head branch beside
  `pr: #N`, so the session is told the target rather than deducing it.
  Costs a GitHub read on `show`, which today needs none — probably
  only worth it on an explicit flag.
- **Cheapest mechanical**: `next`'s rework answer already names the
  PR ("rework of <session>'s build"); have it name the branch too,
  where it is already reaching for the item's fields.

Related but distinct from 3ICDOGbm (builder distance / the re-claim):
that one is about WHO may judge the rework, this one is about WHERE
the rework is pushed.

## Second evidence: one assigned branch, two fresh pulls

2026-08-24, hit live in another scheduled (unattended) session, session
name `magical-bell`, assigned `claude/magical-bell-bk8kul`. This is the
case the section above assumes away — "a branch assignment applies only
when the item names none (a fresh pull, where the session is opening the
first PR)" — because it presumes ONE fresh pull per session. The loop
does not work that way.

The session ran the loop as instructed (up to five actions): pulled
3IK30UQA, built it, opened PR #1354 on the assigned branch, moved it to
`check`. Two actions later `next` answered `pull 3IM89fv4` — a second
FRESH item, naming no PR. The assigned branch was already spent: it
carries #1354 and pushing a second, unrelated change onto it would put
two board items in one pull request and couple their verdicts (the
failure 3I9igGsG describes from the other direction).

There is no third option. The session stopped the loop with one action
of its five remaining budget unusable, and left 3IM89fv4 in `ready`
rather than claiming a lease it could not discharge.

So the rule the item needs is wider than the rework case: a branch
assignment is **one branch, and therefore at most one fresh PR per
session**, while `next` will keep handing out fresh pulls as long as
`ready` has depth. Whatever fix shape is chosen has to say what the
session does with the second one. The candidates:

- **Derive a branch per item** — `<assigned-branch>-<item-prefix>` — so
  one session can open several PRs without inventing names. Needs the
  session prompt's "never push to a different branch" to admit the
  derivation, which is a change to how the routine is configured, not
  to this repo.
- **Cap the loop at one fresh pull** and say so in `SKILL.md`, letting
  the remaining actions go to review, refine and promote — cheap, but
  it caps throughput for every session, not just branch-assigned ones.
- **Have `next` know** a session has spent its branch, and prefer
  non-pull actions once it has. Needs the session to tell the tool,
  which it has no way to do today.

Not chosen here; recorded so the item is refined against the whole
problem rather than half of it.
