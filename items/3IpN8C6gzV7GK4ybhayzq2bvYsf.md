## Evidence

Reconciling pawY_zI7x after its builder bounced:

    $ o/bin/gitboard spec 3Ip8xpkW... FILE --base BASE
    gitboard-spec: REFUSED: 3Ip8xpkW is claimed by build-pawY_zI7x-obs1 — rewriting another session's live build needs --force --why
    $ o/bin/gitboard drop pawY_zI7x --why ...
    gitboard-drop: REFUSED: 3Ip8xpkW is build-pawY_zI7x-obs1's live claim — the builder drops their own work; abandon a dead session's with --force

Both succeeded with `--session build-pawY_zI7x-obs1`. Under `help
orchestrate` the builder never runs gitboard, so "the builder drops
their own work" names a path that does not exist for a minted claim,
and the text steers toward `--force`. Refusal text:
`_work/gitverbs.tl:294` (drop); the spec refusal is in
`_work/gitverbs.tl` or `_work/gitclaim.tl` (grep `rewriting another
session's live build`).

## Change

In both refusals, when the claimant matches the minted shape
(`^(build|review|research|refine|decompose)-`), say: "the claim was
minted by an orchestrator — pass `--session <claimant>` to act as it;
`--force --why` only abandons a dead session". Keep the current text
for a session-derived claimant.

`_work/gitverbs_test.tl` (or `gitclaim_test.tl`): both refusal texts
under a minted claimant and under a UUID claimant.

## Non-goals

No change to who may drop or spec; only the message.
