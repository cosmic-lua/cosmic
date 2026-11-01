# your first project

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

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
- `name.tmpl` is a typed template ([`cosmic.template`]), built into the
  module `require("name")` with a `render` function: `pages/home.tmpl`
  is `pages.home`, `pages/init.tmpl` is `pages`. Nothing generated is
  kept, and an error carries the template's own line (its column is the
  generated code's).
- `name_test.tl` holds tests: each top-level `local function test_*`
  is one test. Nothing is returned or registered.
- `name_example.tl` holds worked examples: it returns a record named
  `Example`, with one function per example.
- `cmd/<name>/main.tl` is a program: it returns a function of `argv`,
  the words after the file on the command line.

`cosmic docs cosmic.layout` and `cosmic docs cosmic.entrypoint` say
the same in full.

A module shares a value by returning it for another to `require`. A
build refuses `global` (`global x`, `global function`, `global record`)
and a `function f()` with no local `f` in scope, at the line and column
of the declaration: put the value in a module and require it. It refuses
them in a `.d.tl` file too.

A `.d.tl` declares a module implemented in C, and says so with the line
`--- @kind binding` in its leading comment. A build refuses a `.d.tl` that
does not, naming the file: a file of types or code is a `.tl`, which is checked
and real at run time.

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

## a class with methods

A class is how a module makes values that carry methods. Its methods are
declared inside it, with `self` as the first parameter, and a value is a
table literal typed as the class: there is no metatable to set, and a
method is always found. A module that offers such values declares what
they do in an interface and returns a record that names it, so another
module never sees the class itself.

```teal file=counts.tl
--- How many times each word appears in some text.

local Fs = require("cosmic.fs")

local record Counts
  --- One word and how many times it appeared.
  record Entry
    word: string
    times: integer
  end

  --- What a count of words does.
  interface Tally
    add: function(self: Tally, text: string)
    top: function(self: Tally): {Counts.Entry}
  end

  new: function(): Counts.Tally
  open: function(path: string): Counts.Tally?, string
end

--- Each word seen, and how many times.
local class Seen is Counts.Tally
  words: mut {string:integer}

  --- Counts each word of `text`, split on whitespace.
  function add(self, text: string)
    for word in text:gmatch("%S+") do
      self.words[word] = (self.words[word] or 0) + 1
    end
  end

  --- Every word seen, the most frequent first, then in byte order.
  function top(self): {Counts.Entry}
    local out: mut {Counts.Entry} = {}
    for word, times in pairs(self.words) do
      out[#out + 1] = { word = word, times = times }
    end
    table.sort(out, function(a: Counts.Entry, b: Counts.Entry): boolean
      if a.times ~= b.times then return a.times > b.times end
      return a.word < b.word
    end)
    return out
  end
end

--- Counts with no words in them yet.
function Counts.new(): Counts.Tally
  local made: Seen = { words = {} }
  return made
end

--- Counts the words in the file at `path`, or nil and why it could not be
--- read. A constructor that can fail returns `Counts.Tally?, string`.
function Counts.open(path: string): Counts.Tally?, string
  local text, why = Fs.read(path)
  if text == nil then
    return nil, why
  end
  local made: Seen = { words = {} }
  made:add(text)
  return made, ""
end

return Counts
```

`Counts.open` shows the usual shape of a constructor that can fail: it
returns `Counts.Tally?, string`, and the class value may be returned
straight from it.

A record declared inside another, like `Entry` here, is `Counts.Entry`
to every module; `record Counts.Entry` written outside the record's body
is refused. Another module names the types through the same `require`:
`local Counts = require("counts")` is the module, `Counts.Tally` the type
of a value `Counts.new()` makes, and `Counts.Entry` the nested one. A
module that only names the types, and calls nothing, writes `local
type Counts = require("counts")`.

