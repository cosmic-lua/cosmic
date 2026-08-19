## Goal

G8 — the flow system: the measurement G8 names is unbuilt. Every board
transition is one commit on the `board` branch, so `git log` over
`items/**` IS the flow record; the flow review (`skills/work/review.md`)
currently reads it by hand. This item builds the instrument that reads
it mechanically, replacing the deleted label-era `stats.tl`.

## Change

The three questions intake left open, settled. Measured 2026-08-19 on
the board branch:

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
   state. Subjects are consulted for exactly two things: the trailing
   `(forced: …)` marker (repairs, excluded from flow numbers and
   counted separately) and the verb word, which classifies a
   backward move as bounce (`move`) vs rework (`verdict … "request
   changes"`) vs reject (`verdict … reject`) — review.md's three kinds,
   with accepts explicitly not backward.
3. **What it reports** — the flow review's own list, so a review quotes
   the tool instead of hand arithmetic. Per phase: stint count, dwell
   median and max (minutes), peak concurrent occupancy against
   `flow.LIMITS`, minutes spent at-or-over the limit. Globally:
   accept / rework / bounce / reject counts, forced-move count,
   pickup latency (ready→do) median and max. Output one `key=value`
   line per number (the house instrument shape), then
   `gitboard-stats: <N> transitions over <window>` as the verdict
   line. `--since ISO8601` narrows the window; default is full
   history. `--dir` as every verb.
4. **Tests** (`_work/stats_test.tl`): `_work/fixture.tl`'s
   `init_state_repo` builds a scripted history (new → ready → do →
   check → verdict accept → done; one bounce; one forced move) with
   committer dates pinned via `GIT_COMMITTER_DATE` env per commit, so
   dwell numbers are exact; assert the table, the classification of
   all three backward kinds, the forced exclusion, and the pickup
   latency.

## Non-goals

- no persistence, no trend files, no chart output — one run, one
  table; history is re-derivable, which is the point of reading the
  log.
- no refusal counting: a refused mutation never commits (review.md
  documents this), so the tool cannot see it and must not pretend to —
  the report says so in a fixed footer line rather than omitting it
  silently.
- no change to `flow.LIMITS` or any verb's behavior; no skill edits
  (the flow review's hand method stays documented as the tool's
  definition).

## Acceptance

On the board worktree:

- `bin/cosmic --make test _work/stats_test.tl` ends
  `test: PASS (1 files)`.
- `o/bin/gitboard help` lists `stats`, and `o/bin/gitboard stats`
  against the live board ends with its `gitboard-stats:` verdict line.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — the measurement definitions are review.md's (the tool
implements that text, not a new theory), the git plumbing and fixture
harness exist at the cited lines, and the file-state walk removes the
subject-grammar ambiguity that would otherwise be the wrong turn.
