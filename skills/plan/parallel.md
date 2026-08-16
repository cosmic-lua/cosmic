# Fanning out: many implementer sessions at once

the board's WIP limits are sized for parallel work — `plan:doing`
holds 5 because five implementer sessions can run at once, and
`plan:ready` holds 20 so there is a deep queue of independent slices
to feed them (`SKILL.md`). this chapter is the other half of that
design: how ONE orchestrating session runs several implementers
concurrently without them colliding, and which parts of the system
never fan out.

the orchestrator is not a new role. it pulls from the same board by
the same rules; it just does step 2 of the implementer loop N times
and delegates step 3 to N agents, each in its own checkout.

## when to fan out

- `plan:ready` holds two or more MUTUALLY INDEPENDENT slices and
  `plan:doing` has room. the limit is a cap, not a target: fan out to
  what is actually independent, never to what merely fits.
- review still comes first. work flows right to left for an
  orchestrator too — if `plan:review` has anything in it, a planner
  verdict unblocks more than another implementer does.
- never fan out to make ONE slice faster. a slice is sized for one
  session by construction (`decompose.md`), and splitting it across
  agents is how a diff arrives half-implemented twice.

## picking the set: disjointness beats board order

`next` names exactly one issue — the oldest unblocked ready — and it
does not know what else you are about to take. taking N means walking
that order yourself and SKIPPING any issue whose files a slice you
already took is touching.

the shape to watch for: one slice restructures a file, another edits
it. #1118 splits `_plan/board.tl` in two; #1119 adds a verb to that
same file and says so in its own body. taken in one wave they produce
two PRs that cannot both merge, and the second implementer's session
is thrown away. take the next issue down instead.

say which one you skipped and why, in the report and in the issue
trail. an implementer stepping over the board's order silently is
indistinguishable from a bug.

`Blocked by:` chains are already handled — `next` skips them.
file disjointness is the check `next` does NOT do, and it is yours.

## claim first, then spawn

move each issue to `plan:doing` YOURSELF, one at a time, before
spawning anything. the move is the lock; an agent that claims its own
issue races every other agent for the same column.

space the moves and read each verdict line. GitHub's list-by-label
index lags a mutation by a few seconds, so a burst of moves can hit a
spurious `REFUSED` at the limit — pause and retry, never `--force`
(`SKILL.md`'s hard rules bind the orchestrator exactly as they bind
everyone else).

## one worktree, one branch, one PR

- **one worktree per agent.** a shared checkout means two sessions
  editing the same tree and one `o/` racing itself; the builds
  interleave and both results are garbage.
- **one branch per issue**, named after it. never stack two slices on
  one branch: one branch is one PR is one issue, and a stacked branch
  cannot be reviewed, reverted, or merged as the slice it claims to
  be.
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

an agent knows nothing this session knows. paste the issue BODY
verbatim rather than pointing at its number — "read #N and do it"
turns a specified slice back into an interpretation, which is the one
thing the ready bar exists to prevent. then add what the issue does
not carry:

- the branch name, and the instruction to start from the latest
  `origin/main`;
- bootstrap (`--make fetch` first) and honest gate timeouts — `--make
  ci` takes minutes, and an agent that kills it at 2 minutes reports a
  failure that never happened;
- environment quirks the tree does not document (proxy variables,
  tokens);
- the commit trailers and the PR attribution footer;
- a DRAFT PR referencing `Closes #N`, then `move N review` and the PR
  link commented on the issue;
- **do not merge** — the verdict is a planner's job and the merge is
  the goal owner's, and an agent with a green PR will otherwise
  finish the job it thinks it has.

carry the bounce rule verbatim (`SKILL.md`, "when the issue
under-specifies"): comment naming exactly what is missing, `move N
shaping`, stop. an agent told to finish WILL improvise unless the
brief says that stopping is a good outcome.

## what never fans out

- **the review verdict.** it is the system's final gate and a
  sophisticated model's judgment (`review.md`); N agents reviewing N
  PRs is N unreviewed merges wearing a costume.
- **refinement.** parallel planners contend on the same columns and
  the same goals list, and two of them will decompose the same goal
  twice.
- **anything two slices share.** see above — this is the whole game.

## after the wave

an agent can die mid-loop, so reconciliation is the orchestrator's,
not the board's:

- every issue that went to `doing` is now in `review` with a PR, or
  back in `shaping` with a bounce comment. anything else — `doing`
  with no PR — is a dead session: move it back to `ready` by hand
  rather than leaving the column jammed against its limit.
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
