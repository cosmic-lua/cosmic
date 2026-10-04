# Task

You have one tool you have never seen before: `cosmic`, a runtime for
command-line programs written in Teal (typed Lua). It is on your PATH.
The binary is the only source of information about it: there is no
documentation, repository, website, or package index for it, and you
must not use skills, plugins, web search, or any prior knowledge of a
project called "cosmic". Treat it as unknown. Anything the binary itself
tells you (help text, error messages, output of any command you can
think of running against it, or inspecting the file itself) is fair game.

Work only inside this directory. Do not read or write anything outside it
except the `cosmic` binary and scratch files under `$TMPDIR`, which is
yours for anything temporary.

## What to build

A small project, `jobs`, in Teal, using cosmic. It is a process
supervisor that runs a set of named jobs:

- `run <jobfile>` reads `<jobfile>`, a JSON object whose keys are job
  names and whose values are objects with these fields:
  - `cmd`: the job's argv, a non-empty array of strings. The program is
    named by its path; nothing searches `PATH` for it.
  - `needs`: names of jobs that must finish successfully before this
    one starts; none when absent.
  - `timeout`: seconds, possibly fractional, that one attempt may run;
    no limit when absent.
  - `retries`: how many more times a failed attempt is run again; 0
    when absent.
  - `env`: an object of strings, the job's whole environment: a job
    sees exactly these variables, none of `jobs`'s own; empty when
    absent.
  - `cwd`: the directory the job runs in; `jobs`'s own when absent.
- Jobs run as soon as everything they need has succeeded, at most
  `--parallel <n>` at once (2 by default; options may come before or
  after `<jobfile>`). A job any of whose needs did not succeed never
  runs: it is `skipped`, and so is anything needing it, however
  indirectly.
- An attempt fails when its program exits non-zero, is ended by a
  signal, or cannot be started at all. An attempt still running at its
  `timeout` is killed, together with every process it started, and
  counts as a timeout. A failed or timed-out attempt is run again while
  retries remain.
- With `--logs <dir>`, each job's stdout and stderr, every attempt's,
  go to `<dir>/<name>.log` (creating `<dir>` if needed); without it,
  they are discarded. Nothing a job writes reaches `jobs`'s own output.
- When every job has finished, `jobs` prints one JSON object to
  stdout, `{"jobs": {"<name>": {...}, ...}}`, with for each job:
  - `status`: `ok`, `failed`, `timeout`, `skipped` or `interrupted`,
    as its last attempt ended;
  - `code`: the exit code of its last attempt, or `null` when there is
    none (never ran, could not start, killed);
  - `attempts`: how many attempts were made, one that could not
    start included (0 for a skipped job);
  - `start_ms` and `end_ms`: when its first attempt started and its
    last attempt ended, in whole milliseconds since `jobs` started,
    or `null` for a job that never ran.
  It exits 0 if every job is `ok`, and non-zero otherwise.
- Sent SIGTERM or SIGINT while jobs run, `jobs` stops every running job
  (and what it started), starts no more, prints the report with those
  jobs `interrupted` and the ones never started `skipped`, and exits
  non-zero, within a second or two.
- A jobfile is checked whole before any job runs. A jobfile that
  cannot be read or is not JSON is an error naming the problem. Past
  that, the first problem found, in the order below, is an error whose
  message is exactly the one shown, `<name>` the job's name and
  `<other>` the job it needs:
  1. the file's JSON is not an object (an array, a string, ...):
     `jobfile: must be an object of jobs`;
  2. then each job in byte order of its name, and in it each field in
     this order: a job that is not an object:
     `job <name>: must be an object`; `cmd` missing or not a non-empty
     array of strings: `job <name>: cmd must be a non-empty array of
     strings`; `needs` not an array of strings: `job <name>: needs
     must be an array of strings`; `timeout` not a number greater than
     0: `job <name>: timeout must be a positive number`; `retries` not
     a whole number 0 or more: `job <name>: retries must be a
     non-negative integer`; `env` not an object of strings: `job
     <name>: env must be an object of strings`; `cwd` not a string:
     `job <name>: cwd must be a string`; then any other field, the
     first in byte order: `job <name>: unknown field <field>`;
  3. then each job in name order, each of its `needs` in the order
     given, naming a job that does not exist:
     `job <name>: needs unknown job <other>`;
  4. then needs that form a cycle: `job <name>: needs form a cycle`,
     `<name>` a job in it.

  An error is one line on stderr holding that message, and a non-zero
  exit code; nothing runs.
- `help`: prints usage naming `run`, `--parallel` and `--logs`, to
  stdout, and exits 0. Run this one with no other arguments.
- Use cosmic's own process, JSON and time support rather than calling
  other programs to supervise yours.

The project's library module is named `jobs`, `require("jobs")`, and
exports at least this API, which the project's own program uses and
which is checked through these names and types:

- `jobs.Status`, an enum of the five statuses above: `"ok"`,
  `"failed"`, `"timeout"`, `"skipped"` and `"interrupted"`.
- `jobs.Job`, a record of one job as checked: `name: string` (its
  key), `cmd: {string}`, `needs: {string}` (empty when absent),
  `timeout: number` (nil when absent), `retries: integer` (0 when
  absent), `env: {string: string}` (empty when absent) and
  `cwd: string` (nil when absent).
- `jobs.Plan`, a record: `jobs: {string: jobs.Job}` by name, and
  `order: {string}`, every job's name once, each after every job it
  needs, choosing at each step the name first in byte order among
  those whose needs are all listed already.
- `jobs.plan(text: string): jobs.Plan | nil, string`: the plan for a
  jobfile's text, or nil and the message the error above names.

The project must have all four of these:

1. **Tests** of the project's own code, which cosmic runs and passes.
   Show them passing.
2. **Examples**: worked examples of using the project's own code, in
   whatever form cosmic treats as an example, so that cosmic itself
   checks or runs them.
3. **Formatting**: every Teal source formatted the way cosmic itself
   formats Teal.
4. **A binary**: a single standalone executable named `jobs`, produced
   by cosmic from this project, that runs the tool above on its own:
   copied alone into an empty directory and run with an empty
   environment (no `PATH`, no `HOME`, no `cosmic` anywhere), it still
   works. Show it running: `./jobs run some.json --parallel 3 --logs logs`
   with jobs that run `/bin/sh -c ...`.

How cosmic finds tests and examples, formats code, and produces a
binary is for you to find out from the binary.

## Deliverables, all in this directory

1. The project: source, tests, examples, and the produced `jobs`
   executable, working as far as you can get them.
2. `JOURNAL.md`, described below.
