## Problem

`skills/work/parallel.md` still describes the pre-rewrite publish
contract, in the one paragraph an orchestrator reads before it spawns a
wave ("claim first, then spawn"):

> read each move's verdict line. a lost race is not a lagged index
> anymore: a rejected publish rebases onto whoever moved first,
> re-checks the limit against the merged board, and REFUSES explicitly
> if it now binds — re-read the board and continue, never `--force`

The merged `_work/store.tl` `publish` does none of that. On a lost race
it drops the mutation whole (`reset --hard HEAD~1`), re-syncs onto the
winner, and ALWAYS refuses with `store.LOST_RACE` — "lost the push race
— the mutation was dropped whole and the checkout re-synced; re-run the
verb against the current board" — regardless of whether any limit binds.
Nothing is rebased and re-checked; the verb is re-run.

The operational cost is specific to the orchestrator this paragraph
addresses: it says a lost race that does NOT bind the limit still lands
the claim. Under the merged code that claim was dropped. An orchestrator
following this paragraph spawns an agent onto an item it does not hold.

`skills/work/SKILL.md`'s "board in one minute" paragraph now tells the
drop-and-re-run story correctly, so the two chapters of one skill
currently disagree about the same mechanism.

## Change

Rewrite `parallel.md`'s "read each move's verdict line" sentence to the
merged contract: a rejected publish is diagnosed before anything is
destroyed; a lost race drops the mutation whole and refuses, and the
answer is to RE-RUN the verb (which re-decides with every gate against
the merged board), never `--force`. Say it without restating SKILL.md's
paragraph — one sentence plus the pointer is enough.

## Non-goals

- No machinery change; `store.publish` is correct as merged.
- No change to `SKILL.md` or `loop.md`.

## Acceptance

- `grep -n "rebases onto" skills/work/parallel.md` finds nothing.
- The paragraph names re-running the verb as the recovery.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Evidence

Found in the review of the standing-loop / CAS-paragraph change:
`_work/store.tl:350-409` (publish) and `_work/gitgate.tl:88-99` are the
merged behaviour; `_work/store_test.tl:221-287` and
`_work/publish_race_test.tl` pin it.
