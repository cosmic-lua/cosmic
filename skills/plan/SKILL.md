---
name: plan
description: >
  The system of work for cosmic: work backwards from the goals in
  docs/goals.md, decompose ambitious outcomes into GitHub issues that
  flow kanban-style across a WIP-limited board, and refine each issue
  until a less sophisticated model can implement it reliably. Use when
  planning what to build next, refining or decomposing work, pulling
  the next issue to implement, or reviewing an implementer's PR.
---

# Planning cosmic: the system of work

this skill is the operating manual for how work on cosmic (and its C
core, whilp/cosmopolitan) is defined, refined, implemented, and
reviewed. it exists because two different kinds of model work on this
repo, and the system is designed so each does what it is best at:

- a **planner** — a sophisticated model (Fable-class) — works backwards
  from ambiguous, ambitious goals, decomposes them into concrete work,
  refines each piece until it is mechanically implementable, and
  reviews what comes back.
- an **implementer** — a less sophisticated model (Opus/Sonnet-class) —
  works backwards kanban-style: take the thing closest to completion
  forward. rework a planner sent back, then in-flight work, then the
  oldest ready issue — implement exactly what the issue says, and hand
  the result back.

the final gate is always a planner: nothing merges until a
sophisticated model has judged the implementation against the issue's
definition of work AND the goal it traces to (`review.md`).

the planner's defining duty is not writing issues; it is making
implementers succeed. when a piece of work is too ambiguous for an
implementer, the planner does not hand it over anyway — it either
refines the issue further or changes the system (core first, then
docs, then skills) until the ambiguity is gone. see `enable.md`.

like `optimize` and `agent-eval`, this is repo tooling for developing
cosmic itself — not embedded in the binary, not part of the published
API. the chapters:

- `SKILL.md` — this file: the board, the roles, the session loops, the
  rules.
- `decompose.md` — working backwards from goals; the refinement
  ladder; the ready bar in full, with a worked example.
- `enable.md` — making implementers succeed: core > docs > skills.
- `review.md` — the planner's review verdicts and the friction
  feedback loop.

## the board in one minute

ALL work state lives in GitHub issues. an issue's column is a label;
the board is whatever the labels say; there is no other tracker and
nothing to commit. the tool is `_plan/board.tl`:

```bash
bin/cosmic --make run _plan/board.tl status              # the board + WIP verdict
bin/cosmic --make run _plan/board.tl next --role planner # the one next action
bin/cosmic --make run _plan/board.tl next                # implementer by default
bin/cosmic --make run _plan/board.tl check 123           # ready-bar lint
bin/cosmic --make run _plan/board.tl move 123 ready      # column change, WIP-limited
bin/cosmic --make run _plan/board.tl new "title" --epic  # open a board issue
bin/cosmic --make run _plan/board.tl init                # create the labels (once per repo)
```

every verb ends with a `plan-<verb>:` verdict line — read that, never
a piped exit status. the default repo is whilp/cosmic; `--repo
whilp/cosmopolitan` targets the C core's board. the tool talks to the
GitHub REST API directly through cosmic's own fetch — no gh CLI: it
needs a `GITHUB_TOKEN` (or `GH_TOKEN`) env var, honors `HTTPS_PROXY`,
and behind a TLS-intercepting proxy wants `SSL_USE_SYSTEM_CERTS=1
SSL_CERT_FILE=<bundle>` (both read by the cosmos TLS root loader).
on a cold clone, run `bin/cosmic --make fetch` once before the first
board command — `--make run` resolves the tool against the tree and
needs the pinned toolchain to exist.
one timing note: a `move`'s verdict line is the truth of the mutation;
GitHub's list-by-label index can lag it by a few seconds, so an
immediately following `status`/`next` may briefly show the old column
— reread, never re-move. the same lagged index feeds the WIP checks in
`new` and `move`, so a burst of creations or moves can hit a spurious
`REFUSED` at the limit: pause and retry, never reach for `--force`.

columns, left to right (an issue carries exactly one column label):

| label | meaning | WIP limit |
|-------|---------|-----------|
| `plan:shaping` | traced to a goal, still ambiguous — planner territory | 12 |
| `plan:ready` | meets the ready bar (`decompose.md`); pullable | 20 |
| `plan:doing` | in implementation: claimed work and rework | 5 |
| `plan:review` | PR open; awaiting a planner verdict | 10 |

the limits are sized for implementer sessions running in parallel: ready
holds a deep queue of mutually independent slices, doing matches the
number of concurrent sessions, and review gives finished work room to
wait for a planner without jamming doing. what makes the deep ready
column safe is independence — see "sizing a slice" in `decompose.md`.

