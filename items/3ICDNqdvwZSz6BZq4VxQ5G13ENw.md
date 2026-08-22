## Goal

G8 — the flow system. `land` is the phase that merges; an item may
only arrive there carrying a standing accept, and a verdict may not
outlive the head it judged.

## Evidence

2026-08-20 machinery audit of the board branch (at 5577fd73; still
true at board head `46f3f43b`). `_work/gitverbs.tl`'s `cmd_move`
gates target `ready` (the bar, line 322) and target `check` (a PR and
the handover, lines 336 and 340) and has NO gate for target `land`
(`grep -c 'target == "land"' _work/gitverbs.tl` is 0), while
`flow.admits_over_limit` admits any arrival into land. So
`move X check land` with no verdict is accepted. Two consequences:

1. **Livelock.** `action.phased_action` returns `finish` for
   `landing[1]` unconditionally, and `gitboard land` then refuses
   ("no accept" / "names no PR"), so `next` re-answers the same
   finish forever. The `pr == 0` variant is reachable through the
   tool alone via `move … check --force` followed by a normal accept.

2. **Stale accepts.** Nothing clears `verdict`/`verdict_head` except
   the next `cmd_verdict`, and a return clears only `claim`
   (`_work/gitverbs.tl`, the `flow.is_return` branch). So: accept
   (land), `move land do`, rework, `move do check`, `move check land`
   — unrefused — and `land` reads the OLD accept and merges a
   reworked, unreviewed head.

## Change

Two files, one new gate function and two branches in `cmd_move`.

1. **`_work/gitgate.tl` gains `land_refusal(it: item.Item): string`**
   — the refusal text for an item entering `land` without a standing
   accept, `nil` when it carries one. It refuses on two grounds, each
   naming what is missing:
   - `(it.verdict or "") ~= "accept"` →
     `a move into land carries a standing accept — <id8> has <what>`,
     where `<what>` is the verdict it does carry or `no verdict`.
   - `(it.pr or 0) == 0` →
     `a move into land names its PR — <id8> names none`.
   `wc -l < _work/gitgate.tl` is 274, so it has the room, and this is
   where `handover_refusal` and `wip_refusal` already live.

2. **`_work/gitverbs.tl` `cmd_move`** gains, beside the existing
   `target == "check"` branches and before the `item.problems` check:

   - `if target == "land" and not force then` → call
     `gate.land_refusal(it)` and return
     `gate.verdict_line("move", false, "REFUSED: " .. refusal)` when
     it fires. `--force` still passes, as it does for every other
     gate, and `--why` is already required with it.
   - beside the existing `if flow.is_return(from, target) then
     it.claim = "" end`: when the return leaves `check` or `land`,
     also clear `it.verdict`, `it.verdict_head` and `it.enable`. A
     leftward move out of the two judged phases means the judgment no
     longer describes the item, and leaving it behind is exactly what
     lets a reworked head merge on an old accept.

   `wc -l < _work/gitverbs.tl` is 464 — 36 lines under the cap, which
   the roughly 12 lines this adds fit inside.

3. **Tests.** `_work/gitgate_test.tl` (88 lines) gains
   `test_land_refusal`, covering an item with an accept and a PR (no
   refusal), one with `request changes`, one with no verdict, and one
   with an accept but `pr == 0`. `_work/gitverbs_test.tl` (408 lines,
   92 under the cap) gains `test_move_into_land_needs_an_accept` and
   `test_return_out_of_land_clears_the_verdict`, the second asserting
   `verdict`, `verdict_head` and `enable` are all `""` after
   `move land do`.

## Non-goals

- `flow.admits_over_limit` does not change: land stays exempt from the
  WIP limit, because an accept is a decision already made.
- `_work/gitverdict.tl` is not touched. An accept's own move into land
  is the verdict verb's, not `cmd_move`'s, and it writes the accept
  the new gate asks for — gating it there would refuse every real
  accept.
- `_work/gitland.tl` is not touched. Comparing `verdict_head` against
  the PR head at merge, and passing GitHub's `sha` guard, is item
  3ICDNJmQ's slice; this one stops a stale accept from ever reaching
  `land`, which is a different hole in the same wall.
- No change to the `gitboard-move:` verdict line format — `status` and
  the skill both read it.
- Returns stay unrefusable. This adds no gate to leftward motion; it
  only makes leftward motion drop what it invalidates.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/gitverbs_test.tl _work/gitgate_test.tl`
  ends `test: PASS`, including `test_land_refusal`,
  `test_move_into_land_needs_an_accept` and
  `test_return_out_of_land_clears_the_verdict`.
- `wc -l < _work/gitverbs.tl` ≤ 500 and `wc -l < _work/gitgate.tl` ≤ 500.
- `grep -c 'target == "land"' _work/gitverbs.tl` is 1 (it is 0 today).

## Enablement

none needed — `gate.handover_refusal` is the exact precedent for the
new function's shape and call site, `flow.is_return` already computes
leftward motion, and the `--force`/`--why` pairing is enforced by
`gate.force_refusal` before any of this runs. The wrong turn to
predict is gating the accept path too: `cmd_verdict` moves an accept
into land without going through `cmd_move`, so the gate must live in
`cmd_move` only — Non-goals states that, and the acceptance run of
`_work/gitverdict_test.tl` under `--make ci` catches it if missed.
