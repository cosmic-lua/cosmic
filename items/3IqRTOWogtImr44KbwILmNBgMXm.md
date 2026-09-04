## Evidence

Measured across the `/work 9` orchestrator pass on 2026-09-04 (friction log
`friction-2026-09-04-work9.md`, filed alongside this item): of 18 dispatched
subagents (8 builders, 9 reviewers, 1 researcher), **8 (44%) independently
hit the harness's `sleep N; <command>` block** on their first attempt to
wait on a background process they'd started (a build, a gate run, `--make
ci`):

```
<tool_use_error>Blocked: sleep 60 followed by: echo waited. To wait for a
condition, use Monitor with an until-loop (e.g. `until <check>; do sleep 2;
done`). To wait for a command you started, use run_in_background...
```

Transcripts and call indices (`cosmic _tool/friction.tl <transcript>`):
- build FeC7_Ri35 (`a17393e6089b1012c`, call 28)
- build eDVe_UY1D (`a0e8b02a81321639b`, call 55)
- build wkmX_zNkM (`aca08d21266b6bf60`, call 90)
- build mZos_IITG (`a2e154d44fbc5501f`, call 12)
- build qqTp_aJfw (`ad46335d22c9e3403`, call 101)
- build 24pv_Z1Dj (`acf7e5c933c667bd7`, call 28)
- review fU6l_yGKY (`a643718cee3aad83a`, call 20)
- review qqTp_aJfw (`a8a9ab1897a5e6d03`, call 24)

Every one of these agents then ended its turn without an answer,
believing (per its own stated reasoning) that a "monitor" or the
orchestrator would notify it when the background command finished — it
would not have; each was a plain subagent with no persistent
notification channel of its own. In every case the orchestrator had to
read a task-notification reporting no progress, diagnose the same
generic problem, and send a `SendMessage` explicitly instructing the
agent to block synchronously in the foreground instead — costing one
full extra orchestrator-to-agent round trip (a resumed turn, its own
tool calls, and the wall-clock of whatever it was waiting on) per
affected agent, for 8 of 18 agents in this one pass.

The builder and review briefs `gitboard brief builder`/`gitboard brief
review`/`gitboard brief research` emit today (`_work/brief.tl` or
equivalent) say nothing about how to wait on a command the agent itself
starts in the background — the gate-running step ("Run the repo's gate
locally...") gives no guidance on `run_in_background`/blocking-loop
conventions, so agents default to the most natural-looking pattern
(`sleep N; <check>`), which happens to be exactly the one the harness
blocks.

## Change

Add one short paragraph to the emitted brief template(s) — `gitboard
brief builder`, `gitboard brief review`, and `gitboard brief research`
share the "run the gate" and "wait for a background result" instruction
— stating explicitly: when starting a long-running command (a build, a
full gate run) in the background, block on it SYNCHRONOUSLY in the same
turn (e.g. `while kill -0 <PID> 2>/dev/null; do sleep 5; done`, or just
run the command in the foreground without backgrounding it at all) —
never end the turn assuming something will notify you; a subagent has
no persistent monitoring between turns. This is a text change to
whatever module renders `gitboard brief`'s output (find it via `git grep
-rn "run the repo's gate locally" _work/` or equivalent in the board
tooling), verified by re-running `gitboard brief builder <id>` on any
item and confirming the new paragraph appears.

## Non-goals

Not changing the harness's own `sleep`-blocking behavior (out of this
repo's control and reasonable as a guardrail) — only ensuring the brief
tells agents the correct alternative up front instead of them
discovering the block by trial and error, one resumed turn at a time.
