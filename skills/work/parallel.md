# Fanning out: many implementer sessions at once

the board's WIP limits are sized for parallel work — `do` admits
several implementer sessions at once, and `ready` holds a queue deep
enough to feed them independent slices (`status` prints both against
their limits). this chapter is the other half of that design: how ONE
orchestrating session runs several implementers concurrently without
them colliding, and which parts of the system never fan out.

the orchestrator is not a new role. it pulls from the same board by
the same rules; it just does step 2 of the implementer loop N times
and delegates step 3 to N agents, each in its own checkout.

## when to fan out

- `ready` holds two or more MUTUALLY INDEPENDENT slices and `do` has
  room. the limit is a cap, not a target: fan out to what is actually
  independent, never to what merely fits.
- work flows right to left for an orchestrator too. a `check` item
  unblocks more as a planner verdict than as another implementer, and
  `land` comes before both: land what is accepted, then fan out — a
  wave of pulls on top of a full landing queue starts work while
  finished work waits.
- never fan out to make ONE slice faster. a slice is sized for one
  session by construction (`decompose.md`), and splitting it across
  agents is how a diff arrives half-implemented twice.

## picking the set: disjointness beats board order

`next` names exactly one item, and it does not know what else you are
about to take. taking N means walking the board's order yourself and
SKIPPING any item whose files a slice you already took is touching.

the shape to watch for: one slice restructures a file, another edits
it. taken in one wave they produce two PRs that cannot both merge,
and the second implementer's session is thrown away. take the next
item down instead.

disjointness is judged on the MERGE, not on either branch. two slices
that each GROW the same file are not disjoint when that file is near
the 500-line cap: each branch clears the cap alone — 470 lines on one,
480 on the other — and the merge is over it, a failure that belongs to
neither diff and that neither implementer can see. treat a shared file
with thin headroom exactly like a shared restructure, and take the
next item down.

say which one you skipped and why, in the report and in the item's
spec trail. an orchestrator stepping over the board's order silently
is indistinguishable from a bug.

`blocked_by` chains are already handled — `next` skips them.
file disjointness is the check `next` does NOT do, and it is yours.

## claim first, then spawn

move each item to `do` YOURSELF (`move ID do --claim <session>`), one
at a time, before spawning anything. the move is the lock; an agent
that claims its own item races every other agent for the same phase.
name that session to `next` too (`next --session <session>`): a claim
is only a lock against a session that reads it, and `next` without one
will happily hand you back work another orchestrator is running.

read each move's verdict line. a lost race is not a lagged index
anymore: a rejected publish rebases onto whoever moved first,
re-checks the limit against the merged board, and REFUSES explicitly
if it now binds — re-read the board and continue, never `--force`
(`SKILL.md`'s hard rules bind the orchestrator exactly as they bind
everyone else).

## the board stays with the orchestrator

agents do not run board verbs. the orchestrator claims before
spawning, moves each item to `check` when its PR opens, and files
what the agents found — so no agent needs the board worktree, push
rights to `board`, or any state beyond its own slice. the agent's
job is the diff; the board's truth is one session's responsibility
per wave.

## one worktree, one branch, one PR

- **one worktree per agent.** a shared checkout means two sessions
  editing the same tree and one `o/` racing itself; the builds
  interleave and both results are garbage.
- **one branch per item**, named after its id prefix. never stack two
  slices on one branch: one branch is one PR is one slice, and a
  stacked branch cannot be reviewed, reverted, or merged as the slice
  it claims to be.
- **a fresh worktree has no `o/`.** the brief must start with
  `bin/cosmic --make fetch`, or the agent's first `--make` command
  fails on a cold tree and it starts debugging the toolchain instead
  of the slice.
