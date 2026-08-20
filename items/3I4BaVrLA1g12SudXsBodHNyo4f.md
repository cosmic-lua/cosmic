## Goal

G8 — the flow system: the measurement G8 names is unbuilt. Every board
transition is one commit on the `board` branch, so `git log` over
`items/**` IS the flow record; the flow review (`skills/work/review.md`)
currently reads it by hand. This item builds the instrument that reads
it mechanically, replacing the deleted label-era `stats.tl`.

The hand method has now been run end to end once, over this branch's
full history (the spike recorded under "Measured" below). It produced
the decisions review.md's rules ask for — and it exposed four places
where the hand grammar and the file-state walk disagree, plus two
errors in this spec's own test plan. Both are settled here, so the
implementer meets none of them mid-slice.

## Change

1. **Where: `_work/stats.tl` + a `gitboard stats` verb.** The log it
   reads lives on this branch beside the machinery; "board state moves
   and reads through gitboard only" makes a verb the door, and the
   generated `gitboard help` picks it up with no skill edit. Read-only:
   no network, no token, no mutation. The store's git plumbing already
   exists (`_work/store.tl:51`, `git(s, argv)` over the checkout).

2. **How it reads: file states, not subject parsing.** A commit
   subject cannot distinguish `new` into `plan` from `new` into triage,
   and hand-parsing `a -> b` strings re-implements what the item files
   already say. The walk: `git log --reverse --format=%H|%aI --
   items/*.tl` (plus `--since` when given); for each commit and each
   item file it touches, read the file at that commit (`git show
   <sha>:<path>`, parsed with `cosmic.literal` exactly as the store
   parses it live) and diff `phase`/`resolution` against the previous
   state.

   Subjects are consulted for exactly two things: the trailing
   `(forced: …)` marker (repairs, excluded from the flow numbers and
   counted separately) and the verb word, which classifies a backward
   move as bounce (`move`) vs rework (`verdict … "request changes"`)
   vs reject (`verdict … reject`) — review.md's three kinds, with
   accepts explicitly not backward.

