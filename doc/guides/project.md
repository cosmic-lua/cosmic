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

## a record with methods

A record is also how a module makes values that carry methods. The
methods are functions on the record's own table, and each value finds
them through a metatable whose `__index` is that table: a value made
without `setmetatable` type-checks, then fails when a method is called,
with `attempt to call a nil value (method 'add')`.

```teal file=counts.tl
--- How many times each word appears in some text.

local record Counts
  --- One word and how many times it appeared.
  record Entry
    word: string
    times: integer
  end

  --- Each word seen, and how many times.
  seen: {string:integer}
end

-- A value's methods: those of the Counts table.
local counts_mt: metatable<Counts> = { __index = Counts }

--- Counts with no words in them yet.
function Counts.new(): Counts
  return setmetatable({ seen = {} }, counts_mt)
end

--- Counts each word of `text`, split on whitespace.
function Counts:add(text: string)
  for word in text:gmatch("%S+") do
    self.seen[word] = (self.seen[word] or 0) + 1
  end
end

--- Every word seen, the most frequent first, then in byte order.
function Counts:top(): {Counts.Entry}
  local out: {Counts.Entry} = {}
  for word, times in pairs(self.seen) do
    out[#out + 1] = { word = word, times = times }
  end
  table.sort(out, function(a: Counts.Entry, b: Counts.Entry): boolean
    if a.times ~= b.times then return a.times > b.times end
    return a.word < b.word
  end)
  return out
end

return Counts
```

A record declared inside another, like `Entry` here, is `Counts.Entry`
to every module; `record Counts.Entry` written outside the record's body
is refused. Another module names the types through the same `require`:
`local Counts = require("counts")` is the module, `Counts` the type of
a value `Counts.new()` makes, and `Counts.Entry` the nested one. A
module that only names the types, and calls nothing, writes `local
type Counts = require("counts")`.

```teal file=counts_test.tl
local Counts = require("counts")

local function test_top()
  local counts = Counts.new()
  counts:add("b a b")
  local top: {Counts.Entry} = counts:top()
  assert(top[1].word == "b" and top[1].times == 2)
  assert(top[2].word == "a" and top[2].times == 1)
end
```

## a program with commands

[`cosmic.flags`] reads the command line. The program's first word is a
command, `words` or `top`, and [`Flags.dispatch`] runs the one it names
with the words after it: `got.words[1]` is the file, not the command.
Each command's spec names its options and whether each takes a value,
and they may come before the file or after it; any other option is
refused, so a typo is never read as a file name. `tally --help`, and
`tally top --help`, print help written from the same descriptions. A
program with no commands parses its options with `Flags.parse(argv, 1,
spec)` instead. [`cosmic.log`] writes what went wrong to standard error
under the program's name. The function's result is the exit code.

```teal file=cmd/tally/main.tl
local Counts = require("counts")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Log = require("cosmic.log")
local Tally = require("tally")

local log = Log.new("tally")

--- The file a command names, or standard input; nil once it has said
--- why it could not read it.
local function input(got: Flags.Parsed): string | nil
  local text, trouble = Fs.read(got.words[1] or "/dev/stdin")
  if text == nil then
    log:complain(trouble)
  end
  return text
end

local function show(entry: Counts.Entry)
  print(entry.word .. "\t" .. entry.times)
end

local commands: {string:Flags.Command} = {
  words = {
    about = "Counts the words of a file, or of standard input.",
    usage = "[options] [file]",
    spec = { ["--lines"] = { about = "count lines instead" } },
    run = function(got: Flags.Parsed): integer
      local text = input(got)
      if text == nil then return 1 end
      if got.set["--lines"] then
        local lines = 0
        for _ in text:gmatch("[^\n]+") do
          lines = lines + 1
        end
        print(lines)
      else
        print(Tally.words(text))
      end
      return 0
    end,
  },
  top = {
    about = "Lists the most frequent words.",
    usage = "[options] [file]",
    spec = { ["--limit"] = { value = "n", about = "list at most n words" } },
    run = function(got: Flags.Parsed): integer
      local limit = math.tointeger(tonumber(got.values["--limit"] or "10"))
      if limit == nil then
        log:complain("--limit takes a whole number")
        return 2
      end
      local text = input(got)
      if text == nil then return 1 end
      local counts = Counts.new()
      counts:add(text)
      for at, entry in ipairs(counts:top()) do
        if at > limit then break end
        show(entry)
      end
      return 0
    end,
  },
}

return function(argv: {string}): integer
  local ran, why = Flags.dispatch(argv, 1, commands, "tally")
  if ran == nil then
    log:complain(why)
    return 2
  end
  if ran.help ~= "" then
    print(ran.help)
  end
  return ran.code
end
```

