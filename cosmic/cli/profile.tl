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
--- - With no `--by`, it prints the processes' totals, the spans (each under the span it stood in, with its count,
---   wall time and CPU time), then the functions with the most time of their own, and those with the most time in
---   their stack.
--- - `--by function` prints the functions by their own time: the innermost frame of each sample, a C function
---   included. `--by stack` counts a function once in each sample whose stack holds it, so a recursive one is not
---   counted twice. `--by line` prints the innermost Lua lines. `--by span` prints the spans alone. `--by process`
---   prints each process: its id, its parent, its CPU time, its sampled time, and its command line.
--- - `--top N` is how many rows each list has (default 25).
--- - `--process PID` reads the profile of that process alone.
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
  },
  spec = {
    ["--by"] = { value = "kind", about = "print one list: functions by own time, stacks, lines, spans or processes",
      choices = { "function", "stack", "line", "span", "process" } },
    ["--top"] = { value = "n", about = "the rows of each list", integer = { min = 1, max = 100000 }, default = "25" },
    ["--process"] = { value = "pid", about = "read the profile of this process alone", integer = { min = 1 } },
    ["--folded"] = { about = "print each stack and its microseconds, for a flame graph tool" },
  },
}

return command
