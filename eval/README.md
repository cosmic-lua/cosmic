# evaluating cosmic with a fresh agent

doc/design.md's second promise names the measure: a builder given only the
binary completes real work with less friction than elsewhere, and the
measure is a fresh agent given the binary and nothing else, journaling
what slowed it down. This directory is that measure, runnable: a task,
an arena to run it in, and a grader that checks the result without
trusting the agent's word.

Nothing here is part of the build, and CI never runs it: an eval spends
money and minutes on a model, and reaches the network to do so.

## what an eval is

One agent, one task, one binary. The agent starts with no memory of
cosmic and no way to learn about it except from the binary itself. It
builds what the task asks, and keeps a journal of every attempt as it
goes. Afterward the grader runs the agent's project through cosmic and
the built executable through its paces, and the journal's ranked
summary says what to fix next. The fix goes in, the binary is rebuilt,
and the same task runs again: the numbers say whether it helped.

## preparing a run

Build once at the commit under test (`bin/zig build boot`). Claude and
Codex use the same task, journal, binary and grader, but each gets a new
arena and a fresh agent. Do not show either agent another run's output.

```sh
eval/arena notes o/bin/cosmic /tmp/cosmic-evals/notes/claude/run-001
eval/arena notes o/bin/cosmic /tmp/cosmic-evals/notes/codex/run-001
```

Choose new absolute paths outside the checkout; an existing destination
is an error, never deleted. The arena contains `bin/cosmic`,
`project/TASK.md` (task plus journal contract), `tmp/` (the solver's
`TMPDIR`, its one sanctioned place outside `project/`), `PROMPT.md` (the
entire launch prompt), and `inputs.sha256`. Give the solver only PROMPT.md's
contents. The parent keeps metadata, grading output and other runs out
of the solver's project. The prompt varies only in arena paths.

## conditions shared by both runners

- **No cosmic context.** A fresh agent, no inherited conversation,
  repository instructions, prior journals or coaching about cosmic.
  Generic platform instructions and ordinary tools are fine. The
  binary is the only source of cosmic information: no repository,
  skills, plugins, web searches or other outside sources may supply it.
  Tool availability alone is not contamination; using an outside source
  about cosmic is. Record any known contamination and invalidate that run.
  A host can carry cosmic knowledge the solver never asks for: a synced
  cosmic skill under `~/.claude/skills`, or repository instructions pulled
  in through environment variables. Isolate the runner's configuration
  (below) and confirm afterward that no tool call named this checkout or
  a skills directory.
- **Work in the arena.** Explicitly set `project/` as the working directory,
  prepend the arena's `bin/` to PATH and set TMPDIR to the arena's `tmp/`
  for every shell call. A Work
  subagent's default directory is still the parent's workspace. Reading
  the binary itself, including `strings`, is fair. No delegation.
- **Bounded.** Use a 600-second solver deadline. Claude's timeout enforces
  it; the Work parent monitors elapsed time and interrupts at the deadline.
  Record actual elapsed time and enforcement method. A turn cap is an
  additional runner-specific limit, not a claim of equal model budgets.
- **Independent grading.** After the solver stops, run
  `timeout 30 eval/check/notes <absolute-arena>` and save stdout/stderr as
  `grade.log` outside `project/`. A timeout is distinct from an assertion
  failure. The notes grader requires recorded tests and examples (including
  guide doctests), checks formatting, builds exactly `o/bin/notes`, then
  exercises it without supporting files or environment. The grader runs
  on the pinned bootstrap cosmic, which is no solver dependency either;
  run `bin/cosmic-bootstrap` once beforehand, so its first download is
  not counted against the grader's 30 seconds.
- **Evidence.** Preserve the project and journal. Any path a tool call
  named outside the arena is a boundary breach to record. Preserve a full transcript
  where the runner supplies one; a journal is not a replacement transcript.
  Validate claims against available outputs and reproduce uncertain ones.
- **Named.** Record runner, exact model/settings, commit, input hashes,
  start/end times, completion or timeout, grading exit code and verdict.
  Keep usage metrics if supplied; unavailable metrics are `null`, not zero.
  Compare commits within a fixed runner/model/settings first. A paired
  Claude/Codex result compares the whole agent setup, not just the model.

## Claude Code

Use a fresh noninteractive session, without resume or inherited project
instructions. Set `dir` to the absolute arena path and `model` explicitly.
The existing tool allowlist makes local tools usable without prompts.
An empty `CLAUDE_CONFIG_DIR` leaves out user skills, plugins, hooks and
instructions (credentials still come from the environment); a cloud
session also sets `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`,
`CLAUDE_ADDITIONAL_DIRECTORIES` and `CLAUDE_CODE_SYNC_SKILLS`, which can
bring the checkout's instructions or a synced cosmic skill back in, so
unset them. Probe once with `claude -p "list your skills"` under the same
settings before trusting the setup.

```sh
config=$(mktemp -d)
cd "$dir/project" && env -u CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD \
  -u CLAUDE_ADDITIONAL_DIRECTORIES -u CLAUDE_CODE_SYNC_SKILLS \
  CLAUDE_CONFIG_DIR="$config" TMPDIR="$dir/tmp" PATH="$dir/bin:$PATH" timeout 600 \
  claude -p "$(cat "$dir/PROMPT.md")" \
  --model "$model" --disable-slash-commands \
  --tools "Bash,Read,Write,Edit,Glob,Grep" \
  --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
  --disallowedTools "Skill,WebSearch,WebFetch,Agent,Task,ToolSearch,SearchSkills,ListSkills,SearchPlugins,ListPlugins,SearchMcpRegistry,Workflow,SendMessage,Artifact,NotebookEdit,SendUserFile" \
  --max-turns 60 --output-format stream-json --verbose \
  < /dev/null > "$dir/transcript.jsonl" 2> "$dir/stderr"
```

