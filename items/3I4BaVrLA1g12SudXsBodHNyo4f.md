## Goal

G8 — the flow system, measuring itself. The board's own commit log
already records every transition; this reads it back as phase dwell
and transition counts, so a flow review argues from the log instead
of from impressions.

## Evidence

Measured 2026-08-22 at board head `e7cd0c84`. Every board mutation is
one commit with a structured subject, and
`git log --format=%s -60 | sort | uniq -c` over this branch shows the
grammar is already regular and already sufficient:

```
      8 spec ID8
      8 attach ID8 under 3HyRdT1J
      6 move ID8 ready -> do
      6 move ID8 plan -> ready
      6 move ID8 do -> check
      4 verdict ID8 accept (check -> land)
      4 done ID8 completed (from land)
```

Nothing reads this. The label-era `stats.tl` was deleted with the
label board, and the flow review in `review.md` — which tunes the WIP
limits — currently has no instrument behind it. `plan` sits at 48/12
and the case for cutting it is being made from impressions.

Two facts the parser must respect, both from the same sample:

- **Squash-merge commits share the log** and do not match the verb
  grammar: `verdict: an accept reads the request it judges (#1322)`
  is a PR title, not a `verdict <id8> <kind> (<from> -> <to>)`
  transition. Matching must be anchored and shape-driven, not a
  substring search for a verb name.
- **`verdict` subjects may carry a trailing ` by <session>`** since
  #1321, and older ones do not. The parse must accept both.

## Change

One new module, one new read verb, one small store change.

1. **`_work/store.tl`: `history` takes an OPTIONAL id.** Today
   `history(s, id)` appends `-- items/<id>.tl` to the `git log`. Make
   `id` optional (`id?: string`) and omit the pathspec when it is
   absent, returning the whole branch log. Three lines; nothing else
   changes. `wc -l < _work/store.tl` is 485, so there are 15 lines of
   headroom — **do not add more than that**; if this needs more,
   stop and report rather than restructuring the file.

2. **New `_work/flowstat.tl`**, pure over `{store.Event}` plus one
   `cmd_` that reads:
   - `record Transition { id: string, at: string, from: string, to: string, verdict: string }`
     — `verdict` is `""` for a plain `move`.
   - `parse(events: {store.Event}): {Transition}` — anchored patterns
     for the three transition subjects and nothing else:
     `^move (%S+) (%S+) %-> (%S+)$`,
     `^verdict (%S+) (.-) %((%S+) %-> (%S+)%)`, and
     `^done (%S+) (%S+) %(from (%S+)%)$` (its `to` is `""`, the item
     ending). Every other subject — `spec`, `attach`, `block`, `new`,
     `set`, and squash-merge PR titles — yields no transition.
   - `dwell(ts: {Transition}): {string: Dwell}` where
     `record Dwell { phase: string, entries: integer, median_s: integer, p90_s: integer }`
     — for each item, the time between entering a phase and leaving
     it, aggregated per phase. An item still in a phase contributes
     no interval (its dwell has not ended).
   - `counts(ts: {Transition}): {string: integer}` — `accept`,
     `request changes`, `reject`, `completed`, and `pulls` (any
     `ready -> do`).
   - `report(ts: {Transition}): {string}, string` — the lines, and
     the verdict detail, in this repo's report-plus-`cmd_` shape.
   - `cmd_stats(s: store.Store): integer` — reads
     `store.history(s)`, prints, ends `gitboard-stats:`.

   Timestamps are ISO 8601 from `%cI`. Parse them arithmetically
   (`(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)` plus the offset) — do NOT
   shell out and do NOT use `os.time` with a table, whose DST
   handling makes the result host-dependent.

3. **`_work/gitboard.tl`: a `stats` verb**, in the CSPEC beside
   `status` and `tree`, dispatching to `flowstat.cmd_stats`. It is a
   READ, so it does NOT go in `MUTATES`. `wc -l < _work/gitboard.tl`
   is 312.

4. **Tests.** New `_work/flowstat_test.tl`, pure over literal
   `store.Event` lists — no git, no network. Cover: the three
   transition shapes; a `verdict` subject WITH and WITHOUT the
   trailing ` by <session>`; a squash-merge PR title yielding no
   transition; dwell over a two-transition item; an item still in a
   phase contributing no interval; and the counts.

## Non-goals

- **WIP adherence over time is not in scope.** The capture names it,
  and it needs a per-instant reconstruction of the whole board rather
  than per-item intervals. This slice is dwell plus counts; the
  adherence series is its own item once these two are trusted.
- No new dependency, no JSON output, no file written. `stats` prints
  and exits.
- `_work/health.tl`'s staleness rule is untouched — it reads an
  item's last commit, not this.
- No change to any existing commit-subject format. This slice READS
  the grammar; changing it would invalidate the history it parses.
- No change to `status`, `tree`, `next` or their output.
- `_work/store.tl` gains the optional parameter and nothing else.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/flowstat_test.tl _work/store_test.tl`
  ends `test: PASS`.
- `o/bin/gitboard stats` prints a per-phase dwell line and a counts
  line and ends `gitboard-stats: ...` with exit 0, run from the board
  worktree.
- `o/bin/gitboard help stats` lists the verb.
- `wc -l < _work/flowstat.tl` ≤ 300, `wc -l < _work/flowstat_test.tl`
  ≤ 300, `wc -l < _work/store.tl` ≤ 500, `wc -l < _work/gitboard.tl`
  ≤ 340.

## Enablement

none needed — `_work/gitview.tl` is the worked precedent for the
report-plus-`cmd_` split this follows, `store.Event` already carries
exactly the three fields the parser needs, and `gitview_test.tl`
shows how a report is asserted over literal values without capturing
stdout. The wrong turn to predict is a substring match on the verb
name, which silently ingests squash-merge PR titles like
`verdict: an accept reads the request it judges (#1322)` as
transitions and corrupts every number the verb prints; `Change`
mandates anchored patterns and the test list names that exact case.
