## Goal

G8 — the flow system (parent 3HyRdT1J). The board machinery carries no
gate that can never fire: `new`'s WIP gate, its `vacated` credit, and
the `--force` escape documented as "override the plan WIP limit" are
deleted rather than left describing a refusal that cannot happen.

## Change

Four source files and the test call sites, all on the `board` branch,
all deletion.

**1. `_work/gitgraph.tl` (256 lines) — `cmd_new` loses the dead
gate.** A filed child always gets `phase = "backlog"` (line 43) and
`flow.LIMITS` has no `backlog` entry, so the gate at lines 60-70
(`vacated` read included) is unreachable — proven by mutation during
3IVKVXoO's review: neutralising the read leaves the whole suite green.
Delete the gate block and the `vacated` computation. With the gate
gone, `force`/`why` in `cmd_new` feed only `force_refusal` and
`forced_suffix` on a verb nothing refuses: remove both parameters from
`cmd_new` (and the `forced_suffix` call in its commit message).

**2. `_work/gitboard.tl` — `new` loses `--force`/`--why`.** The flags
at lines 81-82 (help text: "override the plan WIP limit" — provably
false) and the dispatch's two arguments go.

**3. `_work/gitgate.tl` (346 lines) — `wip_refusal` loses `vacated`.**
After (1), no live caller passes it (`grep -rn "vacated" _work/*.tl`
outside tests: only gitgraph 56-66 and gitgate's own signature/docs,
measured 2026-08-27). Delete the parameter, the `or vacated == to`
clause, the `vacated` paragraph in its doc comment, the mention in
`commit_and_publish`'s doc (line 91), and the record declaration.

**4. Tests.** `_work/gitgate_test.tl` (144 lines):
`test_the_merged_board_carries_the_wip_refusal` drops its
vacated-credit assertion (it exercised a credit with no live caller).
`fixture.file_item` loses its `force` parameter, and every call site
drops the argument — measured now: file_item appears 47 times across 8
test files plus fixture.tl's own 4 uses, and direct `cmd_new(` calls
outside its definition number 8. All mechanical one-line edits; the
"filled board" fixtures that passed `true, "test fixture"` simply stop
passing anything, since nothing they were escaping exists.
`gitverbs_test.tl`'s `test_a_decomposition_is_never_refused_by_a_full_board`
keeps its postconditions (the child lands, the parent de-phases) —
what changes is that no gate was ever in its way, which its comment
now says.

## Non-goals

- `wip_refusal` itself stays: `cmd_move` is its live caller and the
  arrival/return semantics are untouched.
- `force`/`why` stay on every verb that can actually refuse (`move`,
  `done`, `review`, `land`): this deletes the escape only where there
  is nothing to escape.
- No new gate: whether `new --parent` under a phased leaf SHOULD be
  bounded is a design question for the flow review, not this cleanup.
- No change to `dephased_container` or the one-commit decomposition.

## Acceptance

- `bin/cosmic --make ci` from the board worktree ends `ci: PASS`.
- `grep -c "vacated" _work/gitgraph.tl _work/gitgate.tl` is 0 and 0.
- `o/bin/gitboard help new` lists no `--force` and no `--why`.
- `bin/cosmic --make test _work/gitgraph_test.tl _work/gitgate_test.tl
  _work/gitverbs_test.tl` passes.

## Enablement

none needed — deletions on this branch, gated by `bin/cosmic --make
ci` from the worktree; no blocker items. Wide but mechanical across
test files, so it merges last of this wave (3IVJUjX4, 3IVJVZJt touch
gitverdict/flow, disjoint from every file here).

## Evidence

Found 2026-08-27 during 3IVKVXoO's review (PR 1466), by mutation: the
reviewer neutralised the `vacated` read in `cmd_new` and the whole
suite stayed green at that head and at its base.

`cmd_new`'s up-front WIP gate cannot refuse anything: a filed child
always gets `phase = "backlog"` (`_work/gitgraph.tl:42`), and
`flow.LIMITS` deliberately has no `backlog` entry, so
`wip_refusal(board, nil, "backlog", vacated)` is nil for every input —
the gate, the `vacated` slot it reads from the parent-to-be, and the
`--force` escape documented around it are dead code. The same fact made
the deleted post-race revalidate dead for `cmd_new` too (its
`limit ~= nil` guard never armed), which 3ICDOfPj's fix could not have
known when it taught the closure the vacated credit. The cleanup is to
delete the dead gate and its `vacated` plumbing from `cmd_new` (the
credit stays real in `cmd_move`, where a de-phasing decomposition does
arrive in a bounded column), and to drop or repoint
`gitgate_test.tl`'s vacated assertion, which today exercises
`wip_refusal` directly rather than any live caller.
