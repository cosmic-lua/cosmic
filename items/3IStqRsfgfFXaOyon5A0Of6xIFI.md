## Goal

G8 — the flow system. `move ID check --evidence` is the handover a
research slice needs, and today it cannot complete on the real board:
the handover still asks GitHub about PR #0. This makes the flag work.

## Evidence

`move ID check --evidence` — landed 2026-08-26 as PR #1417 (`board`
`c2b5edde`), the whole point of which is a handover that carries no PR
— is unreachable on the real board. The FIRST attempt to use it, on
item `3ISWHyP7`, was refused:

```
$ o/bin/gitboard move 3ISWHyP7 check --evidence
gitboard-move: REFUSED: cannot read PR #0: GET /repos/whilp/cosmic/pulls/0:
  HTTP 404: Not Found; --force to hand it over anyway
```

The cause, read at `board` `a1be06e5` (the machinery is unchanged
since `c2b5edde`: `git log --oneline c2b5edde..a1be06e5 -- _work/`
prints nothing):

- `_work/gitverbs.tl:151-157` — every move to `check` that is not
  forced calls `gate.handover_refusal(s, id, (pr or 0) ~= 0 and pr or
  it.pr, it.repo)`. PR #1417 added the `--evidence` branch ABOVE this,
  at `_work/gitverbs.tl:127-140`, and left this call unconditional, so
  an evidence handover reaches it with `number = 0`.
- `_work/gitgate.tl:171-193` — `handover_refusal` returns nil only
  when `store.has_origin(s)` is false; otherwise it calls
  `gh.pull(s, 0, repo)`, which 404s, and a failed read is deliberately
  a refusal rather than a silent pass.

So the only way an evidence handover completes today is `--force`,
which the `work` skill reserves for repair, not flow — and forcing
also skips the `## Result` check that `--evidence` exists to impose.

**Why the tests did not catch it.** `_work/gitverbs_test.tl`'s
`test_check_takes_an_evidence_handover_only_when_asked` passes because
`fixture.init_state_repo` builds a local-only store, so
`store.has_origin` is false, `handover_refusal` returns nil at its
first line and the GitHub path never runs. Every existing handover
test is in the same position: this class of gate is inert under the
local-only fixture. `fixture.init_shared` is the fixture that is NOT —
it clones over a bare remote, so `has_origin` is true — and it is what
the new test below uses.

**A shared-fixture test needs no network.** `_work/gh.tl:24-41`
resolves the repo from `git remote get-url origin` and requires a
`github.com[:/]owner/name` URL; `init_shared`'s origin is a local
path, so `gh.pull` returns `origin is not a github remote: <path>`
without any HTTP, and `handover_refusal` turns that into a refusal.
That is exactly the discriminating signal: the new test fails today
and passes with the fix, offline either way.

## Change

One guard, in `_work/gitverbs.tl`, plus one regression test.

1. **`_work/gitverbs.tl`** — the block at lines 151-157 reads:

   ```teal
   if target == "check" and not force then
     local refusal = gate.handover_refusal(s, id,
       (pr or 0) ~= 0 and pr or it.pr, it.repo)
   ```

   Extend its condition so the gate runs only when a PR number is
   actually in hand:

   ```teal
   if target == "check" and not force
   and ((pr or 0) ~= 0 or (it.pr or 0) ~= 0) then
   ```

   Nothing else in the block changes. Add a sentence to the comment
   above it (or a new one) saying why: an evidence handover names no
   PR, so there is nothing for this gate to read and nothing for it to
   say — which is not the same as the "cannot see" case
   `_work/gitgate.tl:158-168` deliberately refuses, and leaving that
   property intact for every PR-carrying handover is the reason the
   skip lives at the CALL SITE rather than inside `handover_refusal`.

   Measured now: `wc -l _work/gitverbs.tl` is 297 — 203 lines of
   headroom under the 500-line cap.

