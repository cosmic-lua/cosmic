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