- **keep the worktrees out of the project root if you can.** a
  checkout nested inside another project's root breaks `--make` in
  both directions, and neither failure names its cause:
  - inside, every verb refuses with `ambiguous root: … is inside a
    project rooted at …`. `COSMIC_MAKE_ROOT=$PWD` gets past it, but
    that variable is INHERITED by the nested `--make` runs the tests
    spawn, so it fails `_make/check_test.tl` and
    `_types/tl_conformance_test.tl` — three gate failures that belong
    to the layout, not the diff.
  - outside, the parent's gate breaks instead: the project model
    prunes dot-directories, so a checkout under `.claude/worktrees/`
    stays out of the MODEL, but the coverage scan walks the tree
    itself without that pruning, and the nested checkout's sources and
    `.cov` dumps join the PARENT's report — a ratchet failure against
    thousands of foreign paths. a `.gitignore` entry keeps `git
    status` clean; it does not keep `--make ci` clean.

  when the layout is not yours to choose, an agent's brief should say
  to gate from an unambiguous root — a copy of the tree elsewhere,
  with the changed files verified identical afterwards — and the
  parent should gate from outside its own root, or wait for the wave
  to land.
- **a stale `o/` does not survive a path move.** a tree copied or
  moved with its build directory reports a mass coverage collapse
  (74% -> 25% across ~130 files, in the case that found this) that is
  purely the stale paths. `rm -rf o && bin/cosmic --make fetch` first,
  or the wave's first gate result is fiction.

## the brief

an agent knows nothing this session knows. paste the spec sidecar
verbatim rather than pointing at an id — "read the board and do it"
turns a specified slice back into an interpretation, which is the one
thing the ready bar exists to prevent. then add what the spec does
not carry:

- the branch name, and the instruction to start from the latest
  `origin/main`;
- bootstrap (`--make fetch` first) and honest gate timeouts — `--make
  ci` takes minutes, and an agent that kills it at 2 minutes reports a
  failure that never happened;
- environment quirks the tree does not document (proxy variables,
  tokens);
- the commit trailers and the PR attribution footer;
- a PR opened READY for review, not draft, carrying `Board: <id>` in
  its body so the reviewer joins the PR to its item — the orchestrator
  runs `move ID check` when it sees the PR;
- the acceptance run in that body: the spec's commands and the verdict
  lines they ended on. an agent that ran them and said so in its final
  message has told the orchestrator, not the reviewer, and the
  reviewer is who needs it;
- the finding rule: report anything found out of scope — a real
  defect, a stale doc — in the final message as one paragraph of
  evidence each, and return to the slice. the orchestrator files each
  as a board finding; an agent that cannot hand evidence somewhere
  either loses it or widens its diff to fix it;
- **do not merge** — a PR lands only after a planner accept, in a
  later implementer pass. the brief's loop ends at the opened PR.

carry the bounce rule verbatim (`SKILL.md`, "when the spec
under-specifies"): report exactly what is missing and stop — the
orchestrator returns the item to `plan`. an agent told to finish WILL
improvise unless the brief says that stopping is a good outcome.

## what never fans out

- **the review verdict.** it is the system's final gate and a
  sophisticated model's judgment (`review.md`); N agents reviewing N
  PRs is N unreviewed merges wearing a costume.
- **refinement.** parallel planners contend on the same phases and
  the same goals, and two of them will decompose the same goal twice.
- **anything two slices share.** see above — this is the whole game.

## after the wave

an agent can die mid-loop, so reconciliation is the orchestrator's,
not the board's:

- every item that went to `do` is now in `check` with a PR, or back
  in `plan` with the gap recorded. anything else — `do` with no PR —
  is a dead session: move it back to `ready` yourself rather than
  leaving the phase jammed against its limit.
- run `status` and read it. the board is the truth of what happened,
  and a fan-out that half-failed looks fine from inside the session
  that launched it.
- the PRs are yours to watch now. the agents are gone; their CI
  failures and review comments arrive here.

## the cost

G8 measures tokens × model tier per merged slice, and a fan-out
multiplies the first factor by N. that is a good trade when the N
slices are independent and each becomes a merge; it is pure waste
when two of them collide and one gets thrown away. the disjointness
check is not bookkeeping — it is the cost control.
