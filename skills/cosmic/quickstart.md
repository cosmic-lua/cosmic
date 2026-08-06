# Quickstart: Your First Project

the smallest real cosmic project, end to end: one binary, one library
module, one test — built, run, tested and gated with four commands. the
pieces are each documented in depth elsewhere (`guide.make`,
`guide.testing`, `guide.checking`); this page assembles them once so
you do not have to.

## the layout

a project is a directory of conventionally named files. there is no
manifest, no build spec, nothing to register — position declares what
each file is:

```
myproj/
  cmd/greet/main.tl    a binary: cmd/<name>/main.tl builds to o/bin/<name>
  greet/text.tl        a library module: require("greet.text")
  greet/text_test.tl   its test: *_test.tl, discovered by --make test
```

a source's path relative to the project root IS its import path —
`greet/text.tl` is `require("greet.text")`. run every command below
from the project root (the `cosmic` binary itself is written here as
`cosmic`; use the path you have it at).

one caution before you start: keep the `cosmic` binary OUTSIDE the
project directory (or list it in a `.cosmicignore` file). the lint gate
reads every file the project walk sees, and a 10MB executable fails the
file-length rule in a confusing way.

## the library module

`greet/text.tl` — a module is a record describing its API, returned at
the bottom:

```teal
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

## the binary

`cmd/greet/main.tl` — guard `arg[1]` (it is `string | nil`), return an
`integer` from main (`os.exit` rejects `number`):

```teal
local text = require("greet.text")

local function main(): integer
  local name = arg[1]
  if not name then
    io.stderr:write("usage: greet <name>\n")
    return 1
  end
  print(text.greeting(name))
  return 0
end

os.exit(main())
```

## the test

`greet/text_test.tl` — shebang on line 1, `test_*` functions called
immediately after their definition (the `test_` prefix is reserved for
tests; name helpers something else):

```teal
#!/usr/bin/env cosmic
local text = require("greet.text")

local function test_greeting()
  local got = text.greeting("world")
  assert(got == "hello, world!", "got: " .. got)
end
test_greeting()
```

## build, run, test, gate

```bash
cosmic --make build
# compile o/greet/text.lua
# compile o/greet/text_test.lua
# compile o/cmd/greet/main.lua
# make: o/bin/greet
# build: PASS (3 files, 1 binary)

o/bin/greet world
# hello, world!

cosmic --make test
# test: PASS (1 file)

cosmic --make ci        # fmt, check, example, lint, coverage — the whole gate
# ci: PASS (4 stages)
```

(4 stages, not 5: the `example` stage reports "nothing to do" until the
project has a `*_example.tl` file.)

`o/bin/greet` is a standalone fat binary: copy it anywhere — another
directory, another machine, another OS — and it runs with no dependency
on the project tree or on `cosmic` itself.

the first `ci` run will note there is no coverage baseline; write one
and commit it to start the ratchet:

```bash
cosmic --make coverage --baseline    # writes .cosmic-coverage
```

## when something fails

- a TYPE error names the file, line and type; the recurring traps carry
  a `hint:` line, and `cosmic --docs guide.gotchas` walks the rest
- a FMT failure prints a have/want diff and the exact fix command:
  `cosmic --fix <file>`
- a LINT failure names its rule; `cosmic --docs guide.lint` documents
  every rule with its fix
- `--check types <file>` type-checks one file in isolation — the fast
  inner loop while a file is still taking shape
- know what each verb does NOT say: `--make build` and `--make test`
  run neither fmt nor lint, so a tree that builds and tests clean can
  still fail `ci` on formatting drift or an unjustified `as` cast.
  `--check fmt <file>` and `--check lint <file>` are those same gates
  per file — run them in the inner loop too, not first at `ci` time

## where to go next

- `cosmic --docs guide.make` — the full project model: more binaries
  (`cmd/<other>/main.tl`), embedded payload (`embed/`), pinned deps
  (`*_pin.tl`), what ships and what does not
- `cosmic --docs guide.modules` — the `cosmic.*` standard library
  (json, sqlite, fs, net, child, ...); `cosmic --docs <module>` for any
  one of them, with runnable examples
- `cosmic --docs guide.testing` — TEST_TMPDIR, the test sandbox,
  `check.eq`/`check.must` assertion helpers
- `cosmic --docs guide.recipes` — worked end-to-end programs (a CLI
  skeleton, sqlite indexing, TCP echo)
