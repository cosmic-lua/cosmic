# measuring

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

This guide shows how to find where a project's code and tests spend their
time, and which lines the tests reach. `cosmic test` records each test's
time and the lines it ran in the build directory's database, and
`cosmic sql --build` reads that database. [`Clock.span`] times a region of
the code itself.

## what a test run records

Each project has a build directory outside its checkout, and in it
`build.db`, the working database every build and test run writes.
`cosmic db` prints its path. `cosmic sql --build '<statement>'`, run in the
project's root, runs one read-only SQL statement against it and prints a
header line and a row a line, separated by tabs (`--to csv` or
`--to ndjson` for another format). A line on standard error says how many
rows came back.

These tables and columns are the interface this guide relies on. A query
that names only them keeps working as cosmic changes; the other tables of
`build.db` are the build's own and may change.

- `runs` holds one row per test, from the latest run that named it:
  - `path`: the test module, by module name (`tally_test`, or
    `lib.parse_test` for `lib/parse_test.tl`).
  - `test`: the test function's name.
  - `passed`: 1 for a pass, 0 for a failure, a skip, a pass that called no
    `assert`, or a test that cannot run on this host.
  - `message`: why it did not pass, or "" for a pass.
  - `elapsed_ns`: how long the test took, in nanoseconds, in the run that
    reached its verdict. A test whose verdict stood was not run again, so
    its time is that earlier run's.
  - `run_at_ns`: when the run that reached the verdict started, in
    nanoseconds since the epoch. A verdict taken from another checkout's run
    holds the time of the run that took it.
- `coverage` holds one row per executable line of the project, for each of
  the latest few runs:
  - `ran_at_ns`: when that run started. The latest run's rows are those
    with `ran_at_ns = (SELECT max(ran_at_ns) FROM coverage)`.
  - `path`: the module, by module name (`tally`).
  - `line`: the line number in the module's file.
  - `hit`: 1 where a test ran the line, else 0.

A run that names test files (`cosmic test tally_test.tl`) writes a coverage
row for every line of the project, hit only by the tests it ran.

A run counts the lines its tests reach in every module, the ones they
import included, sandboxed (the default on Linux) or not. A test whose
verdict stands brings the hits of the run that reached it. A module's hits
count only on the text they were counted on: where that text has changed
since, they are left out, and the coverage line says the figure is partial
until `--all` runs those tests again. A comment or a blank line added to a
module a sandboxed test imports runs no test, so it leaves that module's
figure partial until then.

## slowest tests

```text
cosmic sql --build "SELECT path, test, elapsed_ns / 1000000 AS ms FROM runs ORDER BY elapsed_ns DESC LIMIT 20"
```

prints the twenty slowest, in milliseconds:

```text
path	test	ms
lang.check_test	test_a_chain_of_any_length_is_checked_without_recursion	1140
lang.check_test	test_each_case_has_its_error_with_place_message_and_fix	899
lang.check_flow_fuzz_test	test_a_program_over_locals_the_flow_takes_does_not_fail_at_a_narrowed_read	801
```

Sum by module to find the module that costs the most:
`SELECT path, sum(elapsed_ns) / 1000000 AS ms FROM runs GROUP BY path ORDER BY ms DESC`.
To time every test now rather than as each verdict was reached, run
`cosmic test --all` first.

## lines no test reaches

The lines of one module that the latest run did not reach:

```text
cosmic sql --build "SELECT line FROM coverage WHERE path = 'tally' AND hit = 0 AND ran_at_ns = (SELECT max(ran_at_ns) FROM coverage) ORDER BY line"
```

The share of each module's lines that the latest run reached, least first:

```text
cosmic sql --build "SELECT path, sum(hit) AS hit, count(*) AS lines FROM coverage WHERE ran_at_ns = (SELECT max(ran_at_ns) FROM coverage) GROUP BY path ORDER BY sum(hit) * 1.0 / count(*)"
```

`cosmic test` prints the whole project's share as its `test: coverage` line,
and `--min` and `--min-file` make a floor of it (`cosmic help test`). A
partial figure is at most what the tests reach: judge a floor after
`--all`.

## trying it

This runs the recipes on a small project. `words` is tested and `shout` is
not, so the lines of `shout` are the ones no test reaches.

```teal file=tally.tl
local record Tally
end

function Tally.words(text: string): integer
  local n = 0
  for _ in text:gmatch("%S+") do
    n = n + 1
  end
  return n
end

function Tally.shout(text: string): string
  if text == "" then
    return "(nothing)"
  end
  return text:upper()
end

return Tally
```

```teal file=tally_test.tl
local Tally = require("tally")

local function test_counts_words()
  assert(Tally.words("a b  c") == 3)
end

local function test_counts_none()
  assert(Tally.words("") == 0)
end
```

```teal
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")

local relaunch = assert(Proc.relaunch())
local env: mut {string: string} = {}
for name, value in pairs(Env.all()) do env[name] = value end
for name, value in pairs(relaunch.env) do env[name] = value end
env["COSMIC_TEST_SANDBOX"] = "0"
local function cosmic(...: string): string
  local argv = { table.unpack(relaunch.argv) }
  for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
  local said = assert(Child.run(argv, { env = env, fds = relaunch.fds, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(120) }))
  assert(said.code == 0, said.stderr)
  return said.stdout or ""
end

local function query(statement: string)
  print((cosmic("sql", "--build", statement):gsub("\n$", "")))
end

local _ = cosmic("test", "--all")
query("SELECT path, test, passed FROM runs ORDER BY test")
query("SELECT line FROM coverage WHERE path = 'tally' AND hit = 0 AND " ..
  "ran_at_ns = (SELECT max(ran_at_ns) FROM coverage) ORDER BY line")
query("SELECT path, sum(hit) AS hit, count(*) AS lines FROM coverage WHERE " ..
  "ran_at_ns = (SELECT max(ran_at_ns) FROM coverage) GROUP BY path ORDER BY path")
```

```output
path	test	passed
tally_test	test_counts_none	1
tally_test	test_counts_words	1
line
13
14
16
path	hit	lines
tally	7	10
tally_test	5	5
```

## timing a region of code

[`Clock.span`] times the code from where it is called to the end of the
block that holds it, by name, and [`Clock.report`] lists the names by the
time spent in each. Hold the span in a `<close>` local. In a loop's body each
pass is a span of its own.

```teal
local Clock = require("cosmic.clock")

local spans: Clock.Spans = {}
local words = 0
for _, line in ipairs({ "one two", "three four five", "six" }) do
  local _t <close> = Clock.span(spans, "count")
  for _ in line:gmatch("%S+") do
    words = words + 1
  end
end
print(words, assert(spans["count"]).count)
for _, line in ipairs(Clock.report(spans)) do
  print((line:gsub("[%d.]+ ms", "N ms")))
end
```

```output
6	3
count  3 spans, N ms wall, N ms cpu
```

A test prints its report where `cosmic test --show-output` shows it, beside
the pass (add `--all` to run a test whose verdict stands). A program prints
it when it ends.

## a profiler

A sampling profiler, which needs no change to the code it measures, is on
the [roadmap](../roadmap.md#measuring): `cosmic test --profile` would record
each function's and line's own time into a table of `build.db`.

[`Clock.report`]: ../../cosmic/clock.tl
[`Clock.span`]: ../../cosmic/clock.tl
