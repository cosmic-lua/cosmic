## Evidence

PR #1657 opened 18:34:44Z; the orchestrator claimed its review and
spawned a reviewer at ~18:36. The emitted review brief's first rule
("CI ... still running ends the review immediately — record nothing")
ended that agent after 6 tool calls (~66k tokens): `smoke`×2 and
`repro` were in_progress until 18:37:19Z. The claim stayed held, the
orchestrator had to notice, wait for the check-suite notice, and
respawn under the same session. Nothing in the chain refuses early:
`take ID` on an item awaiting a verdict grants the review without
reading CI (`_work/gitverbs.tl`, the review claim path), `next` offers
"review «X»" the moment `pr` is recorded, and `brief review` fills
`<HEAD_SHA>` from a placeholder rather than from a CI read. The
verdict verb already reads the PR (`_work/gitverdict.tl`) through
`_work/gh.tl`, so the check-runs read exists.

## Change

`_work/gh.tl`: one function `head_checks(repo, pr): "green" | "red" |
"running" | "none", string` over the PR head's check runs (the same
read `verdict` uses; `none` when a repo runs no checks).
`_work/gitverbs.tl`, the review claim in `take`: refuse with
`gitboard-take: REFUSED: <id>'s head <sha7> has CI running (<n> of <m>
checks done) — review when it settles` unless `--force`. `next`
(`_work/action.tl`): a reviewable item whose head is `running` is
rendered `ci running` under doing and not offered as head; `red`
renders as `ci red — builder's` and is also not offered. `brief
review`: fill `<HEAD_SHA>` from the same read when the state is
`green`, and refuse to emit for `running`/`red` with the same verdict
line. Off-line (no GitHub reach) every path behaves as today.

`_work/gitverbs_test.tl`, `action_test.tl`, `brief_test.tl`: a fixture
PR in each of the four states.

## Non-goals

No polling, no waiting inside a verb; the state is read once per
verb, as `verdict` already does.
