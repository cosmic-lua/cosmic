--- `cosmic profile [options] <dir|file|->...`: reads the profiles a run with `COSMIC_PROFILE=<dir>` wrote, and
--- prints where their time went. It only reads: it runs nothing and writes no file.
---
---     COSMIC_PROFILE=prof bin/cosmic fix --check .
---     cosmic profile prof
---     cosmic profile --by line --top 10 prof
---     cosmic profile --folded prof > stacks.txt
---
--- A directory stands for each `.prof` file in it; `-` is standard input. Each process wrote one file,
--- and the report adds them up:
---
--- - With no `--by`, it prints the processes' totals (the largest peak resident set among them), the spans (each
---   under the span it stood in, with its count, wall time, CPU time, and the most the Lua heap held as one
---   closed), then the functions with the most time of their own, and those with the most time in their stack.
---   A module a process loads is a span `[require:<module>]` too, left out here.
--- - `--by function` prints the functions by their own time: the innermost frame of each sample, a C function
---   included. `--by stack` counts a function once in each sample whose stack holds it, so a recursive one is not
---   counted twice. `--by line` prints the innermost Lua lines. `--by span` prints the spans alone, the modules'
---   loads too. `--by require` prints the modules loaded, by the wall time each took with what it required.
---   `--by process` prints each process: its id, its parent, its CPU time, its sampled time, its peak resident
---   set, and its command line.
--- - `--top N` is how many rows each list has (default 25).
--- - `--process PID` reads the profile of that process alone. A process in a sandbox has the pid it has there,
---   so each sandboxed test worker is pid 2: its command line tells it apart.
--- - `--per-process` adds a row under each span for each process that closed one (its count, wall and CPU time, its
---   file and its command), most CPU first: which of a fanned run's workers spent a phase's time.
--- - `--against OLD` compares the spans with those of an older run's profiles (a directory, a file or `-`): each
---   span's wall and CPU time then and now, and the change. It takes `--by span` or no `--by`.
--- - `--folded` prints each stack and its microseconds on a line (`a;b;c 1234`), the spans first, for a flame graph
---   tool.
---
--- Its standard output is the report, and it prints no summary. It exits 0 when it printed. It exits 2 for a command
--- line that it refuses, and 5 for a file it cannot read, one that is not a profile, or a write that fails.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "print where the time of a profiled run went",
  usage = "[options] <dir|file|->...",
  examples = {
    { line = "prof", about = "the report of every profile in prof/" },
    { line = "--by line --top 10 prof", about = "the ten lines with the most time" },
    { line = "--folded prof", about = "folded stacks, for a flame graph" },
    { line = "--against old-prof prof", about = "each span's time against an older run's" },
  },
  spec = {
    ["--by"] = { value = "kind", about = "print one list: functions by own time, stacks, lines, spans, processes or modules loaded",
      choices = { "function", "stack", "line", "span", "process", "require" } },
    ["--top"] = { value = "n", about = "the rows of each list", integer = { min = 1, max = 100000 }, default = "25" },
    ["--process"] = { value = "pid", about = "read the profile of this process alone", integer = { min = 1 } },
    ["--folded"] = { about = "print each stack and its microseconds, for a flame graph tool" },
    ["--per-process"] = { about = "under each span, a row for each process that closed one" },
    ["--against"] = { value = "dir", about = "compare each span's time with an older run's profiles" },
  },
}

return command
