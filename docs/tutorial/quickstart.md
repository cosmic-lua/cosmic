# your first project

build the smallest real cosmic project from nothing: one binary, one
library module, one test. at the end you have a fat binary that runs on
any supported OS, and a gate that passes. the whole page takes about
ten minutes.

you need the `cosmic` binary on your `PATH`. the commands below call it
as `cosmic`; use the path you have it at.

## 1. make an empty directory

keep the `cosmic` binary outside the project directory. the lint gate
reads every file in the project, and a 10 MB executable fails the
file-length rule.

```bash
mkdir greet-project
cd greet-project
```

the project you build has this layout. do not create the files yet;
the next steps do.

```text
greet-project/
  cmd/greet/main.tl    the binary: cmd/<name>/main.tl builds to o/bin/<name>
  greet/text.tl        a library module: require("greet.text")
  greet/text_test.tl   its test: *_test.tl, found by --make test
```

there is no manifest and no build file. a file's position declares
what it is. a source's path relative to the project root is its import
path, so `greet/text.tl` is `require("greet.text")`.

## 2. write the library module

create `greet/text.tl`. a module is a record that describes its API,
returned at the bottom of the file:

```teal file=greet/text.tl
local record TextModule
  greeting: function(name: string): string
end

local function greeting(name: string): string
  return "hello, " .. name .. "!"
end

local M: TextModule = {
  greeting = greeting,
}

return M
```

## 3. write the binary

create `cmd/greet/main.tl`. hand your main function to `cosmic.main`.
it passes the arguments in, writes your error return to stderr, and
exits with your code:

```teal file=cmd/greet/main.tl
local cosmic = require("cosmic")
local text = require("greet.text")

cosmic.main(function(args: {string}, env: cosmic.Env): number, string
    local name = args[1]
    if not name then
      env.stderr:write("usage: greet <name>\n")
      return 1
    end
    print(text.greeting(name))
    return 0
  end)
```

## 4. write the test

create `greet/text_test.tl`. a test is a top-level `local function`
whose name starts with `test_`. the runner finds every such function
and calls each one in order. do not call it yourself. the `test_`
prefix is reserved for tests, so name a helper something else:

```teal file=greet/text_test.tl
#!/usr/bin/env cosmic
local text = require("greet.text")

local function test_greeting()
  local got = text.greeting("world")
  assert(got == "hello, world!", "got: " .. got)
end
```

## 5. build it

run the build from the project root:

```bash
cosmic --make build
# compile o/greet/text.lua
# compile o/cmd/greet/main.lua
# make: o/bin/greet
# build: PASS (3 files, 1 binary)
```

the build type-checks every file, compiles it, and embeds the result
into `o/bin/greet`.

## 6. run it

```bash
o/bin/greet world
# hello, world!
```

`o/bin/greet` is a standalone fat binary. copy it to another directory,
another machine, or another OS, and it runs. it does not need the
project tree or the `cosmic` binary.

## 7. test it

```bash
cosmic --make test
# test: PASS (1 file)
```

## 8. run the whole gate

`ci` runs every check in order: formatting, types, examples, lint, and
tests with coverage.

```bash
cosmic --make ci
# ci: PASS (4 stages)
```

it reports 4 stages, not 5. the `example` stage has nothing to do
until the project has a `*_example.tl` file.

the first run says there is no coverage baseline. write one and commit
it, and every later run refuses a drop below it:

```bash
cosmic --make coverage --baseline
```

review the `.cosmic-coverage` diff like any other change before you
commit it.

## when a step fails

- a type error names the file, the line, and the types. the common
  traps carry a `hint:` line, and `cosmic --docs howto.type-errors`
  walks the rest.
- a formatting failure prints a have/want diff and the fix command,
  `cosmic --fix <file>`.
- a lint failure names its rule. `cosmic --docs reference.lint` has
  every rule and its fix.
- `--make build` and `--make test` run neither the formatter nor the
  linter. a tree that builds clean can still fail `ci`. run `ci` after
  each edit instead: every stage skips work it has already proved, so a
  warm rerun in a small project takes about a second.

## what you learned

- position declares what a file is: `cmd/<name>/main.tl` is a binary,
  `*_test.tl` is a test, and a path is an import path.
- a module is a record returned at the bottom of its file.
- `cosmic.main` owns the exit code and the error output.
- a test is any top-level `test_*` function; defining it enrols it.
- `--make ci` is the one command that says the project is good.

## next

- `cosmic --docs tutorial.cli-tool` builds a real command-line tool
  with flags, JSON input, and SQLite storage.
- `cosmic --docs howto.build` covers more binaries, embedded files,
  and pinned dependencies.
- `cosmic --docs howto.test` covers `TEST_TMPDIR`, the test sandbox,
  and the `cosmic.check` assertions.