done is a closed issue — completed when the work merged, not planned
when the planner killed it (a recorded dead end, kept forever). two
marker labels ride alongside the column: `plan:epic` (a decomposition
parent — never pulled, closes when its children close) and
`plan:enable` (work that exists to make implementers succeed).

an issue is **blocked** when its body has a line containing `blocked
by` naming open issues (`Blocked by: #99`). `next` skips blocked
issues; `check` reports them.

**work flows right to left.** finishing beats starting: review before
refining, refining before intake, and an implementer finishes doing
before pulling ready. the WIP limits are what make this real — a full
column REFUSES new entries (`move` says so) and the fix is to drain
the columns to its right, not to widen the limit. limits are policy,
committed in `_plan/model.tl`, tuned only by a reviewed change.

## the planner session

run `next --role planner` and do what it says; the rule it applies is,
in order:

1. **review** — anything in `plan:review` gets a verdict first
   (`review.md`). this is the strongest lever: it unblocks
   implementers and harvests friction evidence.
2. **refine** — while `plan:ready` has slack, take the oldest shaping
   issue one rung down the ladder (`decompose.md`): decompose an epic,
   or drive a slice to the ready bar. before a `move N ready`, run the
   enablement check (`enable.md`) and `check N` — both must pass.
3. **intake** — while `plan:shaping` has slack, work backwards from
   [docs/goals.md](../../docs/goals.md): walk the RANKED outcome list
   top-down and take the first goal whose win condition has real
   slack and no live epic already driving it; name the most valuable
   missing outcome and open it as a shaping issue (usually an epic).
   the rank is committed and re-derived by paired comparison when
   contested (`decompose.md`); instruments (G1, G8) get worked when
   an outcome's measurement needs them.
4. **nothing** — shaping and ready are full and review is empty:
   implementation has to catch up. do not open more issues; a longer
   backlog is not progress.

a planner session may touch several cards, but it respects the same
flow: never step left while a right-hand column has work for you.

## the implementer session

one issue per session, exactly this loop:

1. `next` names the issue, rightmost first: finish `plan:doing` —
   which holds both fresh claims and rework a review verdict sent
   back, the work closest to completion — before pulling the oldest
   unblocked `plan:ready`. if it answers `none`, stop — do not invent
   work; say a planner session is needed (`next` names the bottleneck).
2. claim it: `move N doing`, then comment on the issue that this
   session is on it (the move is the lock; the comment is the trail).
   a doing item with an open PR and review comments is rework: skip
   the claim ceremony, address the reviewer's quoted gaps on that PR,
   and rejoin the loop at step 3.
3. implement EXACTLY what the issue says. its `Change` is the scope,
   its `Non-goals` are walls, its `Acceptance` commands are the
   definition of done — run them and quote their verdict lines in the
   PR description.
4. open the PR, referencing the issue (`Closes #N`), then `move N
   review` and comment the PR link on the issue.
5. stop. review is the planner's job; do not merge your own PR.

**when the issue under-specifies** — you hit a decision the body does
not settle, a command that does not exist, a contract question — do
not improvise. comment on the issue naming exactly what is missing,
`move N shaping`, leave the PR draft or close it, and stop. a bounce
is a good outcome: it is the ready bar failing loudly instead of a
silent wrong guess, and every bounce becomes enablement evidence
(`enable.md`).

## hard rules (guardrails)

- ALL plan state lives in GitHub issues and their labels — never in
  committed backlog files, notes docs, or TODO comments. the files in
  this directory carry method only. (the `perf` label keeps its own
  hypothesis backlog under the `optimize` skill; a plan issue may link
  to a perf issue, never duplicate it.)
- the ready bar is never lowered to make an issue pullable, and the
  WIP limits are never widened to make a move succeed. `--force`
  exists for repair (a mislabeled issue, a split epic), not for flow.
- epics are never pulled. an epic in `plan:ready` is a bug; `check`
  says so.
- implementers implement what the issue says; planners decide what
  issues say. a scope question discovered mid-implementation goes back
  to the board, not into the diff.
- every issue traces to a goal: its `Goal` section names a `G<n>` from
  docs/goals.md or a parent epic that does. work that traces to no
  goal is closed as not planned, however good the idea — open a goals
  amendment PR instead when the goals themselves are wrong.
- repo conventions are not relaxed for implementers: `--make ci` and
  the contract freezes in AGENTS.md bind every PR regardless of which
  model wrote it. when a convention keeps tripping implementers, the
  fix is enablement (`enable.md`), never an exception.
