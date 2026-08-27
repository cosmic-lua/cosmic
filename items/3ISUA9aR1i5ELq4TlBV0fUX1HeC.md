## Goal

G8 — the flow system: a live claim survives backward motion the same
way it survives replacement. The observed incident (2026-08-26, item
3ISNVQBg): session 9d68ddeb moved 7b2d5794's mid-build item `do ->
ready` with no `--force`, the return path cleared the claim, and the
re-pull minted a fresh claim over work whose branch was already
pushed — the builder discovered the loss only at the handover refusal.
The forward guard (converged by 3ISONrYo, PR #1410) already holds a
live claim against replacement; this closes the backward door.

## Evidence

Measured 2026-08-27 on the `board` branch worktree (o/board), at the
head carrying #1410 and #1411.

- **The unguarded path.** `_work/gitverbs.tl`'s `cmd_move`: the
  claim-replacement guard (`:176-185`) fires only when a NEW claim is
  passed over a live different one — a backward move passes none —
  and `flow.is_return(from, target)` then clears `it.claim = ""`
  unconditionally (`:192-194`), with returns deliberately never
  WIP-refused. So `move <id> ready` on someone else's `do` item is
  accepted silently, and the follow-up `move <id> do --claim <me>`
  claims an empty field: the lease never judges liveness because the
  claim is gone before anyone reads it.
- **The mover's identity is derivable but not passed.**
  `_work/gitboard.tl:278-289`: the move dispatch fills `claim` from
  `session.resolve(nil)` only for moves TO `do`/`check`; every other
  move calls `cmd_move` with no notion of who is moving.
  `session.resolve` (`_work/session.tl:93`) returns the identity plus
  its source and is already what `next`/`verdict` use.
- **Headroom.** `wc -l _work/gitverbs.tl` → 304 (196 under the cap);
  `_work/gitverbs_test.tl` → 405 (95 under — enough for the two
  tests below); `_work/gitboard.tl` → check at pull, the edit there
  is ~3 lines.
- **What must stay free.** A return is the system correcting itself:
  the builder bouncing their OWN item (3ISKgfS6's bounce, 3ISSFN5u's)
  and a reviewer's verdict-driven moves (which go through
  `cmd_verdict`, not this path) must not gain a `--force` toll. Only
  the abandonment of a live FOREIGN claim out of `do` does.

## Change

Two files on the `board` branch, landed as a PR whose base is
`board`; gate with `bin/cosmic --make ci` in the board worktree.

1. **`_work/gitboard.tl`** — the move dispatch resolves the mover
   unconditionally: `local mover = session.resolve(nil)` beside the
   existing claim fill (keep the to-do/to-check claim fill exactly as
   is), and passes `mover` to `cmd_move` as a new trailing parameter.
2. **`_work/gitverbs.tl`** — `cmd_move` gains `mover: string`. Before
   the `is_return` claim-clear, one guard:

   ```teal
   if flow.is_return(from, target) and from == "do"
   and (it.claim or "") ~= "" and it.claim ~= mover
   and (claim or "") == "" and not force then
     return gate.verdict_line("move", false,
       ("REFUSED: moving %s out of do abandons %s's live claim — the "
         .. "builder returns their own work; take over a dead "
         .. "session's with --force --why"):format(
         id:sub(1, 8), it.claim))
   end
   ```

   The `from == "do"` bound is the decision, recorded here: `do` is
   the one phase where a claim means work in progress on a machine
   the board cannot see; a claim on `check`/`land` marks the builder
   for review distance, and reviewer-driven leftward motion out of
   those phases already flows through `cmd_verdict`. The doc comment
   above the guard says exactly this. `cmd_set`'s `set_in_place`
   path (`:99`) is untouched — same-phase edits do not clear claims.
3. **`_work/gitverbs_test.tl`** — two tests in the file's existing
   fixture style: a `do -> ready` move of an item claimed by
   `session-A`, moved with mover `session-B` and no force, is refused
   naming session-A and `--force --why`; the same move with mover ==
   claimant succeeds and clears the claim (the bounce stays free).
   Follow how existing tests drive `cmd_move` and thread the new
   parameter through every existing call site in the test file.

## Non-goals

- **No `cmd_verdict` change** — verdict-implied moves carry their own
  rules and already record who judged.
- **No staleness check inside the guard** — a dead session's claim is
  taken over with `--force --why`, exactly like the replacement path;
  lease-aware offering is `next`'s job (3ISONrYo) and stays there.
- **No change to `is_return`'s claim-clear or verdict-clear** for the
  moves that pass the guard; no WIP rule changes — returns stay
  exempt from limits.
- **No change to `set_in_place`, `--claim` semantics, or the
  to-do/to-check claim fill.**
- **Frozen:** the `gitboard-move:` verdict-line format; `--force
  --why` as the takeover spelling; `session.resolve`'s derivation
  order.

## Acceptance

Run from the board-branch worktree (`o/board` of a cosmic checkout).

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/gitverbs_test.tl` passes, including
  the two new tests.
- `grep -c "abandons" _work/gitverbs.tl` prints at least `1` (today
  `0`).
- Live probe, from a scratch clone of the state repo (the fixture
  helpers make one; do not probe the real board): a foreign backward
  move without `--force` prints `REFUSED` and leaves the claim
  standing; with `--force --why` it succeeds.
- `git diff --name-only board` lists exactly `_work/gitboard.tl`,
  `_work/gitverbs.tl`, `_work/gitverbs_test.tl`.

## Enablement

none needed. The incident trail is on 3ISNVQBg's history (board
commits b8fb59f8, 7fb86f04, and the forced repair 7775cfb6); every
cited line was read at refinement; the mover identity reuses the
existing `session.resolve`; and the one design bound (`from == "do"`)
is decided above, not left to the implementer.
