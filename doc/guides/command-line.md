# the command line

`cosmic` takes a verb, such as `test`, `fix`, `build` or `docs`, or a
path to a file to run. Each example here starts the `cosmic` that runs
it, through `cosmic.child`, and shows what it prints.

## a one-liner

`cosmic -e '<chunk>'` runs a chunk of Lua, as `lua -e` does, against
the standard library. No tree is built. The words after the chunk are
its `...`, and an integer it returns is the exit code.

```teal
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")

local cosmic = assert(Proc.executable())
local said = assert(Child.run({ cosmic, "-e", "print(select('#', ...), ...)", "a", "b" },
  { stdout = "capture", timeout_ms = 10000 }))
print(((said.stdout or ""):gsub("\n$", "")))
local exited = assert(Child.run({ cosmic, "-e", "return 3" }, { timeout_ms = 10000 }))
print("exit " .. tostring(exited.code))
```

```output
2	a	b
exit 3
```

A chunk prints only what it prints. It gets no verdict line, as a
file run gets none.

## help for one verb

`cosmic help` prints every verb. `cosmic help <verb>` prints only that
verb's line, then a verdict line.

```teal
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")

local result = assert(Child.run({ assert(Proc.executable()), "help", "db" },
  { cwd = tmp, stdout = "capture", timeout_ms = 10000 }))
local out = result.stdout or ""
print(out:match("^[^\n]*"))
local verbs = 0
for line in out:gmatch("[^\n]+") do
  if line:sub(1, 8) == "`cosmic " then verbs = verbs + 1 end
end
print(verbs .. " verb")
print(out:match("help: PASS %(1 verb") ~= nil)
```

```output
`cosmic db [path...]`: what the two databases under o/ hold --
1 verb
true
```

## paths narrow a verb

A verb takes paths to narrow it. `cosmic build cmd/hi` builds the tree
but writes only the programs under `cmd/hi`.

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
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local built = assert(Child.run({ assert(Proc.executable()), "build", "cmd/hi" },
  { cwd = tmp, stdout = "capture", timeout_ms = 60000 }))
print("exit " .. tostring(built.code))
local hi, _ = Fs.exists(tmp .. "/o/bin/hi")
local bye, _ = Fs.exists(tmp .. "/o/bin/bye")
print("hi: " .. tostring(hi) .. ", bye: " .. tostring(bye))
local ran = assert(Child.run({ tmp .. "/o/bin/hi" }, { stdout = "capture", timeout_ms = 10000 }))
print(((ran.stdout or ""):gsub("\n$", "")))
```

```output
exit 0
hi: true, bye: false
hi
```

`test`, `fix` and `todos` take paths the same way. `uses` takes paths
after its symbol, and `db` the databases to describe. `docs` takes
words to search for, and `help` a verb.