```teal file=counts_test.tl
local Counts = require("counts")

local function test_top()
  local counts = Counts.new()
  counts:add("b a b")
  local top: {Counts.Entry} = counts:top()
  local first, second = assert(top[1]), assert(top[2])
  assert(first.word == "b" and first.times == 2)
  assert(second.word == "a" and second.times == 1)
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
local function input(got: Flags.Parsed): string?
  local text, trouble = Fs.read(got.words[1] or "/dev/stdin")
  if text == nil then
    log:complain(trouble)
  end
  return text
end

local function show(entry: Counts.Entry)
  print(entry.word .. "\t" .. tostring(entry.times))
end

local commands: {string:Flags.Command} = {
  words = {
    about = "Counts the words of a file, or of standard input.",
    usage = "[options] [file]",
    spec = { ["--lines"] = { about = "count lines instead" } },
    run = function(got: Flags.Parsed): integer
      local text = input(got)
      if text == nil then return 1 end
      if got.set["--lines"] == true then
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
cosmic build                              write the tally program
cosmic docs tally                         what your own module offers
```

`cosmic fix` rewrites each file in canonical layout, in place: run it
after editing. `cosmic test` builds the tree, then runs each test, and
skips one whose code and inputs have not changed since it last passed.
`cosmic cmd/tally/main.tl words words.txt` runs the program from source. `cosmic
build` writes `tally` in the project's build directory, outside the project
(`~/.cache/cosmic/trees/<key>/bin/tally`; `COSMIC_BUILD_HOME` moves it), and
prints its path on a line of its own; `cosmic build cmd/tally` writes only that one. `cosmic docs` lists your own modules with the standard library's, and
`cosmic docs Tally.words` shows a function with the examples that call it.

That `tally` is the whole program: copy that one file to a Linux (arm64
with Armv8.2-A dot-product and half-precision floats: Cortex-A55 or
Neoverse N1 and newer, Graviton2, Raspberry Pi 5, but not a Raspberry
Pi 3 or 4; or x86-64 with AVX2, FMA, BMI1 and BMI2, F16C, LZCNT and
MOVBE: Intel Haswell or AMD Excavator and newer mainstream cores, but
not Atom-class or AVX-less Pentium and Celeron parts) or arm64 macOS
host with no cosmic on it and it runs, even with an empty environment
(`env -i ./tally`). `file` calls it a shell script because it starts as
one: a /bin/sh launcher with a core for each supported system and the program
appended. On a host's first run the
launcher copies that host's core into a private cache
(`~/.cache/cosmic/cores`, `~/Library/Caches/cosmic/cores` on macOS, or
`/tmp/cosmic-cores-<uid>` with no `HOME`; `cosmic help build` lists the
rest) and runs it from there; the launcher then `exec`s the core, so the process
you start is the program's own and signals reach it directly. The file
is in the project's build directory, `$XDG_CACHE_HOME/cosmic/trees/<key>/bin/tally`
(`~/.cache/cosmic/trees/<key>/bin/tally`; `COSMIC_BUILD_HOME` moves the
`<key>` directories), and `cosmic build` prints its path. `cosmic build
--host` writes instead a native executable for this system alone, which
needs no shell and writes no cache: the choice for a container with no
/bin/sh, or a host with nowhere to write. It writes the same
`bin/tally`, replacing the launcher build.

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
local env: mut {string: string} = {}
for name, value in pairs(Env.all()) do env[name] = value end
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
-- The test summary where there is one, else how the verb exited.
local function outcome(said: Child.Result, verb: string)
  print((said.stdout or ""):match(verb .. ": %d+ tests? passed") or verb .. " exited " .. tostring(said.code))
end

outcome(cosmic("fix"), "fix")
outcome(cosmic("test"), "test")
print(((cosmic("cmd/tally/main.tl", "words", "words.txt").stdout or ""):gsub("\n$", "")))
print(((cosmic("cmd/tally/main.tl", "top", "words.txt", "--limit", "2").stdout or ""):gsub("\n$", "")))
local missing = cosmic("cmd/tally/main.tl", "words", "--nope")
print(missing.code, ((missing.stderr or ""):gsub("\n$", "")))
print(((cosmic("cmd/tally/main.tl", "--help").stdout or ""):gsub("\n$", "")))
local wrote = cosmic("build", "--host")
outcome(wrote, "build")
local program = assert(("\n" .. (wrote.stdout or "")):match("\n(/[^\n]+)"))
local built = assert(Child.run({ program, "words", "words.txt" },
  { cwd = tmp, stdout = "capture", timeout_ns = Clock.seconds(60) }))
