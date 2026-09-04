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
  then fan out up to that many disjoint items; with `--routine` after
  the number, run unattended: terse output, no questions, and the
  friction log friction.md describes recorded on the board.
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
status. `gitboard help` lists the verbs and the doctrine topics;
`gitboard help <verb>` and `gitboard help <topic>` serve everything
else. the decompose procedure — verification items, held roots — is
`skills/work/decompose.md`. this file deliberately restates none of it — the doctrine
ships with the tool, so a change to how the board is operated never
needs an edit here.

## /work N — the standing loop

invoked with a number (typically under `/loop`): bootstrap if
needed, run ONE bounded orchestrator pass exactly as `gitboard help
orchestrate` describes, and end the pass. under `/loop` in dynamic
mode a pass that moved nothing is a no-op tick; agents in flight
notify on completion, so the wakeup is a long fallback, never a
poll.

## /work N --routine — the same pass, unattended

with `--routine` the pass runs with nobody reading and nobody to
ask, and it observes itself while it runs:

- **terse.** no human is reading the chat. there are no progress
  updates between actions, no narration, no summary of the doctrine,
  no restating what the verdict lines already said; the only prose
  the pass writes is one terse summary at its end: what moved, one
  line per board action, and the friction log's handle. everything
  else a reader might want is already on the board.
- **no questions.** never ask; the tool that asks the user is not
  used at all. a decision that belongs to the goal owner — a
  comparison that would put new work above existing work, a wall a
  spec cannot answer, a reject that reopens a decision — is not a
  question here: file it as an item with the evidence, block what
  waits on it, take the next thing, and let the ledger name it. the
  bar and the doctrine already say what to do at every other fork;
  `next` names the head, and `none` ends the pass.
- **the friction log.** for the orchestrator and for every agent it
  runs, each place where the goal and what actually happened
  differed in a way that cost time, tokens, or quality, with the
  numbers that size the cost, what made the difference, and the
  countermeasure. the procedure, the shape of an entry, the note that
  asks each agent to report its own, and the transcript reader are
  `skills/work/friction.md`. the log ends the pass as an unparented
  board item to triage, and every countermeasure that already passes
  the bar is filed as its own item before the pass ends.
