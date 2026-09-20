# evaluating cosmic with a fresh agent

design.md's second promise names the measure: a builder given only the
binary completes real work with less friction than elsewhere, and the
measure is a fresh agent given the binary and nothing else, journaling
what slowed it down. This directory is that measure, runnable: a task,
an arena to run it in, a grader that checks the result without trusting
the agent's word, and a table of what each run cost.

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

## running one

1. **Build the binary** at the commit under test: `bin/zig build boot`
   in a clean worktree gives `o/bin/cosmic`. Note the commit.
2. **Make the arena**: `eval/arena <task> <binary> <dir>` lays out `dir/`
   with the binary at `bin/cosmic` and the task at `project/TASK.md`
   (the task file joined to `eval/journal.md`, the journal contract
   every task shares). Put the arena outside this repository, so the
   agent cannot reach the tree by accident. `o/eval/<task>/<commit>/`
   is the conventional place; nothing under `o/` is committed.
3. **Run the agent** in `dir/project`, with `dir/bin` first on its PATH,
   under the conditions below, with this as its whole prompt:

   ```text
   Your working directory is <dir>/project. Read TASK.md there and do
   exactly what it says. The 'cosmic' binary is on your PATH.
   ```

4. **Grade**: `eval/check/<task> <dir>` runs the project's tests and
   format check, builds it, and runs the executable with nothing beside
   it. It ends in a verdict line. The grader is the record of what
   works; the journal can be wrong about the tool and about itself, and
   has been (one run reported an argv bug that its own transcript
   disproved).
5. **Record** a row in `eval/baseline.md`: task, commit, agent and model,
   verdict, minutes, tool calls, cost. The transcript, the journal, and
   the project stay under `o/eval/`.
6. **Read the journal's summary**, act on its ranked list, and go again.

## the conditions the agent runs under

The point is a fresh builder with only the binary. Every condition
below protects that, and the run is invalid without it:

- **No prior context.** A fresh session: no memory, no project or user
  instruction files, no skills or plugins, no system prompt beyond the
  agent's own default. Anything that describes cosmic, including this
  repository, must be out of reach.
- **No network.** No web search or fetch tools; the task text says the
  binary is the only source of information, and the tools must make
  that true.
- **Only local tools.** A shell, and reading, writing, editing and
  searching files. No sub-agents, no delegation.
- **The arena is the world.** Working directory `dir/project`; the
  binary reached by name through `dir/bin` on PATH. The agent may read
  the binary itself: `strings` over it is fair, and one run found the
  standard library that way.
- **Bounded.** A turn cap on the order of 60 and a wall clock under 10
  minutes, so a stuck run ends and its journal says so, and a passing
  run stays quick and cheap to run.
- **Kept.** The full transcript, so a journal claim can be checked
  against what the agent actually saw.
- **Named.** The agent and model, in the baseline row: numbers across
  models do not compare, numbers across commits of one model do.

Runs so far used Claude Code with Sonnet, invoked non-interactively;
this satisfies every condition above:

```sh
cd "$dir/project" && PATH="$dir/bin:$PATH" timeout 600 \
  claude -p "Your working directory is $dir/project. Read TASK.md there and do exactly what it says. The 'cosmic' binary is on your PATH." \
  --model sonnet --disable-slash-commands \
  --tools "Bash,Read,Write,Edit,Glob,Grep" \
  --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
  --disallowedTools "Skill,WebSearch,WebFetch,Agent,Task,ToolSearch,SearchSkills,ListSkills,SearchPlugins,ListPlugins,SearchMcpRegistry,Workflow,SendMessage,Artifact,NotebookEdit,SendUserFile" \
  --max-turns 60 --output-format stream-json --verbose \
  < /dev/null > "$out/transcript.jsonl" 2> "$out/stderr"
```

Two flags that look right and are not: `--bare` drops the credential
helper and the run fails to authenticate, and the permission-bypass
flag is refused by policy; the explicit allowlist is what makes the
tools usable without prompts. `eval/summarize` reads that transcript
for the turn count, tool calls, duration and cost. Another agent needs
its own invocation and its own reading of its own transcript; the
conditions and the prompt stay the same.

## writing a task

A task file is Markdown under `eval/task/`, and `eval/arena` appends
`eval/journal.md` to it. What has worked:

- **Say what is fair game and what is not**, in the task's own words:
  the binary is the only source, no skills, no web, no prior knowledge
  of anything called cosmic, work only in this directory.
- **Ask for something a grader can check**: named commands with exact
  output, a file the tests must live in, an executable that must run
  with nothing beside it. Each requirement the task names is one the
  grader runs.
- **Use the standard library that exists.** A task that needs a module
  cosmic does not have yet measures the gap, not the tool.
- **Pair it with a grader** at `eval/check/<task>`, taking the arena
  directory and ending in a verdict line.
- **Keep the journal contract out of the task.** It is the same for
  every task and lives in `eval/journal.md`.

## reading a journal

The summary at the end ranks what slowed the agent, with the log
entries it refers to; read those entries, not the ranking alone. Then:

- **Check every claim about the tool against the transcript and the
  grader.** An agent that misread its own probe will rank the misreading
  first.
- **A guess that held up is still a gap**: the agent learned it from
  trying, not from the tool. The "guessed rather than learned" list is
  where the next help line or error message comes from.
- **"The one change that would have helped most"** has been right every
  time so far, and cheap. Start there.