2. **`_work/gitverbs_test.tl`** — add one test function,
   `test_an_evidence_handover_asks_github_nothing`, called on the line
   after its `end` like every other test in the file. It must use
   `init_shared` (already bound at `_work/gitverbs_test.tl:23`), NOT
   `init_state_repo`, because a local-only store short-circuits the
   gate this test exists to cover:

   - `local a = init_shared("evidence-origin")` — the first clone;
   - `local _, leaf = root_with_leaf(a)`;
   - write `fixture.READY_SPEC .. "## Result\nMeasured, twice.\n"` to a
     file under `tmpdir` and install it with `verbs.cmd_spec`;
   - `cmd_move(a, leaf, "ready", "", 0, false, "")`, then
     `cmd_move(a, leaf, "do", "session-a", 0, false, "")`;
   - `assert(verbs.cmd_move(a, leaf, "check", "", 0, false, "", true) == 0)`
     — this is the assertion that fails today;
   - assert the loaded item's `phase == "check"` and `pr == 0`.

   Measured now: `wc -l _work/gitverbs_test.tl` is 380 — 120 lines of
   headroom.

## Non-goals

- **Do NOT change `_work/gitgate.tl`.** `handover_refusal`'s
  "a gate that waves things through when it cannot see is worse than
  no gate" property is deliberate and must keep holding for every
  handover that DOES name a PR. Teaching it to return nil for
  `number == 0` would move the decision away from the one call site
  that knows whether a PR was expected.
- **Do NOT touch the `--evidence` branch at `_work/gitverbs.tl:127-140`**,
  the `## Result` check, `has_result`, or the claim refusal at
  `_work/gitverbs.tl:145-150`. They are correct; only the gate below
  them is wrong.
- **Do NOT change `_work/gitverdict.tl`.** The accept-ends-a-PR-less-item
  path landed with PR #1417 and is not implicated.
- **Do NOT weaken or delete the existing
  `test_check_takes_an_evidence_handover_only_when_asked` or
  `test_an_evidence_handover_carries_a_result_section`.** They cover a
  different half; the new test is added beside them.
- **Do NOT make any test reach the network.** The shared fixture's
  origin is a local path and `gh.tl` rejects it before any HTTP; keep
  it that way.
- **Do NOT touch `items/**`.** This is a machinery change; no board
  state moves in the diff.
- **Do NOT rebase or force-push `board`.**

## Acceptance

Run from the `board` worktree, on a branch off `board`.

- `bin/cosmic --make ci` ends `ci: PASS`. (It also prints `ci: HEAD is
  not a descendant of origin/main` — expected: `board` is an orphan
  history.)
- `bin/cosmic --make test _work/gitverbs_test.tl` passes and reports
  `_work/gitverbs_test.tl (17 test functions)` — today it reports 16.
- The new test genuinely discriminates: with the one-line guard in (1)
  reverted, `bin/cosmic --make test _work/gitverbs_test.tl` FAILS.
  State in the PR description that this was checked and what the
  failure said.
- `grep -c 'init_shared("evidence-origin")' _work/gitverbs_test.tl` →
  `1` (today: `0`).
- `wc -l _work/gitverbs.tl _work/gitverbs_test.tl` — both ≤ 500
  (today: 297 and 380).

## Enablement

`none needed`. Every mechanism exists and is already used in this
file: `fixture.init_shared` backs four tests in `_work/gitgate_test.tl`
and one in `_work/gitverbs_test.tl`, `root_with_leaf` and
`fixture.READY_SPEC` are already bound at the top of
`_work/gitverbs_test.tl`, and `cmd_move`'s trailing `evidence?` flag
landed with PR #1417.

The one judgment a literal-minded session could get wrong — reaching
for `init_state_repo` out of habit, which makes the new test pass
whether or not the fix is present — is stated as a wall in `Change`
(2) and checked by the revert-and-fail step in `Acceptance`.

This item is what `3ISWHyP7` waits on: the moment it lands, that
slice's `## Change` step 4 becomes runnable as written.
