# friction: 2026-09-04 work9 reconciliation tail (/work 9 --routine)

Continuation of `friction-2026-09-04-work9.md` (filed as «FcWz_FClp»):
this covers everything from the wave's builds landing PRs through all
six items reaching `done`/merged, since most of the pass's real work —
and nearly all its friction — happened during reconciliation, not
during the initial wave-fill.

## orchestrator
- goal: hand a rejected item back for rework without a `brief` verb
  that generates the rework brief.
  actually happened: six rework rounds this pass (2 on «fuXz_MkSX», 4
  on «FacE_b8sh»), each requiring the orchestrator to hand-assemble a
  "Why this is a rework" section (quoting the reviewer's PR comment
  verbatim via a GitHub API fetch), hand-write worktree-reuse
  instructions (find the existing worktree, confirm it's clean and at
  the pushed head, tell the agent NOT to branch fresh or discard the
  diff), and hand-write push/no-new-PR instructions — none of which
  `gitboard brief builder <id>` emits for a `state: rework` item (it
  emits the same fresh-pull brief, `<BOUNCE_CONTEXT>` placeholder and
  all, unfilled). Cost: roughly 15-20 minutes and 8-10 tool calls of
  hand-assembly PER rework round (fetch comment, check worktree state,
  write brief, spawn) — six times, so on the order of 90-120 minutes
  and 50-60 tool calls of pure orchestrator overhead this pass that a
  `brief builder` aware of `state: rework` would have collapsed to one
  command each time.
  contributed: `_work/brieftext.tl`/`_work/brief.tl` has no rework-
  specific template; the `<BOUNCE_CONTEXT>` placeholder exists (named
  in every builder brief's verdict line) but nothing fills it
  automatically from the item's own `verdict`/`pr` fields, which
  `gitboard show` already prints. This is exactly what «rNh1_b1Se»
  (still open, band 1, itself part of the `_work/brief.tl` collision
  cluster this pass explicitly avoided pulling) proposes fixing in
  part, but it doesn't cover auto-generating the rework brief body —
  only headroom/per-file-check/bounce-diff/base-conflict sentences.
  improvement: a gate in the tool — `gitboard brief builder <id>` on
  a `state: rework` item should detect the existing `verdict`/`pr`
  fields, fetch the PR's latest review comment via `gh.tl` (the read
  already exists — `verdict`/review flows use it), and fill
  `<BOUNCE_CONTEXT>` with a templated "this is a rework" section
  quoting it, plus fill the worktree section with reuse instructions
  keyed off the item's recorded branch. This is squarely a `brief.tl`
  change, same family as «rNh1_b1Se» and «Elus_cLzz» — candidate filed
  below.

- goal: give each review round a session label distinct from every
  prior round on the same item, so `take`'s exact-string reclaim never
  collides with a stale prior lease.
  actually happened: `gitboard brief review <id>` always mints the
  same base label (`review-<handle>-<orch8>`) regardless of how many
  times the item has already been reviewed — this pass hand-suffixed
  `-2`, `-3`, `-4` via `take --session` and then `sed -i` across the
  emitted brief to keep the verdict command's embedded session string
  consistent with the actual claim. Six times this pass (once per
  re-review after every rework/description-fix). Not a lot of overhead
  per round (~1 tool call), but the tool print a label at the bottom
  that this orchestrator then had to override with a search-replace
  across the whole file rather than a single field — copy-paste risk
  if the orchestrator forgets one of the (up to 3) occurrences.
  contributed: `brief review`'s mint logic derives the label purely
  from `<handle>-<orch8>`, with no round counter even though the item
  itself already carries enough state (`verdict` recorded, `pr`
  unchanged since) to know this is round N.
  improvement: `gitboard brief review <id>` could mint
  `review-<handle>-<orch8>-<n>` where `n` is one more than the number
  of prior verdicts already recorded against this item's current `pr`
  — a small, mechanical addition to the same minting code path that
  the `orchestrate` doctrine already asks callers to read off the
  verdict line, so the orchestrator never hand-edits a label again.

