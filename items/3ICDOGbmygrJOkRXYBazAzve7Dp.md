## Evidence

2026-08-20 machinery audit of the board branch (at 5577fd73; still
true after #1298/#1299 — #1257's title says honour-system rules
became refusals, but builder distance did not). `action.tl`'s
`reviewable` skips only `claim == session`, and the rework path
merely PRINTS "hand it back with --claim <session>":
`cmd_move` neither requires nor verifies a claim on the do→check
handover, and `cmd_verdict` takes no `--session` at all. Scenario: A
builds, reviewer bounces (claim stays A by design); B takes over the
rework and moves it back to check WITHOUT --claim B; `next --session
B` now hands B the verdict on B's own build. Corollary: an item
pulled without --claim is unclaimed in check and offered to everyone,
including its builder. Fix shape: `move … check` requires the mover
to identify itself (or inherits the last mover's session), and
`verdict` takes --session and refuses when it matches the claim.

## Confirmed live, 2026-08-20 — the predicted scenario ran

The "Scenario" above happened, exactly as written, in a scheduled
session later the same day. It is no longer hypothetical.

3I1J9Xhg (coverage floor becomes a literal, PR #1295): built by
`claude-cloud-yv5jl8`, bounced `request changes`. Session `dji1my`
took the rework, pushed `07ac88c4`, and moved it back with
`move 3I1J9Xhg check --pr 1295` — WITHOUT `--claim dji1my`. `next`
had printed the advice ("rework of claude-cloud-yv5jl8's build — hand
it back with --claim dji1my") and it was not followed. The next call:

    gitboard-next: review 3I1J9Xhg … — check is the rightmost phase
    awaiting a decision — verdicts before new work

`next --session dji1my` offered dji1my the verdict on the head dji1my
had just pushed. Only an operator instruction ("never accept work this
session built") stopped it; the tool's own withholding did not fire,
because `claim` still read `claude-cloud-yv5jl8` and the claim is the
only thing `reviewable` consults.

Two further observations from the repair, both sharpening the fix:

1. **There is no verb to correct a claim.** `move ID <its current
   phase> --claim X` is a no-op that drops the flag silently:

       $ gitboard move 3I1J9Xhg check --claim dji1my
       gitboard-move: 3I1J9Xhg is already in check
       (claim still claude-cloud-yv5jl8)

   The repair was a leftward-then-rightward round trip —
   `move … do --claim dji1my` then `move … check --pr 1295 --claim
   dji1my` — which works only because a return is never refused, and
   which writes two spurious transitions into the item's history that
   a flow instrument (3I4BaVrL) will later read as real dwell.

2. **A no-op move silently discarding `--claim`/`--pr` is the wider
   bug.** The flags are accepted, the command exits 0, and nothing
   says the write did not happen. Either a same-phase `move` should
   apply its field flags (it already re-validates the item), or it
   should refuse the flags rather than swallow them.

So the fix shape above holds, plus: whatever records a session on the
handover must be settable WITHOUT a phase change, or the only repair
path corrupts the transition history it is trying to keep honest.
