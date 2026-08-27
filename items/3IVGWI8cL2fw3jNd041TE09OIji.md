## Goal

G8 — the flow system. `_work/gitverbs_test.tl` is where every verb refusal is
pinned, and it is 10 lines from the hard cap, so the next verb change fails
`cosmic --check lint` rather than the test it was written for.

## Change

Split `_work/gitverbs_test.tl` in two along the seam the file's own ordering
already shows, moving test bodies VERBATIM. No test is renamed, added,
removed, or edited; no source file changes. Measured now on `board` at
`7f3659f4`: `wc -l < _work/gitverbs_test.tl` is 490 (10 under the 500-line
cap) and `grep -c "^local function test_" _work/gitverbs_test.tl` is 21.

**1. New `_work/gitspec_test.tl`** — everything that judges the SPEC SIDECAR.
Move these 10 tests and the one helper they share, in their current order,
each with its leading comment:

- `test_the_ready_bar_is_the_items_own`
- `test_the_ready_bar_still_refuses_a_hollow_spec`
- `test_a_no_op_mutation_is_named`
- `spec_file` (the helper, defined before its first use)
- `test_spec_refuses_a_write_with_no_base`
- `test_spec_refuses_a_stale_base`
- `test_ready_bar_names_a_blocker_that_is_not_an_item`
- `test_ready_bar_wants_a_prose_blocker_mirrored_in_the_field`
- `test_check_takes_an_evidence_handover_only_when_asked`
- `test_an_evidence_handover_carries_a_result_section`
- `test_an_evidence_handover_asks_github_nothing`

**2. `_work/gitverbs_test.tl` keeps** the PHASE CROSSINGS: the remaining 11
tests (`test_a_decomposition_is_never_refused_by_a_full_board`, the two
`done` container tests, `test_move_records_the_pr`,
`test_wip_limits_bind_arrivals_but_never_returns`,
`test_force_states_its_reason_and_the_log_keeps_it`,
`test_a_full_plan_does_not_refuse_a_filing`, the two `land` tests, and the
two foreign/own backward-move tests) plus the `occupancy` and `fill_plan`
helpers, which only those tests use.

**No new source module.** `cmd_spec` stays in `_work/gitverbs.tl`; this is a
test file grouped by behaviour, which the branch already does —
`_work/gitclaim_test.tl`, `_work/action_pick_test.tl` and
`_work/converge_test.tl` each exist with no same-named source
(`ls _work/gitclaim.tl _work/action_pick.tl _work/converge.tl` finds none).

**Each half carries a header and only the imports it uses.** Lines 1-28 today
are a shebang, a 5-line file comment, 11 `require`s and 8 `fixture` aliases;
warnings are errors under `--check types`, so an import either half no longer
uses must not be copied into it. Write each file's comment to say what that
file holds — the sidecar half judges spec CONTENT, the verbs half judges
phase MOTION.

Measured expectation from the block sizes (each test's leading comment
through its call line, summed): about 225 lines for `gitspec_test.tl` and
about 294 for `gitverbs_test.tl`, so roughly 200 lines of headroom each.
The `Acceptance` caps below are the contract; these two figures are only the
reason to believe them.

**No coverage baseline rewrite.** The ratchet floors SOURCE files only —
`grep -c "_test.tl" .cosmic-coverage` is 0 — and the same 21 tests still
run, so `_work/gitverbs.tl 172 229` and every other row is untouched. If the
coverage stage nevertheless fails, run exactly the regen command its failure
message prints and commit the result; do not edit `.cosmic-coverage` by hand
and do not weaken a test to move a number.

## Non-goals

- No edit to any file under `_work/` that is not one of the two test files:
  `_work/gitverbs.tl`, `_work/gitgate.tl`, `_work/flow.tl` and the rest of
  the sources stay byte-identical.
- No edit to `_work/fixture.tl`. Both halves keep using the shared fixture;
  do not fork it, and do not move `spec_file` into it — it is used by one
  half only.
- No test renamed, no assertion reworded, no test body changed, and no test
  added or deleted. A verbatim move is what makes this reviewable as a
  split rather than a rewrite.
- No new `_work/gitspec.tl` source module, and no move of `cmd_spec` out of
  `_work/gitverbs.tl`.
- No `.cosmic-coverage` edit, no `--baseline` run, and no change to
  `.github/workflows/**` or `.cosmicignore`.
- No third file, and no further splitting of either half.

## Acceptance

- `bin/cosmic --make ci` from the `board` worktree ends `ci: PASS`, with its
  coverage stage reporting `coverage ratchet ok`.
- `bin/cosmic --make test _work/gitverbs_test.tl _work/gitspec_test.tl` ends
  `test: PASS (2 files)` and reports `_work/gitverbs_test.tl (11 test
  functions)` and `_work/gitspec_test.tl (10 test functions)`.
- `grep -c "^local function test_" _work/gitverbs_test.tl` is 11 and
  `grep -c "^local function test_" _work/gitspec_test.tl` is 10 — 21
  together, the same 21 as today.
- `wc -l _work/gitverbs_test.tl _work/gitspec_test.tl` — each at most 400,
  which is the point of the split (490 in one file today).
- `git diff --stat origin/board -- _work/gitverbs.tl _work/fixture.tl` is
  empty: no source and no fixture moved.

## Enablement

none needed — a mechanical split of one test file on this branch, gated by
`bin/cosmic --make ci` from the worktree. No blocker items; the tests being
moved are already green on `board`.
