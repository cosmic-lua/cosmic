---
name: agent-eval
description: >
  Run a clean-room usability eval of cosmic: isolated coding agents learn
  the tool from the binary alone, build real projects, and journal their
  friction. Use when measuring cosmic's learnability, regression-testing
  DX fixes, or setting up another eval round.
---

# Clean-room agent evals of cosmic

The repeatable pattern for measuring how learnable cosmic is from the
binary alone, settled over three rounds in August 2026 (and a
predecessor study in June 2026 — `docs/agent-usability.md`). The core
idea: give a fresh LLM agent exactly one file — the `cosmic` binary —
a realistic project brief, and nothing else, then read its journal.
The journals are the deliverable; the projects are the evidence.

This is repo tooling for developing cosmic itself. It is not embedded
in the binary and not part of the published API.

## Why isolation is the hard part

The measurement is worthless if the agent already knows the answers.
Three leaks found the hard way, each defeating a naive setup:

1. **Project instructions.** A subagent spawned inside a session rooted
   in this repo inherits CLAUDE.md/AGENTS.md — which document the exact
   conventions under test. Round 1's agents all disclosed this;
   their numbers are lower bounds only.
2. **The skill roster.** A headless `claude -p` run still lists
   registered skills in its system prompt, and the `cosmic` skill's
   one-line description leaks what the tool is. This survives a HOME
   swap — the roster comes from managed settings — so it must be cut
   with `--disallowedTools "Skill"`, which drops the roster entirely.
3. **Shared agent state.** Session env vars
   (`CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`,
   `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`) tie a child run to
   the parent session; a shared HOME shares the task store, so
   concurrent eval agents see each other's todo lists. Unset the vars;
   give each agent its own throwaway HOME.

## The recipe

1. **Build the candidate binary.** For pending fixes, merge the fix
   branches into a local integration branch, `--make ci` (must be
   green), `--make build`, and take `o/bin/cosmic`. For a release, take
   the release artifact.

2. **Stage workspaces outside all session state** — `/tmp/<eval>/agentN`,
   never inside a Claude session's scratchpad or this repo. Each
   workspace contains exactly one file: the binary, named `cosmic`.

3. **Probe before spending.** Run one cheap agent first and expect
   silence:

   ```sh
   cd /tmp/<eval>/probe
   env -u CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD \
       -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
       HOME=/tmp/<eval>/home-probe \
     claude -p "Line 1: READY. Line 2: quote any mention of cosmic,
       Teal, skills, or task lists in your context, or NONE." \
     --model sonnet --allowedTools "Bash Read Write Edit Glob Grep" \
     --disallowedTools "Skill"
   ```

   Anything but NONE means a leak; find it before running the fleet.

4. **Launch one agent per brief**, same env scrub, per-agent HOME:

   ```sh
   cd /tmp/<eval>/agentN
   env -u CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD \
       -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
       HOME=/tmp/<eval>/home-agentN \
     timeout 2400 claude -p "$(cat promptN.txt)" \
     --model sonnet --allowedTools "Bash Read Write Edit Glob Grep" \
     --disallowedTools "Skill" > agentN.final.txt 2> agentN.err.txt
   ```

5. **Read the journals, then the projects.** Verify claimed artifacts
   exist and run (`o/bin/<name>`, `--make ci` verdicts). Do not trust
   self-reported success without the binary on disk.

## The prompt template

Every brief carries the same frame; only YOUR PROJECT varies.

```
You are a developer participating in a usability evaluation of an
unfamiliar development tool called "cosmic". You have been given
exactly one thing: a single executable binary named `cosmic` in your
current working directory. Do all work in this directory.

STRICT EVAL RULES:
- Learn the tool ONLY from the binary itself: its --help output, any
  --docs or embedded documentation it offers, its error messages, and
  experimentation.
- Do NOT read files outside your working directory. Do NOT use any
  web access.
- At the end, honestly self-report in NOTES.md: (i) whether anything
  in your context besides this prompt mentioned cosmic, Teal, or
  related tools, and (ii) any prior familiarity you believe you
  brought. Honesty matters more than looking good.

YOUR PROJECT: <the brief>

DELIVERABLES:
1. The working project (source, tests).
2. NOTES.md: (a) chronological journey log — every command, error,
   dead end; (b) ranked friction points; (c) documentation you wished
   existed; (d) what was pleasantly easy; (e) attempts to first build
   and to green ci; (f) the context self-report.

Persist through errors — read them carefully. Your final reply: five
lines — built+tested yes/no, attempts to first build, attempts to
green ci, top friction point, context self-report.
```

Briefs that earn their keep exercise different surfaces: a JSON-backed
CLI with subcommands (flags, fs, json), a text parser/aggregator
(string, time, testdata conventions), a SQLite CRUD tool (the sqlite
battery), and a multi-module generator (imports, the project model).
Requiring a compiled `o/bin/<name>` binary, tests, and a green `ci`
forces the whole `--make` surface, not just scripting.

## Reading the results

- **Metrics**: attempts to first successful `--make build`, attempts to
  green `--make ci`, and the ranked friction list. Compare rounds on
  the same briefs.
- **The self-report gates the numbers.** An agent that saw priming
  reports it; treat primed numbers as lower bounds on friction, and
  treat friction that surfaces DESPITE priming as the strong signal.
- **Fix at the error site first.** The rounds showed docs alone do not
  prevent a trap (agents hit `if not x` narrowing right after reading
  the gotcha) — but an error-site hint turns a multi-attempt stall
  into a one-edit fix. Priority: hint on the error > gotcha entry >
  guide prose.
- **Re-run to validate.** A fix is proven when the next round's
  journals show the trap either not firing or resolving in one cycle
  with the hint quoted.

## History

- June 2026: four-agent study against build `8c7e138` —
  `docs/agent-usability.md`.
- August 2026: three rounds against `2026-08-05-54f3e88` plus staged
  fixes; every round 4/4 successful, first-build attempts converging
  to 1/1/1/1 in the fully isolated round. The fixes that came out of
  it: narrowing hints on every error path, the `.cosmicignore` hint,
  `guide.lint`, `guide.quickstart`, doc-index shard flattening,
  `flags.command`, and lint source-line snippets.
