## Change

Evidence (fresh-context sweep 2026-08-30, re-verified by the #1547
review's probe (a)): a PR-less item can be completed with no review at
all, while both doctrine and the tool's own guards assume it cannot.
`cmd_verdict` hard-refuses any item with `pr == 0` ("has no PR — a
verdict judges a diff"), so a research item can never receive a
verdict — yet `cmd_done` ends ANY item via `done ID` with no review,
verdict, or identity check when `it.pr == 0`. skills/work/SKILL.md
already promises "a research item takes the same verdicts, re-running
its recorded checks in place of a diff" — the tool contradicts it.
The two quality gates exist for diff-carrying work and silently do
not exist for evidence-only work.

The change, the least pair that closes the bypass:

1. `_work/gitverdict.tl`: `cmd_verdict` permits a verdict on a
   PR-less item. No `--head` is required there (record `verdict_head`
   empty); the already-judged pair-guard degrades to the spec
   revision alone for such items (an unchanged spec refuses a second
   verdict with the existing guidance); the distance guard applies
   exactly as for PR items (builders/speccers refused; `--force
   --why` is the audited repair). The reviewer's job on such an item
   is the SKILL.md sentence: re-run the spec's recorded checks.
2. `_work/gitverbs.tl`: `cmd_done` on a PR-less item requires a
   recorded `accept` verdict, mirroring how PR items require the
   merge to be real; the refusal names what is missing and that
   `--force --why` exists for repair (e.g. ending obsolete items —
   the live flow this session used repeatedly and which must keep
   working through force with a why).
3. Historical tolerance: already-completed PR-less items are stored
   state, not re-validated — decode and reads untouched.

Tests in `_work/gitverdict_test.tl` and `_work/gitverbs_test.tl`
(runner/legacy per each file's convention): a PR-less verdict records
(accept and request changes); the spec-revision pair-guard refuses an
unchanged re-record; done on a PR-less item without accept refuses,
with accept completes, with `--force --why` completes; PR-carrying
paths unchanged. Mutation-verify the done gate (drop the accept
check, watch its refusal test go red).

## Non-goals

No `next`/`flow.substate` routing for research reviews (follow-up if
the manual routing bites); no new schema fields or flags; no decode
changes; no SKILL.md edit (the tool moves to match the prose).
