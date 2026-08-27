## Goal

G8 — the flow system (parent 3HyRdT1J). The review distance holds
mechanically for orchestrator waves: a session is never offered — and
the verdict verb never accepts from it — a judgment on work built
under an identity it minted (`<session>/<suffix>`, the form
skills/work/loop.md fixes on `main`).

## Change

One source file and two test files, on the `board` branch.

**1. `_work/flow.tl` (490 lines — 10 of headroom, so the addition is
compact).** `built_by` compares names by their ROOT: the name up to
the first `/`, the whole name when it has none. A small local
`root(name: string): string` above `built_by`; the claim comparison
and the builders walk compare `root(x) == root(session)`. The doc
comment gains the rule: `/` is the wave separator — an orchestrator
mints per-agent claims as `<its own id>/<suffix>`, so everything under
one root is one session for review distance, while claim LOCKS
elsewhere stay exact-string and are untouched by this. A name with no
`/` roots to itself, so every existing identity (UUIDs,
GITBOARD_SESSION values, USER-HOSTNAME) behaves exactly as before.

**2. `_work/flow_test.tl` (197 lines) — `test_built_by_roots_names`:**
an item with `claim = "orch/3IVKVslE"` is built by `"orch"` and by
`"orch/anything"`, not by `"orchid"` (prefix means the `/` boundary,
not string prefix) and not by `"other"`; `builders = {"orch/a"}` after
the claim moved on answers the same; plain names still compare
exactly.

**3. `_work/action_test.tl` (grep `built_by` shows the reviewable walk
consults it) — one case:** a `check` item whose builders carry
`"orch/x"` is not offered as a review to session `"orch"` (skipped as
mine), and is offered to `"other"`.

Measured 2026-08-27 at board head: `wc -l _work/flow.tl` 490,
`_work/flow_test.tl` 197; `built_by` is flow.tl's only reader of
`builders`.

## Non-goals

- No change to claim LOCKING: `set_in_place`, `cmd_move`'s takeover
  guard, and every draw (`unheld`, `refinable`, `pullables`) compare
  exact strings — an orchestrator's own `next` still sees its agents'
  claims as held, which is correct (they ARE held, by its wave).
- No change to `session.resolve` or the identity ladder.
- No edit to skills/work/loop.md on `main`: its minted-identity form
  and verdict wall stand; this is the machinery half it names.
- No migration of existing items: no recorded name carries `/` today
  (`grep -l '"claim"] = ".*/' items/*.tl` is empty, measured now).

## Acceptance

- `bin/cosmic --make ci` from the board worktree ends `ci: PASS`.
- `bin/cosmic --make test _work/flow_test.tl _work/action_test.tl
  _work/converge_test.tl` passes, including the two new tests.
- `wc -l _work/flow.tl` is at most 500.
- Reverting the root comparison (back to exact equality) turns
  `test_built_by_roots_names` red while every pre-existing flow test
  stays green.

## Enablement

none needed — flow and its tests on this branch, gated by `bin/cosmic
--make ci` from the worktree. 3IVJUjX4 (verdict reads `built_by`) is
complementary and independently mergeable: once both land, the verdict
verb inherits prefix awareness with no further change.

## Evidence

Found 2026-08-27 while specifying the looped orchestrator (`/work N`,
skills/work/loop.md on main).

`parallel.md` requires an orchestrator to mint a distinct session name
per agent (the claim is the lock, and N agents cannot share the
orchestrator's one environment identity). But `flow.built_by`
(`_work/flow.tl`) matches claim and `builders` entries by exact string
equality, so the board sees no relationship between the orchestrator and
the names it minted: `next` run under the orchestrator's own identity
offers it verdicts on the PRs its own wave built, and `gitverdict`'s
own-build refusal passes them too. A loop that reviews its own wave is
one session merging its own work with extra steps; today only prose
(loop.md's "verdict wall") prevents it. loop.md pins the minted form to
`<session>/<suffix>` so provenance is at least readable in the log — the
machinery half would be `built_by` (and the verdict gate) treating a
name's `/`-prefix as the same session, making the review distance hold
mechanically for waves the way it already holds for lone sessions.
