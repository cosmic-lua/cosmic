A mutation that changes no phase is refused by the phase-limit re-check whenever
its push loses a race, so an over-limit column becomes intermittently
un-editable — exactly when refinement, the thing that drains it, is what the
board needs.

Observed 2026-08-17 with plan at 20/12: `gitboard spec 3I3z2gOF <file>` (a spec
sidecar replacement, no phase change) was refused twice with
`gitboard-spec: refused after concurrent update: plan is over 12 after a
concurrent move`, then succeeded unchanged on the third try once the other
session (which was pushing `spec 3I06cBmI` and `move 3I06cBmI plan -> ready`)
went quiet. Same command, same input, three different outcomes.

Mechanism: `_work/gitgate.tl:89-107`. `commit_and_publish` passes a callback to
`store.publish` that runs only on the rebase path (a rejected push). It re-reads
the merged board and refuses when `#board[it.phase] > LIMITS[it.phase]` and
`flow.admits_over_limit(from, it.phase)` is false. For `spec` — and for `block`,
`unblock`, and any other verb that writes an item without moving it — `from` is
nil and `it.phase` is whatever phase the item already sits in, so the check asks
whether that phase is over its limit rather than whether THIS mutation is an
arrival. It is not an arrival: the count is identical before and after. The
refusal is therefore driven entirely by pre-existing state plus a lost race,
and it drops the local commit whole, so the work has to be re-applied.

Two things to fix, arguably: the gate should re-check the limit only for a
mutation that actually adds to a phase (a `from` different from `it.phase`, or
an entry from nothing), and the message should not say "after a concurrent move"
when neither the local mutation nor the remote one was a move.
