## Goal

G8 — the flow system: an over-limit column must stay editable, because
the mutations that drain it (spec refinement, blocker bookkeeping) are
exactly the ones being refused. Today they fail only when their push
loses a race, so the same command has three different outcomes.

## Evidence

Observed 2026-08-17 with `plan` at 20/12: `gitboard spec 3I3z2gOF <file>`
— no phase change — refused twice with `refused after concurrent update:
plan is over 12 after a concurrent move`, then succeeded unchanged once
the racing session went quiet.

Mechanism, measured 2026-08-19: `_work/gitgate.tl`'s
`commit_and_publish` (lines 88–110) re-checks the WIP limit on the
rebase path with `#(b[it.phase]) > limit and not
flow.admits_over_limit(from, it.phase)` — it never asks whether this
mutation ARRIVES. The callers already state that: `spec`
(`_work/gitverbs.tl:231`), `block`/`unblock` (`:208`), and
`compare`/`uncompare` (`_work/gitcompare.tl:68`) all pass
`from = it.phase`; entries (`new` `:85`, `attach` `:140`) pass `nil`;
`move` (`:333`), `done` (`:380`), `verdict` (`_work/gitverdict.tl:96`)
pass the real departed phase. So `from == it.phase` identifies a
non-arriving write exactly, with no caller changes.

## Change

1. **`_work/flow.tl`** (423 lines, 77 of headroom): add a pure
   predicate beside `is_return`/`admits_over_limit`:

   ```teal
   --- Whether a mutation adds an item to `to`: entries (nil `from`)
   --- and cross-phase moves arrive; a write that leaves the item where
   --- it stands (`from == to`) does not.
   local function is_arrival(from: string, to: string): boolean
     return to ~= "" and from ~= to
   end
   ```

   Export it from the module record.
2. **`_work/gitgate.tl`** (257 lines): in `commit_and_publish`'s rebase
   callback, refuse only when `flow.is_arrival(from, it.phase)` AND the
   count exceeds the limit AND not `flow.admits_over_limit(...)`.
   Reword the refusal — the current text blames "a concurrent move"
   whether or not any move happened:
   `("%s is over %d and this mutation arrives into it"):format(it.phase,
   limit)`. Update `from`'s @param doc: "phase the mutation left; equal
   to `it.phase` for a write that moves nothing, nil for an entry".
3. **`_work/flow_test.tl`** (145 lines): pin the predicate's truth
   table: entry arrives, cross-phase move arrives, same-phase write does
   not, de-phasing (`to == ""`) does not.
4. **`_work/gitgate_test.tl`** (new file): using
   `_work/fixture.tl`'s `init_shared` (two clones over one bare remote,
   the same harness `_work/store_test.tl`'s
   `test_publish_cas_refuses_over_limit` uses), pin both sides: a spec
   write (`from == it.phase`) on an over-limit column publishes after
   losing a race; a move into the same over-limit column is still
   refused, with the new message.

## Non-goals

- no change to `store.publish`'s CAS shape or to `flow.LIMITS`.
- no change to the up-front (pre-push) `wip_refusal` in `cmd_new`/
  `cmd_move` — whether a net-zero `new --parent` should count its
  parent's de-phase is a separate item (filed as its own capture, with
  2026-08-19 evidence).
- no caller changes: the `from` conventions above are already in place.

## Acceptance

On the board worktree:

- `bin/cosmic --make test _work/flow_test.tl _work/gitgate_test.tl`
  ends `test: PASS (2 files)`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -n "is_arrival" _work/flow.tl _work/gitgate.tl` shows the
  predicate defined, exported, and consumed in the rebase callback.

## Enablement

none needed — the fixture harness this needs already exists
(`_work/fixture.tl`), and the caller-side `from` conventions are
measured above rather than assumed.
