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
tool=$(bin/cosmic-bootstrap --standalone build/paths.tl "$PWD")/bin/cosmic
eval/arena notes "$tool" /tmp/cosmic-evals/notes/claude/run-001
eval/arena notes "$tool" /tmp/cosmic-evals/notes/codex/run-001
```

The arena takes the tool itself, from the build directory build/paths.tl
names, not this checkout's [`bin/cosmic`], a script that runs it.

Choose new absolute paths outside the checkout; an existing destination
is an error, never deleted. The arena contains [`bin/cosmic`] (that tool),
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
  additional runner-specific limit, not a claim of equal model budgets;
  eval/solve sets it to 150 so that, at the several seconds a turn
  solvers have taken, the deadline usually binds first.
- **Independent grading.** After the solver stops, run
  `timeout 30 eval/check/<task> <absolute-arena>` (`timeout 60` for jobs,
  mirror and relay, whose checks wait out timeouts of their own) and save
  stdout/stderr as `grade.log` outside `project/`. A timeout is distinct
  from an assertion failure. The grader requires recorded tests and
  examples (including guide doctests), checks formatting, runs a hidden
  test of the library API the task names, builds exactly
  `o/bin/<task>`, then exercises it without supporting files or
  environment (see [grading](#grading)). It runs on the pinned bootstrap
  cosmic, which is no solver dependency either; run
  [`bin/cosmic-bootstrap`] once beforehand, so its first download is not
  counted against the grader's time.
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
instructions, and set the model explicitly. [`eval/solve`] launches it
for an arena in a sandbox, and writes `transcript.jsonl`, `stderr`,
`started_at`, `finished_at` and `exit_code` beside PROMPT.md:

```sh
eval/solve "$dir" --model "$model"    # --max-turns 150 --timeout 600 by default
```

The sandbox is cosmic.child's (`unveil`, as `cosmic test` holds its
workers): the solver, and every process it starts, has a root of its own
holding only

- the arena's `project/`, `tmp/` (its `TMPDIR`), and `config/` and
  `home/` (its `CLAUDE_CONFIG_DIR` and `HOME`, fresh each run, outside
  `project/`), to change; the arena's `bin/`, read-only;
- the `claude` found on PATH, links resolved: a native executable alone,
  or a script's directory and its interpreter;
- read-only, `/usr` (and the links `/bin`, `/lib`, `/lib64` into it) and
  `/etc`, for the shell, the tools its Bash calls start, the loader, and
  passwd, resolv.conf and the CA store (and so `/etc/claude-code`,
  Claude Code's managed settings, on a host that has them: check that
  it does not); `/dev/null`, `zero`, `full`,
  `random` and `urandom`; a `/proc` of its own pid namespace;
- the CA bundle `SSL_CERT_FILE` and `NODE_EXTRA_CA_CERTS` name, and, in a
  Claude Code cloud session, `/home/claude/.claude/remote/.oauth_token`
  alone, without which the CLI is not logged in;
- a `/tmp` of its own, gone with it: a stray `/tmp/x` write lands
  nowhere on the host.

No checkout of this repository, `~/.claude`, `~/.cache/cosmic`, skills
directory (`/mnt/skills`, `/home/claude/.claude/skills`), other arena or
user config is there to read. Its environment is the proxy variables,
the CA bundle variables, any Anthropic credential or endpoint variable
the host sets, and its own PATH (the arena's `bin/` first), `HOME`,
`CLAUDE_CONFIG_DIR`, `TMPDIR` and `COSMIC_TEST_SANDBOX=0`, and nothing
else: the variables a cloud session sets that bring the checkout's instructions or a synced
skill back in (`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`,
`CLAUDE_ADDITIONAL_DIRECTORIES`, `CLAUDE_CODE_SYNC_SKILLS`) are never
passed. It does not isolate the network: the solver reaches the API
through the host's network and proxy, and so could fetch anything the
proxy allows; the prompt's rule and the transcript still govern that.
The solver runs as the caller's user, in a user namespace of its own,
holding no capability, with every path but the arena's four mounted
read-only. With no capability, cosmic cannot sandbox a test worker
there (build/test_policy.tl's `unmet`), so the environment also carries
`COSMIC_TEST_SANDBOX=0`: the solver's `cosmic test` runs its workers
unsandboxed, which it would do anyway, and says so. The grader runs
under the same pin (below).

The sandbox needs Linux with user namespaces the caller may make: where
`cosmic test` sandboxes its workers, eval/solve sandboxes the solver. A
Claude Code cloud session (gVisor, running as root) has them, and the
solver there is uid 0 of its own namespace; a host whose policy refuses
them to an unprivileged user (Ubuntu's AppArmor restriction) does not.
Where the kernel refuses one, or gives the sandbox the host's `/proc`
in place of one of its own (a container that masks `/proc`), eval/solve
fails before the solver starts
rather than running it unconfined. There, and on macOS, launch by hand
as below, where the isolation is by convention only: an empty `CLAUDE_CONFIG_DIR` leaves out
user skills, plugins, hooks and instructions (credentials still come
from the environment), and the three variables above are unset. Probe
once with `claude -p "list your skills"` under the same settings before
trusting the setup.

```sh
config=$(mktemp -d)
cd "$dir/project" && env -u CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD \
  -u CLAUDE_ADDITIONAL_DIRECTORIES -u CLAUDE_CODE_SYNC_SKILLS \
  CLAUDE_CONFIG_DIR="$config" TMPDIR="$dir/tmp" PATH="$dir/bin:$PATH" \
  COSMIC_TEST_SANDBOX=0 timeout 600 \
  claude -p "$(cat "$dir/PROMPT.md")" \
  --model "$model" --disable-slash-commands \
  --tools "Bash,Read,Write,Edit,Glob,Grep" \
  --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
  --disallowedTools "Skill,WebSearch,WebFetch,Agent,Task,ToolSearch,SearchSkills,ListSkills,SearchPlugins,ListPlugins,SearchMcpRegistry,Workflow,SendMessage,Artifact,NotebookEdit,SendUserFile" \
  --max-turns 150 --output-format stream-json --verbose \
  < /dev/null > "$dir/transcript.jsonl" 2> "$dir/stderr"
