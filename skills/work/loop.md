# The standing loop: `/work N`

invoked with a number — `/work 5`, or `/loop /work 5` to run on a
cadence — the session is a LOOPED ORCHESTRATOR: each invocation is one
pass over the board, targeting up to N items in flight at once. the
mechanics of a fan-out (disjointness, claims, worktrees, the brief) are
`parallel.md` and are not restated here; this chapter is what a PASS
is, how it reports, and the one property that makes a loop worth
running: it never blocks.

N is a ceiling, not a quota. the real width is the smallest of N,
`do`'s free slots, and how many ready items are actually independent —
fan out to what is disjoint, never to what merely fits. a pass that
runs zero agents is a legitimate pass.

## one pass

a pass is the session loop run with the board's own ordering — right
to left, finishing before starting — bounded so it terminates instead
of babysitting:

1. **sync, then reconcile the previous wave.** every agent this
   session spawned earlier is now finished, dead, or still running.
   finished with a PR: `move ID check --pr N` and subscribe to the PR.
   dead (no PR, no branch pushed): return the item — `move ID ready`,
   with `--force --why agent died` since the claim is a minted agent's,
   and say so in the report. still running: leave it alone; it holds
   its claim and its `do` slot, and this pass's width shrinks by one.
2. **land** whatever carries an accept. a merge the environment cannot
   perform (a 403 from a scheduled session) is reported in one line and
   stepped past, never retried in a spin.
3. **review** one item sitting in `check`: the id step 1 reconciled
   there, or what `next` offers. spawn ONE review subagent with the
   brief `review.md` describes, wait for it, and act on the verdict it
   recorded. the subagent's window holds the spec and the diff and
   none of this pass's reasoning, which is what makes the judgment
   disinterested. one review, never a fan-out of them (`parallel.md`,
   "what never fans out"); one item per pass is a good bound, because
   a verdict is the system's most expensive judgment and a pass that
   writes five is skimming.
4. **fill the wave.** while `do` has room and the pass has width left:
   walk the ready queue for a disjoint set (yours to judge —
   `parallel.md`), claim each item FIRST (`move ID do --claim
   <minted>`), then spawn its agent in the background with the brief.
   spawning in the background is what keeps the pass bounded: the pass
   ends when the wave is launched, not when it finishes. agent results
   arrive as task notifications; the NEXT pass reconciles them.
5. **fall back to intake.** width filled with items to spare, or
   nothing pullable at all: do what `next` names — refine, promote,
   triage, unblock — at most one or two such actions, then stop. the
   fallback is what "blocked" turns into: a session that cannot pull
   still moves the board.
6. **report and end the pass.** never wait inside a pass — not for a
   wave agent, not for CI, not for an answer. the step-3 review
   subagent is the single exception, and one item bounds it. everything
   else worth waiting on either notifies (task completion, PR events)
   or is the next pass's problem.

## minted identities and your own wave

each agent's claim is minted from this session's own identity plus a
unique suffix: `<session>/<item-prefix>`. unique per agent, so claims
lock (`parallel.md`); prefixed by the orchestrator, so the wave's
provenance is readable in the log.

**an orchestrator may take the verdict on its own wave.** the review
runs in a subagent whose window never held the build — not the brief
that spawned the builder, not the agent's report, not this pass's
reasoning about the item — so the distance a verdict is worth is there
however the reviewer was spawned. that is the rule `review.md` states,
reaching the case a loop meets every pass, not an exception carved out
of it.

**`next` withholds that item.** it offers nothing whose claim or
`builders` name this session, and a minted claim compares by its
prefix, so everything this session's agents built reads as this
session's own. the item is stepped over in silence — the count of them
surfaces only when `check` is at its limit and nothing else fires — so
a pass that waits for `next` to hand back its own wave waits forever.
spawn the review subagent on the id directly, the one step 1
reconciled into `check`.

the distance is only as good as the brief. it carries the item id, the
PR number and the checks, and NOT this session's reading of the item:
the subagent reads the spec off the board and the diff off the PR
itself. a brief that summarises what the wave was trying to achieve
hands the reviewer back the commitment a fresh window exists to be
without.

the claim and `builders` stay the audit record — who held the item, who
built it — and the verdict carries the review subagent's own name,
exported rather than derived: a subagent inherits the session id of the
process that spawned it, so a reviewer that does not name itself records
the verdict as this session's (`review.md`). the log is what shows
whether a review ran at a distance. no gate can inspect a context
window; that record is the evidence.

## never blocked

every way a pass can stall has a non-blocking answer, and most are
already the system's rules — collected here because a loop hits them
all:

| stall | answer |
|-------|--------|
| lost a claim race | next candidate; none left → shrink the wave |
| WIP limit refuses a move | work the right end (review, land), else intake |
| spec under-specifies mid-wave | agent stops (its brief says so); bounce the item to `plan`, gap named |
| ranking question nobody can answer | attach low provisionally and say so (`SKILL.md`) |
| a comparison that raises work | post the pair in the report, keep working |
| out-of-scope finding | capture it (below), return to the pass |
| merge refused (403, branch protection) | one report line, next pass retries once |
| `next` offers no review while your own wave sits in `check` | it withholds this session's own wave; spawn the review subagent on the id step 1 reconciled |
| `next` says `none` | report the named bottleneck in one line, end the pass |

`none` is an answer, not a failure: the loop's value on a quiet board
is that it noticed quietly. do not invent work, do not open items to
fill a quota, and do not lower a bar or force a limit to make a pass
look productive — the hard rules bind a loop exactly as they bind a
session.

**captures dedupe before they file.** N sessions in a loop trip over
the same defects, and a duplicate capture costs a triage decision and
a close. so: `gitboard find <key phrase>` first; an open item that
already names the defect is cited in the report instead of filed
again. no match → `gitboard new "title" --spec-file F` with one
paragraph of evidence, exactly as `SKILL.md` says. filing is never
refused, so this path never blocks.

## the report

the pass's output is a terse ledger, not a narration: one line per
board action, in the order taken, then one line for anything posted
for a human. nothing else — no restated specs, no plans, no prose
between lines.

```
sync: ok (2 behind)
reconcile: 3IAAAAAA -> check pr:1401; 3IBBBBBB dead -> ready
land: 3ICCCCCC merged #1388
review: 3IDDDDDD -> request changes (missing acceptance run)
wave 3/5: took 3IEEEEEE 3IFFFFFF 3IGGGGGG (skipped 3IHHHHHH: shares
  cosmic/sqlite.tl with 3IEEEEEE)
captures: 1 filed (3IJJJJJJ gate.tl:88), 1 duplicate (cited 3IGGGGGG)
none left: ready empty — refined 3IKKKKKK one rung
```

under `/loop` in dynamic mode, a pass that only checked and found
nothing to move is a no-op tick — say `none: <reason>` and mark it so.
pace by what is outstanding: agents in flight notify on completion, so
the wakeup is a long fallback, not a poll; a quiet board earns the
idle interval. a pass that moved anything is not a no-op, however
small the motion.
