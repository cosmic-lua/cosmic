All three ready/plan items under the G8 epic (`3HyRdT1JQS7pCPgF3sZi2Deo66q`) that
touch `_work/**` or its output were refined against a `_work/` architecture that
no longer exists on the `board` branch. This is not one item's ambiguity — it is
the whole batch:

- **`3I06cBmI`** ("land's merge failures are indistinguishable...", whilp/cosmic#1190)
  names `_work/github.tl` (`merge_pull`), `_work/implementer.tl` (`cmd_land`),
  `_work/implementer_test.tl`, `_work/model.tl`, `_work/verdict.tl`, all pinned to
  commit `a3cd318`.
- **`3I0L1TbU`** ("stats: --days must clip the numbers...", whilp/cosmic#1198)
  names `_work/stats.tl`'s `summarize` function and `_work/model.tl`/`_work/github.tl`.
- **`3I0L8yuR`** ("PR #1171 is stranded...", whilp/cosmic#1203) names
  `_work/stats.tl`'s report and doc comment, `_work/model.tl`'s `LIMITS` comment,
  `model.counts_against_limit`, `model.admits_over_limit`, and PR #1171
  (`claude/board-planning-review-mzdg5f`, to be un-drafted and given `Closes #1203`).

None of `_work/github.tl`, `_work/implementer.tl`, `_work/implementer_test.tl`,
`_work/model.tl`, `_work/verdict.tl`, or `_work/stats.tl` exist on `board` today.
`a3cd318`, the commit every one of these specs pins its facts to, is an ancestor
of `origin/main`, not of the orphan `board` branch — and `origin/main`'s current
tip (`c5c03924`) carries no `_work/` directory at all. The actual `board`-branch
`_work/` is a different, later design: `gh.tl` (`merge(s, number)`, ad hoc 403
string handling already), `gitland.tl` (`cmd_land(s, id, force, why)`, built on
`store.Store` and `gate.verdict_line`), `flow.tl` (the real `LIMITS` table —
`plan=12, ready=12, do=5, check=10, land=3`, which does match what these specs
expect, so the LIMITS values survived the migration even though the module
holding them was renamed from `model.tl`). There is no `stats.tl` at all yet —
the instrument `3I0L1TbU` and `3I0L8yuR` both assume already exists has not been
built on this branch.

Best guess at the cause: these three issues (#1190, #1198, #1203) were filed and
refined against a period when the board/gitboard machinery briefly lived under
`_work/` on `main`, before it was migrated wholesale to the `board` orphan
branch's own (renamed, restructured) `_work/`. Nobody reconciled the specs
against the post-migration tree before they were marked `ready`.

An implementer session (2026-08-17) claimed `3I06cBmI`, hit the mismatch,
confirmed it was total rather than a partial ambiguity (every fact-block command
in the spec fails or disagrees against the real tree), and bounced it back to
`plan` rather than improvising a redesign. The orchestrating session then
checked `3I0L1TbU` and `3I0L8yuR` against the same real tree before claiming
either, found the identical problem, and returned both to `plan` directly
without spending an implementer cycle on either.

Refining any of these three again needs someone to re-derive the "Change"
section against `_work/gh.tl` / `_work/gitland.tl` / `_work/flow.tl` as they
exist on `board` today, decide whether `_work/stats.tl` is built first as its
own slice (a real net-new instrument, not a signature change to an existing
one), and decide how the frozen "verdict vocabulary" concepts these specs
assume (`work-land: REFUSED/ERROR/success`, `board.tl stats --days`) map onto
`gitland.tl`'s actual `gate.verdict_line` convention and the real `gitboard`
binary name, since none of these match today's tool as written.