- goal: land a request-changes finding that was pure PR-description
  prose (no code change) without spinning up a full builder agent.
  actually happened: for «fuXz_MkSX»'s third round, the only gap was a
  stale PR title/body (miscounted casts, stale arithmetic). Rather
  than spawn a ~$1-2, 5-10-minute builder agent for a text-only fix,
  the orchestrator edited the PR body directly via
  `mcp__github__update_pull_request`, then had to work around two
  consecutive `gitboard` guard refusals to record the verdict on an
  unchanged head (a same-spec-already-judged refusal, then a same-
  session distance-guard refusal) — both resolved via `gitboard spec
  --force --why` and `gitboard verdict --force --why`, per the review
  agent's own report.
  contributed: no doctrine gap here — this was the orchestrator (not
  an agent) doing the edit, and the two-refusal dance is the guard
  working as intended (a same-session verdict on a spec the same
  session just touched IS suspicious by default). Filed as a positive
  observation: the guard did its job and the escape hatch worked, at
  the cost of two extra commands the item's OWN reviewer (not the
  orchestrator) ended up eating, since the orchestrator handed the
  item back via a plain `take --pr` re-record rather than anticipating
  the guard interaction itself.
  improvement: none needed — noting for future orchestrator sessions
  that fixing a PR body directly (no new commit) and handing back for
  re-review is a valid, faster path for text-only findings, but the
  re-reviewer should expect to `--force` past the same-session/same-
  spec guards once, with `--why` explaining the direct-fix history.

## review round 3, «FacE_b8sh» (claude, orchestrator subagent) — request-changes, ~470s
- goal: catch a real bug via mutation testing in code the item itself
  had not yet wired into any live command.
  actually happened: the reviewer found and demonstrated (via a
  reproducible mutation) a genuine count/names mismatch in dead code
  (`_work/action.tl`'s CI-blocked reason string), then required a fix
  despite the follow-up item's own Non-goals asserting this exact code
  was "correct as shipped here." Reproducing it cost ~5 tool calls
  (three failed scratch-test attempts before landing on the right
  unplaced-root shape `action_ci_test.tl` already used).
  contributed: `item.tl`'s `builders: {string}` field is typed as a
  Lua array in the in-memory `Item` record but `decode` expects a
  space-joined string on the wire — nothing next to the field
  declaration says so, so a reviewer writing a fixture from scratch
  hits a shape error before finding this out. Reported as the
  reviewer's own friction, quoted verbatim above; the same class of
  gap (in-memory type vs. wire shape undocumented at the declaration
  site) could recur for other `Item` fields.
  improvement: a one-line comment on `item.tl`'s `builders` field
  cross-referencing `decode`'s space-joined-string expectation — cheap,
  and the exact shape of doc-comment fix this repo's own conventions
  already ask for.

## candidates
- `gitboard brief builder <id>` auto-fills `<BOUNCE_CONTEXT>` and
  worktree-reuse instructions for a `state: rework` item, from the
  item's own `verdict`/`pr` fields and a `gh.tl` PR-comment read — not
  filed: needs a full spec (which file, which function, the comment-
  selection rule when a PR has multiple review comments) that this
  pass didn't have time to write; stays here for triage. Highest-
  leverage candidate from this pass — six hand-assembled briefs this
  session, all following the identical assembly pattern.
- `gitboard brief review <id>` mints a round-numbered session label
  (`review-<handle>-<orch8>-<n>`) instead of always minting round 1's
  label — not filed: small enough to spec directly from this entry;
  stays here for triage.
- `item.tl`'s `builders` field gets a one-line doc comment naming the
  wire-shape mismatch with `decode` — not filed: small enough to spec
  directly from this entry; stays here for triage.
