## Goal

G8 — the flow system: one claim-liveness rule, shared by the router
and the guard, so `next` never offers what `move` will refuse. The
2026-08-26 incident (item 3IOCco6e / PR #1405): the builder pushed
their rework fix at 14:05; at ~14:13 `next` offered the item to
another session with "hand it back with --claim <you>" and no
`--force`; `move` refused it as a live-claim takeover; by then the
second session had duplicated the fix on the branch.

## Evidence

All in `_work/` on the `board` branch, read 2026-08-26 at `74523b4`+:

- **The carve-out**: `action.tl:105` and `:127` hold a live-claimed
  item from other sessions `and not is_rework(i)` — a rework item
  (any standing non-accept verdict, `is_rework` at `:67`) bypasses
  the hold entirely, whatever the claim's age. The comment at
  `:61–64` gives the reason: rework "actionable by exactly one
  session — and stranded ... the moment that session stopped waking".
- **The guard**: `gitverbs.tl:133–138` refuses ANY claim replacement
  over a non-empty claim without `--force --why`, with no rework and
  no staleness exemption. So the router's carve-out and the guard
  disagree by construction.
- **The guidance**: the rework-finish text (`action.tl:257–263`)
  prints `--claim <you>` with no `--force`; the stale-takeover text
  (`:266–268`) ALSO omits `--force`, which the guard demands there
  too.
- **The lease already bounds stranding**: `health.tl:35`
  `LEASE_S = 4h`; a claim older than that reads stale and is offered
  (`is_stale`, `:41–44`). So the carve-out's stranding argument is a
  4-hour-latency argument, and today's incident is its cost: a
  builder mid build-test-push loop looks board-idle exactly when most
  active.
- No test pins the carve-out: `grep -n "rework" _work/action_test.tl`
  finds none.

## Change

All on the `board` branch (`_work/**`), landed as a PR whose base is
`board`; gate with `bin/cosmic --make ci` in the board worktree.

1. **`_work/action.tl`** — remove the rework carve-out: drop
   `and not is_rework(i)` from the hold conditions at `:105`
   (`unheld`) and `:127` (`held_names`). A live-claimed item is held
   from other sessions whether or not a verdict stands on it; a stale
   one is offered, as today. Rewrite the `:61–64` comment: the lease
   bounds how long rework can strand on a dead session, and a LIVE
   claim over rework is the builder mid-loop, not a lock nobody
   released.
2. **`_work/action.tl:255–271`** — the `whose` guidance collapses:
   an offered item claimed by another session is now, by
   construction, stale — one takeover message, carrying everything
   the guard will demand:
   `(rework of X's build; claim stale Nh — take it over: move it with
   --claim <you> --force --why <reason>)`, with the "rework of X's
   build; " prefix only when `is_rework`. The separate live-rework
   branch at `:257–263` is deleted.
3. **`_work/action_test.tl`** — two tests: a rework item with a LIVE
   foreign claim is held (`next` skips it and counts it held); a
   rework item with a stale claim is offered and the guidance names
   `--force`. Follow the file's existing fixture style.
4. **Rejected, recorded here**: reading PR-branch pushes as claim
   keepalive. Reads are network-free by design (`README.md`: "Reads
   need no network and no token"), and with the carve-out gone the
   live-claim race it would have papered over no longer exists; the
   lease alone decides. If 4h proves slow for dead-session rework,
   the flow review retunes `LEASE_S` — it does not re-grow the
   carve-out.

## Non-goals

- No `gitverbs.tl` change: the guard's rule (any claim replacement
  needs `--force --why`) is the one being converged ON.
- No `LEASE_S` retune — that is `docs/flow-review.md`'s method, not
  this slice.
- No skill-prose edit on `main`: the `work` skill deliberately does
  not restate verb mechanics.
- The verdict-vocabulary item (3ISOOBBM) is its own slice.

## Acceptance

Run from the board-branch worktree:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "is_rework(i)" _work/action.tl` reports 0 in hold
  conditions — concretely, `grep -n "not is_rework" _work/action.tl`
  prints nothing (today: lines 105 and 127).
- `grep -c -- "--force --why" _work/action.tl` reports 1 or more
  (today 0) — the takeover guidance now names what the guard demands.
- `bin/cosmic --make test _work/action_test.tl` ends
  `test: PASS (1 file)` including the two new tests.
- `git diff --name-only board` lists exactly `_work/action.tl` and
  `_work/action_test.tl`.

## Enablement

none needed. The incident transcript is the reproduction; every cited
line was read at refinement; the change deletes a special case rather
than adding one.
