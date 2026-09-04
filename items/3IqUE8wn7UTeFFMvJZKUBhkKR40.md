# friction: 2026-09-04 work9-a6f583ba (/work 9 --routine)

## orchestrator

- **Bare `take` binds the claim to the orchestrator's own single-claim
  session, silently, until a second `take` refuses.** Goal: claim a
  review item (`1j6D_hfCe`) so a fresh subagent could review it. What
  happened: ran `gitboard take 1j6D_hfCe` with no `--session`; it
  succeeded and bound the claim to my own orchestrator session
  (`reviewer: a6f583ba-...`), which is wrong per `help orchestrate`
  ("a distinct minted session name per agent") — had to `drop` it and
  re-derive. Same mistake recurred minutes later on a builder pull
  (`take EMdb_HFX2`, no `--session`): it succeeded silently, then the
  *next* `take djEO_SQWp` was refused outright ("REFUSED:
  a6f583ba-... already holds 3IqJ0yKp — one claim per worker"), which
  is what actually surfaced the mistake. Cost: 2 extra
  drop+retake round trips (4 extra `gitboard` calls, two board-log
  writes for the bogus claim+drop) plus the time to notice the first
  one on my own before it errored. Contributed: `help take`'s
  `--session` doc reads as optional ("Omit to derive it from the
  environment") with no forward warning that the derived (bare)
  session is the orchestrator's own one-claim identity, so nothing
  says "an orchestrator must never call take bare" until the second
  bare take collides. Improvement: a doc fix in `gitboard help take`
  and/or `help orchestrate` stating explicitly "an orchestrating
  session must always pass `--session <minted-name>`; a bare `take`
  binds to the orchestrator's own claim and the NEXT bare take will
  refuse" would have caught this on read instead of on the second
  collision. Filed as a candidate below — not filed as a board item
  yet (tool-doctrine wording call, not code; leaving for triage).

- **`done` on an item another concurrent session already completed
  errors instead of no-op-succeeding.** Goal: mark two accepted items
  (`wkmX_zNkM`, `eDVe_UY1D`) done after confirming their PRs merged.
  What happened: `gitboard done <id>` exited 1 with "nothing to
  record: done <id> completed (from accepted) leaves the board
  unchanged" both times — the board's shared state (this repo runs
  more than one `/work --routine` session concurrently against the
  same `board` branch) had already recorded completion between my
  `sync` and my `done` call. Cost: 2 failed calls plus the `sync`+
  `show` round trip needed to confirm the item was in fact already
  closed rather than actually broken. Contributed: no signal
  distinguishing "already done, no-op" from a real failure — same
  exit code and phrasing as a genuine bug. Improvement: `done` could
  exit 0 on a no-op-because-already-complete case (the state IS what
  the caller wanted), distinguishing it from an actual refusal.
  Tool-side fix, not something to file against this repo's items
  directly — noted for triage.

- **`merge_pull_request` fails 405 when a PR already has GitHub
  auto-merge queued.** Goal: merge PR #1670 for the accepted
  `wkmX_zNkM` item. What happened: the GitHub API call failed ("405
  Pull Request is in the merge queue") because the review agent (or
  the repo's own branch protection) had already enabled auto-merge on
  accept, per the review brief's own instruction ("enable auto-merge
  (squash) ... never merge directly"). Cost: one failed API call, no
  real delay (the PR merged on its own shortly after). Contributed:
  the orchestrator instructions don't say to check `auto_merge` state
  before attempting a manual merge for an item flagged `[accepted]`
  in `doing`. Improvement: minor — check the PR's mergeable/auto-merge
  state before calling `merge_pull_request`, or simply treat a 405
  here as "already queued, poll `done` readiness later" rather than a
  real error. Not worth a board item on its own; noted for triage.

- **Scheduled-wakeup fallback prompt sentinel mismatch under a
  cron-fired `/work --routine`, not `/loop`.** Goal: avoid actively
  polling while a review subagent ran, per "never wait inside a pass
  ... the single exception is a review subagent." What happened: used
  `ScheduleWakeup` with the `<<autonomous-loop-dynamic>>` prompt
  sentinel as a long fallback — but this session was invoked directly
  by a cron trigger firing `/work 9 --routine`, not by `/loop`. Had
  the fallback actually fired before the agent-completion notification
  arrived, the runtime would have resolved the sentinel to generic
  autonomous-loop instructions unrelated to this in-flight `/work`
  pass. It never fired (notifications always arrived first), so no
  actual harm this pass. Contributed: no clear documented equivalent
  for "long fallback timer, resume THIS specific task" outside a
  `/loop` context. Improvement: out of scope for this repo's own
  tooling — this is agent-harness behavior, not `gitboard`/cosmic. Not
  filed as a board item; noted here only because it is a real
  near-miss and the same situation recurs on every routine pass that
  waits on a review.

## candidates

- Clarify in `gitboard help take` / `help orchestrate` that an
  orchestrating session must always pass `--session <minted-name>`
  and that a bare `take` silently claims under the orchestrator's own
  single-claim identity — stays here for triage: this is a doc-wording
  call inside `_work/gitverbs.tl` or the help topic text, not something
  I can file as a self-contained fully-specced board item without
  picking the exact phrasing/location myself, which is a judgment call
  the doctrine reserves for a human or a refiner pass.
- Make `gitboard done` exit 0 (not 1) when the item is already
  completed and the call would be a no-op — stays here for triage:
  same reason, a CLI UX call in `_work/gitverdict.tl` or similar that
  needs its own spec.

## closing note

A concurrently-running orchestrator session on this same board also ran
a `/work 9 --routine` pass this session and already filed its own log
under the title `friction: 2026-09-04 work9` (handle «YIuP_EO8J»,
opened 2026-09-04T02:51:36Z) plus two countermeasure items already in
triage (`LmNB_gMXm`, `RxN2_253n`). This log is titled distinctly below
to avoid colliding with that one; it was written from this session's
own tool-call history only, not `_tool/friction.tl` against the
dispatched agents' transcripts (an omission — see below), so it is
lighter than that sibling log.

- **No friction-collection note included in any spawned agent's
  brief.** Goal: collect each dispatched agent's own account of
  friction, per `skills/work/friction.md`'s "what the agent reports"
  section (the standard closing paragraph asking for a `## Friction`
  section in the final report). Actually happened: none of the 7 build/
  research briefs and 6 review briefs this pass included that
  paragraph — it was never added to any spawned-agent prompt. Every
  agent's final report was read for narrative signs of friction (none
  surfaced anything beyond what's captured above), but no agent was
  asked directly, and this session never ran `cosmic _tool/friction.tl
  <transcript>` against any of the 13 dispatched agents' `.output`
  files to extract the numeric indicators (wallclock, tool calls,
  token counts, error/retry counts) `friction.md` calls for. Cost:
  this log's per-agent sections are absent entirely rather than merely
  thin. Contributed: the friction-collection paragraph never made it
  into this session's brief-construction habit; nothing in the `/work`
  skill's own bootstrap forces it into a brief the way the review/
  builder mechanics are forced through `gitboard brief`. Improvement:
  the biggest single fix available is mechanical — fold the
  friction-collection paragraph directly into what `gitboard brief`
  itself emits (builder/research/review/refine/decompose all), the
  same way the worktree path and the GitHub-reach note already ride
  along automatically, so an orchestrator cannot forget it by omission.
  That is a real code change to `_work/gitverbs.tl` (or wherever briefs
  are templated) — plausibly at the spec bar, but this session did not
  draft a spec for it, so it stays a candidate for triage rather than
  a filed item.

## candidates

- Clarify in `gitboard help take` / `help orchestrate` that an
  orchestrating session must always pass `--session <minted-name>`
  and that a bare `take` silently claims under the orchestrator's own
  single-claim identity — stays here for triage: this is a doc-wording
  call inside `_work/gitverbs.tl` or the help topic text, not something
  I can file as a self-contained fully-specced board item without
  picking the exact phrasing/location myself, which is a judgment call
  the doctrine reserves for a human or a refiner pass. (The sibling
  session's own log, `YIuP_EO8J`, independently hit the same "one claim
  per worker" refusal this pass — two sessions, same day, same gap:
  this is now a repeat, which `friction.md` names as exactly the
  signal a countermeasure is overdue.)
- Make `gitboard done` exit 0 (not 1) when the item is already
  completed and the call would be a no-op — stays here for triage:
  same reason, a CLI UX call in `_work/gitverdict.tl` or similar that
  needs its own spec.
- Fold the friction-collection paragraph into every `gitboard brief`
  emission automatically, so an orchestrator gets it for free instead
  of having to remember to append it by hand — stays here for triage:
  plausibly ready-bar material but not drafted as a spec this pass.