```teal file=words.txt
the cat saw the dog
```

## the verbs

```text
cosmic fix                                format every file, and check it parses
cosmic test                               run every test and example
cosmic cmd/tally/main.tl words words.txt  run the program
cosmic build                              write o/bin/tally
cosmic docs tally                         what your own module offers
```

`cosmic fix` rewrites each file in canonical layout, in place: run it
after editing. `cosmic test` builds the tree, then runs each test, and
skips one whose code and inputs have not changed since it last passed.
`cosmic cmd/tally/main.tl words words.txt` runs the program from source. `cosmic
build` writes `o/bin/tally`, and `cosmic build cmd/tally` writes only that
one. `cosmic docs` lists your own modules with the standard library's, and
`cosmic docs Tally.words` shows a function with the examples that call it.

`o/bin/tally` is the whole program: copy that one file to a Linux (x86-64
or arm64) or arm64 macOS host with no cosmic on it and it runs, even with
an empty environment (`env -i ./tally`). `file` calls it a shell script
because it starts as one: a /bin/sh launcher with a core for each
supported system and the program appended. On a host's first run the
launcher copies that host's core into a private cache
(`~/.cache/cosmic/cores`, `~/Library/Caches/cosmic/cores` on macOS, or
`/tmp/cosmic-cores-<uid>` with no `HOME`; `cosmic help build` lists the
rest) and runs it from there. `cosmic build --host` writes instead a
native executable for this system alone, which needs no shell and writes
no cache: the choice for a container with no /bin/sh, or a host with
nowhere to write.

## trying it

This runs the verbs above on the files of this guide, each through
[`cosmic.child`], as the guide for the command line does. It builds with
`--host`, a native executable for this system with no launcher.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

local relaunch = assert(Proc.relaunch())
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
env["COSMIC_TEST_SANDBOX"] = "0"
local function cosmic_in(dir: string, ...: string): Child.Result
  local argv = { table.unpack(relaunch.argv) }
  for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
  return (assert(Child.run(argv, { env = env, fds = relaunch.fds, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(120) })))
end
local function cosmic(...: string): Child.Result
  return cosmic_in(tmp, ...)
end
local function verdict(said: Child.Result, verb: string)
  print(((said.stderr or "") .. (said.stdout or "")):match(verb .. ": [A-Z]+"))
end

verdict(cosmic("fix"), "fix")
verdict(cosmic("test"), "test")
print(((cosmic("cmd/tally/main.tl", "words", "words.txt").stdout or ""):gsub("\n$", "")))
print(((cosmic("cmd/tally/main.tl", "top", "words.txt", "--limit", "2").stdout or ""):gsub("\n$", "")))
local missing = cosmic("cmd/tally/main.tl", "words", "--nope")
print(missing.code, ((missing.stderr or ""):gsub("\n$", "")))
print(((cosmic("cmd/tally/main.tl", "--help").stdout or ""):gsub("\n$", "")))
verdict(cosmic("build", "--host"), "build")
local built = assert(Child.run({ tmp .. "/o/bin/tally", "words", "words.txt" },
  { cwd = tmp, stdout = "capture", timeout_ns = Clock.seconds(60) }))
print(((built.stdout or ""):gsub("\n$", "")))
verdict(cosmic_in(tmp .. "/cmd/tally", "test"), "test")
print((cosmic("docs", "tally").stdout or ""):match("^[^\n]*"))
```

```output
fix: PASS
test: PASS
5
the	2
cat	1
2	tally: words: no such option: --nope
usage: tally <command> [options]

commands:
  top    Lists the most frequent words.
  words  Counts the words of a file, or of standard input.

Run `tally <command> --help` for a command's options.
build: PASS
5
test: PASS
tally (tally.tl)
```

[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.flags`]: ../../cosmic/flags.tl
[`cosmic.log`]: ../../cosmic/log.tl
[`Flags.dispatch`]: ../../cosmic/flags.tl
