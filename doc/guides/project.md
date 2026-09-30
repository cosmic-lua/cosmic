# your first project

<!-- needs: tool = true -->

A cosmic project is a directory of modules, tests, examples and
programs. They are Teal files: typed Lua, documented at
<https://teal-language.org>. This guide builds a small project,
`tally`, that counts the words in a file, and shows where each kind of
file goes. Run the first build or test at the project's root, the
directory that holds the files below. After that, a verb run from any
directory inside the project uses the root's tree.

## the files

A file's name says what it is.

- `name.tl` is a library module, `require("name")`. A directory
  `name/` holding an `init.tl` is the same module, `require("name")`,
  with room for files of its own beside it.
- `name_test.tl` holds tests: each top-level `local function test_*`
  is one test. Nothing is returned or registered.
- `name_example.tl` holds worked examples: it returns a record named
  `Example`, with one function per example.
- `cmd/<name>/main.tl` is a program: it returns a function of `argv`,
  the words after the file on the command line.

`cosmic docs cosmic.layout` and `cosmic docs cosmic.entrypoint` say
the same in full.

## a library module

The first line comment of a module, and the comment above each
function, are what `cosmic docs` shows for it.

```teal file=tally.tl
--- Counting words in text.

local record Tally
end

--- The number of words in `text`, split on whitespace.
function Tally.words(text: string): integer
  local count = 0
  for _ in text:gmatch("%S+") do
    count = count + 1
  end
  return count
end

return Tally
```

## write a test

A test fails when it raises an error, so `assert` is the whole
vocabulary.

```teal file=tally_test.tl
local Tally = require("tally")

local function test_words()
  assert(Tally.words("a b  c") == 3)
  assert(Tally.words("") == 0)
end
```

## an example

An example is a test that `cosmic docs` also shows under each symbol
it calls, so it teaches as it checks.

```teal file=tally_example.tl
local Tally = require("tally")

local record Example
end

function Example.words()
  print(Tally.words("one two three"))
end

return Example
```

## a program with options

[`cosmic.flags`] reads the command line. A spec names each option and
whether it takes a value; any other option is refused, so a typo is
never read as a file name. [`cosmic.log`] writes what went wrong to
standard error under the program's name. The function's result is the
exit code.

```teal file=cmd/tally/main.tl
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Log = require("cosmic.log")
local Tally = require("tally")

local log = Log.new("tally")

return function(argv: {integer:string}): integer
  local parsed, why = Flags.parse(argv, 1, { ["--lines"] = false })
  if parsed == nil then
    log:complain(why)
    return 2
  end
  local text, trouble = Fs.read(parsed.words[1] or "/dev/stdin")
  if text == nil then
    log:complain(trouble)
    return 1
  end
  if parsed.set["--lines"] then
    local lines = 0
    for _ in text:gmatch("[^\n]+") do
      lines = lines + 1
    end
    print(lines)
  else
    print(Tally.words(text))
  end
  return 0
end
```

```teal file=words.txt
hello big world
```

## the verbs

```text
cosmic fix                          format every file, and check it parses
cosmic test                         run every test and example
cosmic cmd/tally/main.tl words.txt  run the program
cosmic build                        write o/bin/tally
cosmic docs tally                   what your own module offers
```

`cosmic fix` rewrites each file in canonical layout, in place: run it
after editing. `cosmic test` builds the tree, then runs each test, and
skips one whose code and inputs have not changed since it last passed.
`cosmic cmd/tally/main.tl words.txt` runs the program from source. `cosmic
build` writes `o/bin/tally`, one file that runs on its own with nothing
beside it, and `cosmic build cmd/tally` writes only that one. `cosmic
docs` lists your own modules with the standard library's, and `cosmic
docs Tally.words` shows a function with the examples that call it.

## trying it

This runs the verbs above on the files of this guide, each through
[`cosmic.child`], as the guide for the command line does. It builds with
`--host`, a native executable for this system with no launcher.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")

local relaunch = assert(Proc.relaunch())
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
env["COSMIC_TEST_SANDBOX"] = "0"
local function cosmic_in(dir: string, ...: string): Child.Result
  local argv = { table.unpack(relaunch.argv) }
  for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
  return (assert(Child.run(argv, { env = env, fds = relaunch.fds, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ms = 120000 })))
end
local function cosmic(...: string): Child.Result
  return cosmic_in(tmp, ...)
end
local function verdict(said: Child.Result, verb: string)
  print(((said.stderr or "") .. (said.stdout or "")):match(verb .. ": [A-Z]+"))
end

verdict(cosmic("fix"), "fix")
verdict(cosmic("test"), "test")
print(((cosmic("cmd/tally/main.tl", "words.txt").stdout or ""):gsub("\n$", "")))
local missing = cosmic("cmd/tally/main.tl", "--nope")
print(missing.code, ((missing.stderr or ""):gsub("\n$", "")))
verdict(cosmic("build", "--host"), "build")
local built = assert(Child.run({ tmp .. "/o/bin/tally", "words.txt" },
  { cwd = tmp, stdout = "capture", timeout_ms = 60000 }))
print(((built.stdout or ""):gsub("\n$", "")))
verdict(cosmic_in(tmp .. "/cmd/tally", "test"), "test")
print((cosmic("docs", "tally").stdout or ""):match("^[^\n]*"))
```

```output
fix: PASS
test: PASS
3
2	tally: no such option: --nope
build: PASS
3
test: PASS
tally (tally.tl)
```

[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.flags`]: ../../cosmic/flags.tl
[`cosmic.log`]: ../../cosmic/log.tl
