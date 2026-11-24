# the command line

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

`cosmic` takes a verb, such as `test`, `fix`, `build` or `docs`, or a
path to a file to run. The examples here run `cosmic` and show what it
prints. The Teal ones start it through [`cosmic.child`], the way
`cosmic test` starts its workers: [`Proc.relaunch`] names the core it runs
on and what the launcher would hand it, so the start needs no shell.

## a one-liner

`cosmic -e '<chunk>'` runs a chunk of Teal against the standard
library. No tree is built. The chunk is checked as a file is, and one
the checker refuses does not run: its messages are printed and `-e`
exits 4, the status of code that did not compile. It takes the library by `require("cosmic.json")`, with a
literal name, as a file does, and the tool's own modules the same way;
nothing is bound for it. The words after
the chunk are its `...`, each a `string?`, and an integer it returns is
the exit code.

```sh
cosmic -e 'print(select("#", ...), ...)' a b
cosmic -e 'return 3'  # exits 3
```

```output
2	a	b
```

A chunk prints only what it prints. It gets no summary, as a file run
gets none.

## a script run by its name

A file can be run by its own name, as a shell script is: mark it
executable and make its first line `#!/usr/bin/env cosmic`. The language
skips that line, as Lua does, so the lines after it keep their numbers in
errors and tracebacks. Only the first line of the file, from its first
byte, is skipped, and only when it begins `#!`; a `#!` anywhere else is a
syntax error. The language
server leaves the line as it is.

The file is Teal, in a file that ends in `.tl`. A `.lua` file is not run,
and no `require` finds one: `cosmic hello.lua` says that cosmic runs
Teal, checked, and to rename the file to `hello.tl` and run `cosmic fix`
on it to see what the checker asks of it.

A file that requires only `cosmic.*` modules runs as `cosmic --standalone`
runs it. No tree is built around it, so nothing is staged and no build
directory is written. This holds where each `require` names its module
with a literal string, and the file is no program's `cmd/<name>/main.tl`
and no `_test.tl`, outside cosmic's own checkout. A file that requires a
module of its project builds the tree, as `COSMIC_STANDALONE=0` makes any
file do.

## help for one verb

`cosmic help` prints a short index, a line per verb. `cosmic help <verb>`
prints that verb's usage, its summary, options and examples, then its
full text; `--help` or `-h` anywhere on a
verb's line, before a `--`, does the same. It prints no summary: stdout
holds the text alone, and stderr nothing. `cosmic help exit` says
what the exit codes and summaries mean.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

-- Run it outside any tree, so no build is involved.
local dir = assert(Fs.mkdtemp("help-"))
local relaunch = assert(Proc.relaunch())
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = "help"
argv[#argv + 1] = "db"
local result = assert(Child.run(argv,
  { env = env, fds = relaunch.fds, cwd = dir, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(10) }))
assert(Fs.remove_tree(dir))
local out = result.stdout or ""
print(out:match("^usage: cosmic db[^\n]*"))
local verbs = 0
for line in out:gmatch("[^\n]+") do
  if line:sub(1, 8) == "`cosmic " then verbs = verbs + 1 end
end
print(("%d verb"):format(verbs))
print(out:find("help: ", 1, true) == nil, result.stderr == "")
```

```output
usage: cosmic db [path...]
1 verb
true	true
```

## paths narrow a verb

A verb takes paths to narrow it. `cosmic build cmd/hi` builds the tree
but writes only the programs under `cmd/hi`. With `--host`, as here, each
is this system's native executable, which runs with no launcher.

```teal file=cmd/hi/main.tl
return function(): integer
  print("hi")
  return 0
end
```

```teal file=cmd/bye/main.tl
return function(): integer
  print("bye")
  return 0
end
```

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

local relaunch = assert(Proc.relaunch())
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
local argv = { table.unpack(relaunch.argv) }
for _, word in ipairs({ "build", "--host", "cmd/hi" }) do argv[#argv + 1] = word end
local built = assert(Child.run(argv,
  { env = env, fds = relaunch.fds, cwd = tmp, stdout = "capture", timeout_ns = Clock.seconds(60) }))
print("exit " .. tostring(built.code))
-- The build prints each program it wrote, a path per line.
local program = assert(("\n" .. (built.stdout or "")):match("\n(/[^\n]+)"))
local hi = assert(Fs.status(program)).exists
local bye = assert(Fs.status(Fs.dirname(program) .. "/bye")).exists
print(Fs.basename(program) .. ": " .. tostring(hi) .. ", bye: " .. tostring(bye))
local ran = assert(Child.run({ program }, { stdout = "capture", timeout_ns = Clock.seconds(10) }))
print(((ran.stdout or ""):gsub("\n$", "")))
```

```output
exit 0
hi: true, bye: false
hi
```

`test`, `fix` and `todos` take paths the same way. `uses` takes paths
after its symbol, and `db` counts only the rows about the sources under
them. `docs` takes
words to search for, `sql` one statement, `refresh` the datasets to fetch,
`bom` nothing, and `help` a verb.

[`cosmic.child`]: ../../cosmic/child/init.tl
[`Proc.relaunch`]: ../../cosmic/proc.tl
