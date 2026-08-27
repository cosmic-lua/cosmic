## Goal

G8 — the flow system (parent 3HyRdT1J). A mutation never lands on
state its guards did not see: losing the push race always drops the
mutation whole, re-syncs the checkout, and refuses with a line naming
the re-run — so the re-run verb re-applies EVERY gate against the
merged board, not just the WIP limit. Closes the class behind the
reciprocal-block cycle (`_work/health.tl` header) and the
last-two-children stranded parent.

## Change

Nine source files (two substantively, seven call-site trims), README,
and tests, all on the `board` branch.

**1. `_work/store.tl` (490 lines, shrinks) — publish refuses instead
of replaying.** `publish` loses the `Revalidate` parameter, the
`Revalidate` type, and the 3-attempt rebase-repush loop (line 403's
"publish did not converge"). New behavior: one push; on rejection,
`reset -q --hard HEAD~1` — exact, because `save` writes one mutation
as one commit — then `rebase_onto_remote` (nothing local remains, so
no conflict path), and return `false, store.LOST_RACE`.
`LOST_RACE < const >` is exported on the record: "lost the push race —
the mutation was dropped whole and the checkout re-synced; re-run the
verb against the current board". Update the module header's
rejected-push prose.

**2. `_work/gitgate.tl` (378 lines, shrinks) — no post-race
revalidate.** `commit_and_publish` becomes save-then-publish; the WIP
revalidate closure and its `from`/`force`/`vacated` plumbing are
deleted — a re-run verb re-applies `wip_refusal` (which keeps
`vacated` and force semantics up front, unchanged) and every other
guard against merged state, which is strictly more than the closure
re-checked. New signature:
`commit_and_publish(s, it, body, message, also?)`.

**3. Call sites trimmed to the new signature** (drop the trailing
`from`/`also-nil`/`force`/`vacated` arguments): `_work/gitverbs.tl`
lines 49, 240, 287; `_work/gitgraph.tl` 76, 134, 229;
`_work/gitreview.tl` 91; `_work/gitverdict.tl` 224;
`_work/gitcompare.tl` 68; `_work/gitgate.tl` 334 (`set_in_place`).

**4. `README.md` (97 lines).** The two rejected-push paragraphs now
say: a rejected push drops the mutation whole and refuses, naming the
re-run; the re-run applies every gate to the merged board. (The
matching sentence in `skills/work/SKILL.md` lives on `main` and is a
separate PR once this lands — noted in this PR's body.)

**5. Tests.**
- `_work/gitgate_test.tl` (~140 lines): the four rebase-revalidate
  cases become the new contract — a lost race returns
  `store.LOST_RACE` and the SECOND `commit_and_publish` (the re-run)
  publishes; the over-limit-arrival case's refusal now comes from the
  verb's own up-front gate on re-run, not from publish.
- `_work/store_test.tl`: `test_publish_cas_refuses_over_limit`
  becomes `test_publish_drops_a_lost_race`: the loser gets
  `LOST_RACE`, its local log equals origin's (commit dropped, synced),
  and its item file reads the remote's state.
- New `_work/publish_race_test.tl` over `fixture.init_shared`,
  pinning the two filed shapes end to end through real verbs:
  - `test_a_lost_block_race_cannot_land_a_cycle` — A publishes
    `block X on Y`; B, stale, runs `cmd_block Y on X`: the publish
    refuses with `LOST_RACE`, and re-running `cmd_block` on the
    synced checkout refuses naming the cycle. `status` reports no
    cycle at any point.
  - `test_a_lost_done_race_rephases_the_parent` — two children of one
    parent; A `cmd_done`s child1 and publishes; B, stale, `cmd_done`s
    child2: refused with `LOST_RACE`; the re-run computes
    `rephased_parent` against merged state and the parent returns to
    `backlog`.

## Non-goals

- No dispatcher auto-retry: the refusal names the re-run, and
  take-mode already falls to its next candidate on any refusal. An
  automatic re-run at dispatch is its own item if friction shows.
- No change to `sync`/`rebase_onto_remote` as `cmd_sync` uses them
  (the conflicted-rebase unwind there stays).
- No transient-push-failure retry: a push that fails for any reason
  is the same refusal, and the re-run costs one command.
- No change to `save`'s one-mutation-one-commit contract — it is what
  makes the drop exact.
- No change to `wip_refusal`, `force`, or `vacated` semantics at the
  up-front gate.
- No edit to `skills/work/SKILL.md` on `main` — different branch,
  different PR, sequenced after this lands.

## Acceptance

- `bin/cosmic --make ci` from the board worktree ends `ci: PASS`.
- `bin/cosmic --make test _work/publish_race_test.tl
  _work/store_test.tl _work/gitgate_test.tl` passes, including the
  three named tests.
- `grep -c "Revalidate" _work/store.tl _work/gitgate.tl` is 0 in
  both.
- `wc -l _work/store.tl` is under 490 and `wc -l _work/gitgate.tl`
  under 378 (measured 2026-08-27: 490 and 378) — the change shrinks
  both; every touched file stays at most 500.

## Enablement

none needed — board-branch modules only, gated by `bin/cosmic --make
ci` from the worktree, no blocker items. 3IUFODun's rework (PR 1461)
touches `store.tl`/`store_test.tl`/`gitverbs.tl` in different regions
(`history`, `cmd_spec`, EOF test appends vs. `publish`,
`test_publish_cas_refuses_over_limit`, call-site lines); whichever
merges second resolves textually trivial hunks.
