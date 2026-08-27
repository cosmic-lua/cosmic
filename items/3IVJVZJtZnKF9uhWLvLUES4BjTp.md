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
