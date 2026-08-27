## Goal

G8 — the flow system: a review is claimed the way a pull is, so two
sessions never verify the same diff. Measured 2026-08-27 (~4 sessions
active): 3ISSFrCO/#1439 got two full independent verifications —
checkout, fetch, ci, acceptance greps, minutes of builds each — and
the second session learned of the first only when its `verdict` was
refused, AFTER the work. `do` already has the answer (`move --claim`
is the lock, a lease with staleness and --force takeover); `check`
has nothing: the `claim` field there names the BUILDER, and
`reviewable()` hands the same item to every non-builder that asks.

## Change

The board's own claim doctrine, extended to reviews — the claim is
pushed BEFORE the work, and the board commit is the lock.

1. `_work/item.tl`: `reviewer: string` field ("" when unclaimed);
   the root-shape validation refuses it on roots alongside claim/pr.
2. `_work/gitreview.tl` (new; gitverdict's sibling — `_work/review.tl`
   already holds the PR preconditions): `review ID [--session]
   [--force --why]` claims the review. Refusals: an unnamed session
   (a claim by nobody excludes nobody — name it via GITBOARD_SESSION
   or --session); an item not in `check`; a session that built the
   item (same `built_by` rule as verdict, claim + durable builders);
   a LIVE foreign reviewer without --force --why. A stale one is
   anyone's, like every other lease.
3. `_work/health.tl`: `REVIEW_LEASE_S` (1 hour — review dwell is
   minutes, against the 4-hour build lease) and `is_review_stale`.
4. `_work/flow.tl`: `built_by` moves here from `action.tl` (both
   action and gitreview consult it; one definition).
5. `_work/gitverdict.tl`: every verdict clears `reviewer` — the claim
   is consumed by the judgment. A verdict from a session other than
   the claimant is NOT refused: the claim is mutual exclusion, not
   authority, and refusing would wedge a takeover.
6. `_work/gitverbs.tl` move: leaving `check` clears `reviewer`.
7. `_work/action.tl` `reviewable()`: skips items whose reviewer is
   live and foreign (counted and named in the reason like held `do`
   items), so `next` fans concurrent reviewers out instead of
   converging them on the top diff.
8. `_work/guidance.tl` ["review"]: claim-first — the first line
   becomes `review ID` as the lock, before reading anything.
9. `_work/gitboard.tl`: the `review` verb's CLI entry (usage, flags,
   dispatch, mutation set) — help stays generated from the CLI.
10. skills/work on main: review.md's procedure gains the claim step
    (its own PR to main; the skill says what verbs are FOR, and
    claim-before-read is procedure, not verb reference).

## Non-goals

No plan/ready refinement claims: moves are already serialized by
push-as-CAS, WIP limits cap the racers, and the measured waste there
was spec churn, not builds — revisit if measured. No jitter in
`next`: reviewer claims make the fan-out (the second reviewer sees
the claim and takes the next item), so determinism stays. No change
to do-claim semantics or the 4-hour lease. No reviewer authority:
verdict stays valid from any non-builder.

## Acceptance

On the board branch, from its worktree: `bin/cosmic --make ci` ends
`ci: PASS`. New tests pin: claim then foreign claim refused; stale
foreign claim taken with --force --why (and offered without force
once stale); builder refused; unnamed session refused; verdict
clears the claim; move out of check clears it; `reviewable()` skips
a live foreign reviewer and the reason names it; `is_review_stale`
horizons. `gitboard help review` prints the verb. Two-session
walkthrough by hand: A `review ID` then B `review ID` → B refused
and B's `next` names a different item (or none).

## Enablement

None: the lease, session identity, force/why grammar, and the gate's
commit-and-publish all exist; this composes them.
