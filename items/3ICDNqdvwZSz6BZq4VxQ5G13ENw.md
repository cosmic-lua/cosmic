## Evidence

2026-08-20 machinery audit of the board branch (at 5577fd73; still
true after #1298/#1299). `_work/gitverbs.tl` `cmd_move` gates target
`ready` (bar) and `check` (PR + handover) but has NO gate for target
`land`, and `flow.admits_over_limit` admits any arrival into land —
so `move X check land` with no verdict is accepted. Two consequences:
(1) livelock — `action.phased_action` returns `finish` for
`landing[1]` unconditionally, and `gitboard land` then refuses ("no
accept" / "names no PR"), so `next` re-answers the same finish
forever, violating #1296's own contract; the pr==0 variant is
reachable through the tool alone via `move … check --force` followed
by a normal accept. (2) Stale accepts — nothing ever clears
`verdict`/`verdict_head` except the next `cmd_verdict`, and a return
(`move land do`) clears only `claim`; rework then `move do check`,
`move check land` (unrefused), and `land` sees the OLD accept and
merges the reworked, unreviewed head. Fix shape: gate `move` into
land on a standing accept, and clear verdict fields on any leftward
move out of land/check.
