## Goal

G8 — the flow system. "No session accepts its own work" is the
system's last gate; it must hold on the record of who built the diff,
not on a single mutable field that any later mover overwrites.

## Evidence

Observed 2026-08-21 on item `3I7LGcLa` (cosmos pin bump, wave 1). Two
sessions worked it 65 seconds apart:

```
12:46:57  move 3I7LGcLa ready -> do     claude-i66dkr claims it
12:47:35  spec 3I7LGcLa                 claude-3gubgy rewrites the spec
12:47:40  move 3I7LGcLa do -> ready     claude-3gubgy returns it
12:48:02  move 3I7LGcLa ready -> do     claude-3gubgy claims it
13:03:38  move 3I7LGcLa do -> check --pr 1301   claude-i66dkr hands over ITS work
```

`claude-i66dkr` built and pushed whilp/cosmic#1301; the item's `claim`
read `claude-3gubgy`, and `gitboard next --session claude-i66dkr`
answered `review 3I7LGcLa … — check is the rightmost phase awaiting a
decision`. That is the session being offered a verdict on its own PR.
It was declined by hand, not by the tool.

Two distinct holes produced it, and only one is an overwrite:

1. `_work/action.tl`'s `reviewable` consults `(i.claim or "") ==
   session` and nothing else, while `cmd_move` clears `claim` on every
   return (`flow.is_return`). So a return-then-repull moves the claim
   legitimately, and the first builder becomes eligible to review its
   own diff. This is what actually fired above: no overwrite was
   needed.
2. `move ID do --claim B` on an item already in `do` claimed by A
   overwrites it with no refusal, which reaches the same state
   directly.

The compare-and-swap did not fire, and could not: the moves were
sequential in time, so each rebased cleanly. Serialisation is not
mutual exclusion.

## Change

The claim stays a single-valued lease; what becomes durable is the
record of who has held it.

1. **`_work/item.tl` gains `builders: {string}`** on `Item` — every
   session that has held the claim on this item, oldest first,
   deduplicated. Stored the way `beats` and `blocked_by` already are:
   one space-joined string, decoded with `gmatch("%S+")` and encoded
   with `table.concat(it.builders, " ")`, omitted when empty. Session
   names carry no spaces (`claude-i66dkr`, `sched-n4i2ns`, `dji1my`),
   so the existing idiom holds. `problems` gains one rule beside the
   `blocked_by` and `beats` loops: `builders` repeating a name is a
   problem; it is NOT restricted to ksuids. `builders` is not listed
   in the "claim/pr/verdict/repo belong to worked items, not roots"
   rule — a root never gets one, because a root never takes a claim.
   `wc -l < _work/item.tl` is 275.

2. **`_work/gitverbs.tl` `cmd_move` appends before it writes.**
   Wherever `it.claim` is set from the `--claim` flag, append that
   session to `it.builders` when it is not already the last entry.
   The clear-on-return branch (`flow.is_return`) keeps clearing
   `claim` and does NOT touch `builders`: dropping the lease is the
   point of a return, and forgetting who built is the bug.
   `wc -l < _work/gitverbs.tl` is 464.

3. **`_work/gitverbs.tl` `cmd_move` refuses an in-place takeover.**
   When `from == target`, the move already refuses; the new refusal is
   for a claimed item whose `--claim` names a different session while
   the claim is live, i.e. `target == "do"`, `(it.claim or "") ~= ""`,
   `claim ~= it.claim`. Message:
   `REFUSED: <id8> is claimed by <A> — take over a live claim with --force --why`.
   `--force` performs the takeover and still appends to `builders`, so
   the takeover is legible in the log and the earlier builder stays
   disqualified.

4. **`_work/action.tl` `reviewable` consults `builders`.** Replace the
   `(i.claim or "") == session` test with "this session has held this
   item": the claim OR any entry in `builders`. A helper
   `built_by(i: item.Item, session: string): boolean` beside
   `reviewable` keeps the test in one place. The `mine` counter's
   meaning is unchanged — items in `check` this session built — it is
   now correct where it was optimistic. `wc -l < _work/action.tl` is
   458, 42 under the cap, which a helper of about eight lines fits.

5. **Tests.** `_work/item_test.tl` (203 lines) gains
   `test_builders_round_trip` (decode of a space-joined string, encode
   omitting an empty list, `problems` on a repeat).
   `_work/gitverbs_test.tl` (408 lines) gains
   `test_claim_appends_a_builder`, `test_return_keeps_builders`, and
   `test_live_claim_needs_force`. `_work/action_test.tl` (377 lines)
   gains `test_reviewable_skips_a_past_builder`, which reproduces the
   sequence above: A claims, the item returns, B claims, the item
   reaches `check`, and `reviewable` withholds it from A.

## Non-goals

- The claim stays ONE field and stays a lease. `builders` is history
  beside it, not a replacement; `_work/health.tl`'s staleness rule
  reads `claim` and does not change.
- `gitboard spec` is not touched. The capture's third direction —
  detecting that a sidecar changed since the session read it — is a
  different failure (a lost refinement, not a lost review gate) and
  is not in this slice.
- `builders` is never cleared while the item is open, including on a
  return, a reject back to `plan`, or a re-pull. Whoever built stays
  disqualified as reviewer.
- No change to `next`'s verdict-line wording beyond what a correct
  `mine` count already produces, and no new verb.
- `_work/gitverdict.tl` is not touched: making `verdict` itself take
  `--session` and refuse the builder is item 3ICDOGbm's slice.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/item_test.tl _work/gitverbs_test.tl
  _work/action_test.tl` ends `test: PASS`, including
  `test_builders_round_trip`, `test_claim_appends_a_builder`,
  `test_return_keeps_builders`, `test_live_claim_needs_force` and
  `test_reviewable_skips_a_past_builder`.
- `wc -l < _work/item.tl` ≤ 500, `wc -l < _work/gitverbs.tl` ≤ 500,
  `wc -l < _work/action.tl` ≤ 500.
- `grep -c builders _work/action.tl` is at least 1 (it is 0 today).

## Enablement

none needed — `beats` and `blocked_by` are the exact precedent for a
space-joined list field across `decode`, `encode` and `problems`, and
`gate.force_refusal` already requires `--why` with every `--force`, so
the takeover path needs no new machinery. The wrong turn to predict is
clearing `builders` alongside `claim` in the `flow.is_return` branch,
which would restore the bug this slice exists to close; Non-goals
states it and `test_return_keeps_builders` fails if it happens.