3. **Four walk rules the hand grammar leaves open.** Each was hit in
   the spike; each would otherwise be a mid-slice decision or a silent
   wrong number.

   - **A stint ends on a phase CHANGE, not on the next mention.**
     review.md says a stint "ends at the next commit naming that id",
     which is hand shorthand: `spec`, `block`/`unblock`, `compare`,
     and an `attach` naming the item as PARENT all rewrite or touch an
     item's file without moving it. The history holds 74 `spec`
     commits against 99 items; taking mention as the end shreds
     nearly every stint. The rule: a stint ends only at a commit where
     that item's `phase` or `resolution` differs from the state the
     walk carries.
   - **Open stints are censored, not dropped.** 17 stints were still
     running at the window's end in the spike, three of them the whole
     70.4 h. Close each at the window end, include it in the dwell
     numbers, and report the per-phase open count beside the stint
     count so a reader can see how much of a median is right-censored.
     A report that drops them hides exactly the aging the review is
     looking for.
   - **A transition need not name its item.** An item can change phase
     in a commit whose subject names a DIFFERENT item: `gitgate`'s
     `rephased_parent` returns a container to `plan` inside the `done`
     commit of its last child, and `dephased_container` clears a
     parent's phase inside the child's `attach`. Measured over full
     history: 28 arrivals into `plan` were not the subject of their own
     commit (14 container re-phases, 14 from the branch's seed commit)
     against 43 that were. The subject-word classifier has no verb for
     these, so the rule: classify a transition the subject does not
     name by its phase pair alone, and never as bounce, rework or
     reject — those three are review.md's names for a JUDGMENT, and
     nobody judged.
   - **`--since` seeds from the state before the window.** An item
     already sitting in a phase when the window opens has no entry
     event inside it. Walk from the first commit but emit nothing
     before `--since`, so every stint open at the window's start is
     carried in with its true entry time and its dwell is not
     truncated to the window.

4. **What it reports** — the flow review's own list, so a review
   quotes the tool instead of hand arithmetic. One `key=value` line
   per number (the house instrument shape), then
   `gitboard-stats: <N> transitions over <window>` as the verdict
   line. `--since ISO8601` narrows the window; default is full
   history. `--dir` as every verb.

   Per phase: stint count, open-stint count, dwell median and max
   (minutes), peak concurrent occupancy against `flow.LIMITS`, and
   minutes at-or-over the limit. **Report at-or-over on the REFUSING
   threshold.** `gitgate.wip_refusal` refuses an arrival at
   `count >= limit`, while `flow.wip_violations` prints a violation
   only at `count > limit` — different numbers, and the review cares
   about the first. Emit both (`plan_at_or_over_min`,
   `plan_over_min`): the gap between them is time the board spent
   refusing arrivals while `status` printed `WIP ok`.

   Globally: accept / rework / bounce / reject counts, forced-move
   count, and pickup latency (`ready`→`do`) median and max.

   Plus the three the spike had to compute by hand before review.md's
   rules 3 and 4 could be applied at all. They fall out of the same
   walk, need no further input, and without them the dwell table
   cannot answer the question the review exists to ask:

   - **lead time**, created → ended, median and max, split by
     `resolution` — the `not-planned` cohort is what shows what triage
     is costing when it defers the decision.
   - **cycle time** from each commitment point: first entry into
     `plan`, `ready`, `do`, `check` → ended. Rule 4 judges the rework
     tax, which is the spread between these and lead time.
   - **aging WIP**: median and max age of the currently-open stint in
     each phase. Rule 3's "aging inventory" test is this number
     against pickup latency.

5. **Tests** (`_work/stats_test.tl`): `_work/fixture.tl`'s
   `init_state_repo` (`_work/fixture.tl:58`) builds a scripted history
   — new → ready → do → check → verdict accept → done; one bounce; one
   rework; one forced move; one container re-phased by its last
   child's close; one `spec` commit mid-stint — with dates pinned per
   commit so the dwell numbers are exact. Assert the table, all three
   backward classifications, the unnamed-transition fallback, the
   mid-stint `spec` NOT ending a stint, the forced exclusion, the
   censored open stint, and the pickup latency.

   **Pin `GIT_AUTHOR_DATE`, not just `GIT_COMMITTER_DATE`.** The walk
   in point 2 reads `%aI`, the AUTHOR date; pinning only the committer
   date leaves every dwell number floating on wall-clock. Set both.

   **`_work/fixture.tl`'s git helper takes no environment.** Its
   `git(cwd, argv)` (`_work/fixture.tl:47`) passes only `{cwd = cwd}`
   to `child.run`, so it cannot pin a date as written and must gain an
   optional env parameter. `cosmic.child`'s `Options.env` is a
   `{string}` of `"KEY=VALUE"` entries that REPLACES the environment
   when set (`cosmic/child/types.tl:45`), so build it as
   `env.list({set = {GIT_AUTHOR_DATE = d, GIT_COMMITTER_DATE = d}})`
   (`cosmic/env.tl:132`) rather than passing the two entries alone —
   a bare two-entry list would drop `PATH` and git would not start.

## Non-goals

- no persistence, no trend files, no chart output — one run, one
  table; history is re-derivable, which is the point of reading the
  log.
- no refusal counting: a refused mutation never commits (review.md
  documents this), so the tool cannot see it and must not pretend to —
  the report says so in a fixed footer line rather than omitting it
  silently.
- no change to `flow.LIMITS`, to `wip_refusal`/`wip_violations`, or to
  any verb's behaviour, and no skill edits. The threshold disagreement
  in point 4 is REPORTED, not reconciled; whether the two should agree
  is a separate item for whoever reads the first report.
- no derived verdict: the tool prints numbers, never a recommendation.
  review.md's four decision rules are a human's to apply.

## Acceptance

On the board worktree:

- `bin/cosmic --make test _work/stats_test.tl` ends
  `test: PASS (1 files)`.
- `o/bin/gitboard help` lists `stats`, and `o/bin/gitboard stats`
  against the live board ends with its `gitboard-stats:` verdict line.
- **Golden values.** The branch is append-only, so commit
  `1a25ebbe48802f421d6c23026cca53ba27cb32ab` is reachable forever and
  the numbers below are stable. Run the tool over a worktree at that
  commit and reproduce the "Measured" table exactly — every stint
  count, dwell median, peak, backward count and pickup-latency figure.
  Any divergence is the walk disagreeing with the hand read, and the
  disagreement is the finding, not a number to adjust to.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Measured

Spike run 2026-08-20 over the full history at
`1a25ebbe48802f421d6c23026cca53ba27cb32ab`, by the point-2 walk
(replay each `items/*.tl` blob per commit, diff `phase`/`resolution`)
with the point-3 rules applied. Window
`2026-08-17T14:21:05Z .. 2026-08-20T12:46:38Z` = 70.4 h, 382 commits
touching `items/`, 279 transitions, 99 items created, 62 ended,
15 forced.

Per phase (dwell in minutes, forced stints excluded):

| phase | stints | open | median | max | peak | limit | at-or-over |
|-------|--------|------|--------|------|------|-------|------------|
| plan  | 62 | 12 | 275.2 | 4225.6 | 21 | 12 | 66.3 h (94%) |
| ready | 43 |  3 | 235.3 | 1991.0 | 12 | 12 |  1.6 h (2%)  |
| do    | 38 |  2 |   6.4 |  774.3 |  3 |  5 |  0 h         |
| check | 29 |  0 | 167.6 |  617.4 |  6 | 10 |  0 h         |
| land  | 33 |  0 |  13.1 |  359.2 |  4 |  3 |  8.0 h (11%) |

`plan` strictly over 12 for 57.5 h (82%) and exactly at 12 for 8.8 h
(12%) — the second figure is time spent refusing arrivals while
`status` printed `WIP ok`.

Backward: 3 bounce `ready→plan`, 3 bounce `do→plan`, 3 rework
`check→do`, 0 reject; 29 accepts, which are forward and excluded.
Pickup latency `ready→do`: n=34, median 173.0 min, max 996.7 min.
Lead time created→ended: n=62, median 16.1 h, max 57.6 h. Cycle time
from first `do`: n=30, median 3.9 h.

## Enablement

Nothing to sequence ahead of this. The measurement definitions are
review.md's — the tool implements that text rather than proposing a
theory — and the four walk rules in point 3 settle where that text is
shorthand rather than adding to it. The git plumbing
(`_work/store.tl:51`), the fixture harness (`_work/fixture.tl:58`) and
the environment builder (`cosmic/env.tl:132`, `cosmic/child/types.tl:45`)
were each read at the cited lines while writing this. The one edit
outside `stats.tl`/`stats_test.tl` is the env parameter on
`_work/fixture.tl:47`, named in point 5 with its call shape.

The wrong turn this spec exists to prevent is the subject-grammar
one: `git log --format=%s` reads fluently and is wrong four separate
ways, all of them silent. The file-state walk is the whole design.