```

Record `deadline_method` as [`eval/solve`] or `timeout 600`. Either way,
run [`eval/summarize`] over the transcript: its list of paths outside the
arena is the second line of evidence, naming what the sandbox refused
as well as what the manual launch let through.

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

A task file is Markdown under `eval/task/`, and [`eval/arena`] appends
[`eval/journal.md`] to it. Whatever the task itself asks the agent to
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
- **Pair it with checks** in the grader (below), run by
  `eval/check/<task>`, which takes the arena directory and ends in a
  verdict line.
- **Say what, never how.** Name the outcome -- tests that pass, examples
  cosmic checks, code formatted the way cosmic formats it, a binary that
  runs alone -- and never the cosmic command that gets it. Finding the
  command is the thing being measured; a task that names `cosmic test`
  has already answered it. The grader, not the task, runs the commands.
- **Say what the binary's environment will be.** The grader runs it with
  an empty environment; the task says so in the same words.
- **Keep the journal contract out of the task.** It is the same for
  every task and lives in [`eval/journal.md`].
- **Name a library API the grader holds the project to.** A task whose
  checks only run the executable is met by glue around the standard
  library, with every decoded value cast to the shape it is assumed to
  have. Each task but pack also names its module and a small API --
  exact names, records, enums, an interface, a generic, methods, a
  `<close>`-able value -- that a hidden test (below) compiles against
  and calls, so a type the project exports as `any`, or a value cast
  rather than checked, fails it.
- **Write it as `cosmic fix` leaves it, whatever the project
  declares.** The task is the solver's TASK.md, inside the project
  whose `cosmic fix --check` the grader runs. Name the API as a list
  item's head before a `:` (`` - `jobs.Plan`: a record ``), and write
  no other code span spelling a name in the module (a file named
  `notes.db`, under notes, spells its `db`): `fix` would link it once
  the project declares it ([`eval/arena_test.tl`] holds every task to
  this).

## grading

One grader, [`eval/check/grade.tl`], grades every task; each
`eval/check/<task>` runs it for that task on the bootstrap cosmic with
`--standalone`, which loads no module beside the file, so the plumbing
and every task's checks live in that one file, requiring `cosmic.*`
modules only. For each task it

1. requires `project/JOURNAL.md` to be a regular file with something
   in it, as the journal contract asks -- what it says is the
   reader's to judge, not the grader's;
2. clears the runs `project/o/build.db` records, runs the arena's own
   `bin/cosmic test` (workers unsandboxed, as for step 4), and requires
   a passing test and a passing example (or doctest) among the runs
   that test recorded;
3. runs `cosmic fix --check` with `JOURNAL.md` set aside;
4. for a task that names a library API, copies the project, but for
   its `o/`, into a temporary directory, adds the task's hidden test,
   [`eval/check/testdata/<task>_api_test.tl`](check/testdata), and runs
   `cosmic test` on that file alone there (unsandboxed, as step 2):
   each test that fails, or each line the compiler refuses (a module, type or method missing, a
   type that does not fit), is a `check: FAIL hidden api: ...` line.
   The solver never sees the test, the project never holds it, and
   the copy is removed afterward; its output is kept as a
   `check-<n>.out`;
5. runs `cosmic build`;
6. copies `o/bin/<task>` -- only when that build passed and named it --
   alone into the arena's `empty/`, and runs the task's checks there,
   the executable with an empty environment but for a variable a check
   names.

Both `cosmic test` steps run with `COSMIC_TEST_SANDBOX=0`, and
`COSMIC_SANDBOX` and `COSMIC_CI_REQUIRE_SANDBOX` removed, whatever the
grader's own environment holds: the solver is uid 0 of a user namespace
without capabilities, where cosmic cannot sandbox a worker, so its
`cosmic test` ran unsandboxed, while the grader's host can sandbox. Left
to the host, a test that reached the network or a socket file without
declaring it in [`Test.policy`] would pass for the solver and fail at
grading. The hidden tests still declare what they use
([`eval/check/testdata_test.tl`] holds them to it), so they also pass
sandboxed.

Each step's output is kept in the arena as `check-<n>.out`, and a server
task's as `check-serve.out` (relay's as `check-relay*.out`). Every check
prints one `check: ok` or `check: FAIL` line, and the last line is
`check: PASS` or `check: FAIL`, exiting 0 or 1.

To add a task: write `eval/task/<task>.md`, a function `<task>(g)` in
grade.tl's section for it, built from the helpers above them (`expect`,
`refuses`, `help`, `run`, `write`, `check`, and for a server `serves`,
`stops` and `exchange`), an entry in `TASKS` (how long one run may take,
whether its stdin is /dev/null and its children outlive it, and the
files a solver's own runs leave in the project that would answer for
the executable, and whether it has a hidden API test),
`eval/check/testdata/<task>_api_test.tl` for that test -- under
`testdata/`, so this tree neither builds nor runs it -- and
`eval/check/<task>`, a copy of a sibling naming the task. Before running
a model on it, grade a reference solution and a few broken ones (a
mutation for each check that matters, the hidden test's included) and
see each fail where it should. No reference solution is kept here: a
solver's arena must never be able to reach one.

## reading a journal

The summary at the top ranks what slowed the agent, with the log
entries it refers to; read those entries, not the ranking alone. The
solver rewrites it after every entry, so a run stopped at the deadline
or the turn cap still has one, current as of its last write. A journal
written once at the end (`journal_writes` of one or two) is a
retelling: weigh the transcript and [`eval/summarize`]'s counts over its
ranking. Then:

- **Check every claim about the tool against the transcript and the
  grader.** An agent that misread its own probe will rank the misreading
  first.
- **A guess that held up is still a gap**: the agent learned it from
  trying, not from the tool. The "guessed rather than learned" list is
  where the next help line or error message comes from.
- **"The one change that would have helped most"** has been right every
  time so far, and cheap. Start there.

[`bin/cosmic-bootstrap`]: ../bin/cosmic-bootstrap
[`bin/cosmic`]: ../bin/cosmic
[`eval/arena_test.tl`]: arena_test.tl
[`eval/arena`]: arena
[`eval/check/grade.tl`]: check/grade.tl
[`eval/check/testdata_test.tl`]: check/testdata_test.tl
[`eval/journal.md`]: journal.md
[`eval/solve`]: solve
[`eval/summarize`]: summarize
[`Test.policy`]: ../cosmic/test.tl