print(((built.stdout or ""):gsub("\n$", "")))
outcome(cosmic_in(tmp .. "/cmd/tally", "test"), "test")
print((cosmic("docs", "tally").stdout or ""):match("^[^\n]*"))
```

```output
fix exited 0
test: 3 tests passed
5
the	2
cat	1
2	tally: words: no such option: --nope
usage: tally <command> [options]

commands:
  top    Lists the most frequent words.
  words  Counts the words of a file, or of standard input.

Run `tally <command> --help` for a command's options.
build exited 0
5
test: 3 tests passed
tally (tally.tl)
```

## discarding a failure on purpose

A call that answers `nil, why` or `false, why` must be handled: `cosmic
fix` reports a result whose failure is ignored. When the failure cannot
matter, discard both results on purpose with `local _, _ = call()`. The
usual case is a best-effort cleanup in a path that is already failing,
such as a `ROLLBACK` after a statement fails, where the first error is
the one to report.

```teal
local Sqlite = require("cosmic.sqlite")

local function add(db: Sqlite.Handle, body: string): boolean, string
  local began, trouble = db:exec("BEGIN")
  if not began then return false, trouble end
  local ok, why = Sqlite.run(db, "INSERT INTO t (body) VALUES (?1)", { { text = body } })
  if not ok then
    local _, _ = db:exec("ROLLBACK")
    return false, why
  end
  return db:exec("COMMIT")
end

local db = assert(Sqlite.memory())
assert(db:exec("CREATE TABLE t (body TEXT)"))
assert(add(db, "a"))
```

## moving a project to the new grammar

The tool reads one grammar, the new checker's. A project written for the fork's checker (`T | nil`, `goto continue`,
`function R:m()`, `c and a or b`) is refused by the compiler, which names the file, the line and the fix for each form it
finds, and `COSMIC_GRAMMAR=teal` and `cosmic compile --grammar teal` are refused too.

`cosmic migrate`, the verb that rewrote such a project in place, was removed. It still exists as a word that says so and
exits 2, so that a script that runs it is told what happened. A project in the old grammar is rewritten to the new one by
hand. Commit it first, then run `cosmic fix` and `cosmic test` and work through what they report; each finding says what
to write instead. What changed, and what the finding for it asks of the file:

- `T | nil` is `T?` (and `(A | B)?` for a union with nil; a function type in a union is parenthesized). `T...` as a
  parameter's type is `...: T`, and `? T` is a named optional parameter, `name?: T`.
- `goto continue` and its label `::continue::` are the statement `continue`.
- A record with `function R:m()` statements outside it, and the field that declared each, is a `class` that holds them as
  `function m(self, ...)`. The `metatable<R>` local that set its metatable goes, and a table literal of the class takes its
  type from where it is written.
- `local type X = record` is `local record X`; `metamethod __close: T` is the field `__close: T`; `readonly f: T` is `f: T`.
- `c and a or b` is `if c then a else b end`; `and_ternary` names the sites. The two answer differently where `a` is false or
  nil, which is why the checker asks for the `if` expression and does not rewrite it for you.
- `-a ^ b` was read as `(-a) ^ b` and is read as Lua reads it, `-(a ^ b)`: write the parentheses the program meant.
- A trailing `;`, a `--[[ ]]` comment, a digit separator (`1_000`) and a hexadecimal float are not in the grammar.
- A collection that is written is declared `mut` (`names: mut {string}`), as a local, a parameter or a field of a record;
  a field that is assigned after its record is made is declared `mut`. `view_written` and `field_fixed` name the places.
- `local seen = {}` needs a type that says what it holds (`local seen: mut {string: boolean} = {}`), and `m.NAME` on a map is
  written `m["NAME"]`.
- A type and an interface it lists agree on which fields are `mut` (`interface_disagrees`).

The checker holds a project outside the tree to every rule with no ceiling, so each finding must be fixed, not counted. No
cast and no `any` is a fix.

[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.flags`]: ../../cosmic/flags.tl
[`cosmic.log`]: ../../cosmic/log.tl
[`cosmic.template`]: ../../cosmic/template/init.tl
[`Flags.dispatch`]: ../../cosmic/flags.tl
