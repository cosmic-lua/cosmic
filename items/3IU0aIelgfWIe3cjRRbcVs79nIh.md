## Capture

With N concurrent workers, the board's claiming covers only the do
phase (`move ID do` stamps the session), so the unclaimed phases
duplicate work. Observed 2026-08-27, ~4 sessions active:

- Reviews are unclaimed: 3ISSFrCO/#1439 got two full independent
  verifications (checkout, fetch, ci, acceptance greps — minutes of
  builds each); the second session's `verdict` was refused only
  AFTER its work was done ("in no phase", 0e714d6a's accept landed
  30s earlier). The @session on a check item is the BUILDER, not a
  reviewer claim.
- Pre-do refinement races: 3ITpcO21 was respecced by one session
  while another moved it ("is already in ready" mid-flight), and a
  scheduled wake would have re-executed it had its prompt not said
  verify-first; the item was finished by a third path (#1434).
- The shared root: expensive work happens BEFORE the board write
  that would have signaled it. Git already provides optimistic
  concurrency — a claim is a commit, first push wins, the loser's
  push rejects — but only if the claim is pushed before the work.

Candidate changes, for refinement to settle:
1. A reviewer claim in check — stamped and pushed before
   verification starts; checkers sync first and skip items under
   review by a live session.
2. Claim-aware `next` — skip claimed items, jitter ties, so N
   workers fan out instead of converging on the top item and racing.
3. The discipline written into skills/work: push the claim, then
   work; a rejected push means someone else has it. Claims carry a
   timestamp and go poachable past a horizon, or a crashed worker
   holds a lock forever.

Non-candidate: pessimistic locking. Push-rejection already
arbitrates; today's loss was one duplicated review plus spec churn,
and WIP limits cap the blast radius. The mechanism lives in gitboard
on the board branch; the discipline lives in skills/work.
