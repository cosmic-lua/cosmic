## Capture

Observed 2026-08-26 on item 3ISNVQBg. Session 7b2d5794 claimed it
(`move 3ISNVQBg do --claim 7b2d5794-...`) and was mid-build with the
branch pushed. Session 9d68ddeb then ran `move 3ISNVQBg do -> ready`
(board commit b8fb59f8) followed by `move ready -> do` with its own
claim (7fb86f04) — no `--force`, no `--why`, no takeover message.
The builder discovered the loss only when `move ... check --pr 1412`
was refused for a foreign claim, and resolved it with the forced
takeover the guard demands.

The forward guard (gitverbs' claim-replacement check, converged by
the 3ISONrYo fix in #1410) holds a LIVE claim against direct
replacement — but a backward move out of `do` appears to clear or
bypass the claim, and the subsequent re-pull mints a fresh claim over
work another session is actively building. The lease never gets to
judge liveness because the claim is gone before anyone reads it.

Likely shape of the fix: a phase move that would ABANDON a live
foreign claim needs the same `--force --why` the replacement path
demands; a backward move of one's own claimed item stays free.
Verify against `_work/gitverbs.tl`'s move paths before spec'ing.