`eval/summarize <transcript.jsonl>` is specifically a Claude stream-json
reader. Beyond turns, tool calls, minutes and cost it counts failed tool
calls, `cosmic docs` lookups with no exact match, the call at which
`cosmic test` first passed and the journal's writes, then lists every
path a tool call named outside the arena and flags any that named this
checkout or a skills directory. Keep it for Claude; do not feed Work results into it. `--bare`
previously dropped the credential helper, and bypassing permissions was
refused; neither is required for this eval.

## Codex in ChatGPT Work

The parent reads PROMPT.md and uses its exact contents as `message` in
`collaboration.spawn_agent`, with these settings:

```json
{
  "task_name": "notes_eval",
  "fork_turns": "none",
  "model": "gpt-5.6-sol",
  "reasoning_effort": "medium"
}
```

Supply no repo context or launch explanation to the child. Let it use
normal tools; do not mediate individual commands or help when it gets
stuck. Monitor from the parent without sending hints. On completion,
retain the final response and independently run the same grader. At the
deadline interrupt the agent and record a timeout before grading partial
work; do not resume it to repair the result.

The current collaboration interface does not export the full transcript,
turn count or cost. Mark those unavailable. Record the journal, final
response, elapsed time and grader log rather than claiming a full trace.
Fresh-context and repo-access probes found no accidental cosmic leakage
with this setup; it is not a filesystem security boundary.

## reporting a run

Keep a small `result.json` next to PROMPT.md, written by the evaluator:
`runner`, `model`, `reasoning_effort`, `commit`, `started_at`, `finished_at`,
`elapsed_seconds`, `status`, `deadline_method`, `grade_exit_code`,
`grade_verdict`, `contamination`, `transcript`, `turns`, `tool_calls`, and
`cost_usd`. Use `null` for unavailable fields. `inputs.sha256` identifies
all solver inputs; record the harness commit separately when it differs
from the binary commit. A run commits nothing. If it reveals a real fix,
that fix is the PR; cite the run's evidence and limitations.

## writing a task

A task file is Markdown under `eval/task/`, and `eval/arena` appends
`eval/journal.md` to it. Whatever the task itself asks the agent to
build, hold it to the same bar, and grade every part of it for real:

1. **Tests.** The project must ship tests `cosmic test` discovers and
   passes. Non-negotiable, whatever else the task asks for.
2. **Examples, or another form of code docs, where the task's own
   code has a public shape worth demonstrating.** Worked examples
   `cosmic test` also runs and `cosmic docs` shows under the symbols
   they demonstrate; name this requirement explicitly rather than
   leaving it implied, the same as any other.
3. **A green build, fast.** `cosmic test` and `cosmic fix --check`
   both pass, and pass in seconds -- the grader runs them for real,
   the way a project's own CI would, not just checks that the files
   exist. A task too big to build and test quickly is too big for
   this harness.
4. **A binary that stands on its own and says what it does, when the
   task asks for one.** Built by `cosmic build`, runs with nothing
   beside it -- and answers `--help` (or whatever the task names) with
   real usage text; a binary that only works when its author already
   knows the commands is not yet a finished tool.

Each requirement the task names is one the grader runs; a task must
say what it asks for in its own words, so the grader is never checking
something the agent was never told. Beyond that bar, what has worked:

- **Say what is fair game and what is not**, in the task's own words:
  the binary is the only source, no skills, no web, no prior knowledge
  of anything called cosmic, work only in this directory.
- **Ask for something a grader can check**: named commands with exact
  output, a file the tests must live in, an executable that must run
  with nothing beside it.
- **Use the standard library that exists.** A task that needs a module
  cosmic does not have yet measures the gap, not the tool.
- **Pair it with a grader** at `eval/check/<task>`, taking the arena
  directory and ending in a verdict line.
- **Say what, never how.** Name the outcome -- tests that pass, examples
  cosmic checks, code formatted the way cosmic formats it, a binary that
  runs alone -- and never the cosmic command that gets it. Finding the
  command is the thing being measured; a task that names `cosmic test`
  has already answered it. The grader, not the task, runs the commands.
- **Say what the binary's environment will be.** The grader runs it with
  an empty environment; the task says so in the same words.
- **Keep the journal contract out of the task.** It is the same for
  every task and lives in `eval/journal.md`.

## reading a journal

The summary at the end ranks what slowed the agent, with the log
entries it refers to; read those entries, not the ranking alone. A
journal written once at the end (`journal_writes` of one or two) is a
retelling: weigh the transcript and `eval/summarize`'s counts over its
ranking. Then:

- **Check every claim about the tool against the transcript and the
  grader.** An agent that misread its own probe will rank the misreading
  first.
- **A guess that held up is still a gap**: the agent learned it from
  trying, not from the tool. The "guessed rather than learned" list is
  where the next help line or error message comes from.
- **"The one change that would have helped most"** has been right every
  time so far, and cheap. Start there.
