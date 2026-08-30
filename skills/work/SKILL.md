---
name: work
description: >
  The system of work for cosmic: one prioritized board of items on the
  orphan `board` branch, operated by gitboard. Two states — todo and
  doing — with quality held at two gates: a spec good enough to build
  from alone before work is pulled, and a fresh-context review before
  anything merges. Use when planning what to build next, refining an
  item, pulling one to implement, reviewing a PR against its spec, or
  landing an accepted one. Invoked with a number (`/work 5`, typically
  under `/loop`), run one orchestrator pass: reconcile the last wave,
  then fan out up to that many disjoint items.
---

# The system of work for cosmic

the system lives in the tool, not here. this file is only the
bootstrap; everything else — the states and their exits, the spec
bar, building, review, orchestration, the hard rules — is served by
`gitboard` itself, so a doctrine change ships with the tool and
reaches every session on its next sync. do not act from memory of an
older version of this skill: read the tool's pages.

## bootstrap

ALL work state lives on the orphan `board` branch of
cosmic-lua/cosmic, reached as a worktree of the checkout you already
have; the branch carries its own machinery and builds its own tool:

```bash
git worktree add o/board board        # once per checkout
cd o/board && bin/cosmic --make build # once, on a cold worktree
```

that build produces `o/bin/gitboard`. where a proxy re-terminates
TLS, export `SSL_USE_SYSTEM_CERTS=1` in the session (never in a
committed file), or the verbs that reach GitHub fail every call with
`badcert_not_trusted`.

## then let the tool teach

start every session with `sync`. every verb ends with a
`gitboard-<verb>:` verdict line — read that, never a piped exit
status.

- `gitboard help` — the verbs, and the topic list.
- `gitboard help <verb>` — one verb's options and contract.
- `gitboard help <topic>` — the doctrine: `system` (states, order,
  exits, rules), `bar` (the spec bar), `build`, `review`,
  `orchestrate` (concurrent agents and the standing loop).
- `gitboard next` — the one next action, by the system's own
  ordering; do it and ask again. `none` is an answer.
- `gitboard brief <kind> ID` — the subagent prompt for a builder,
  review, refine, or decompose role, spec verbatim and board facts
  filled; fill what its verdict line names, then paste it verbatim.

## /work N — the standing loop

invoked with a number (typically under `/loop`): bootstrap if
needed, then run ONE bounded orchestrator pass exactly as
`gitboard help orchestrate` describes — reconcile, merge accepts,
drain the reviews (one fresh subagent at a time, while any diff
awaits a verdict — work nearly done beats work not started), then
fill the wave with disjoint claims, spare width to refine/triage,
report a terse ledger — and end the pass. under
`/loop` in dynamic mode a pass that moved nothing is a no-op tick;
agents in flight notify on completion, so the wakeup is a long
fallback, never a poll.
