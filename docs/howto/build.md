# Build a project with `--make`

steps for laying out, building, shipping and gating a project with
`cosmic --make`, for a reader who has written a `.tl` file before.

`cosmic --docs reference.make` has every verb, marker and message.
`cosmic --docs explanation.build` says why the build works this way.

## Lay out a project

a project is a directory tree. a file's position and name say what it
is, so there is no build spec to write.

1. make a directory for the project and enter it.
2. write the entry as `cmd/<name>/main.tl`. the binary is named
   `<name>`. a `main.tl` at the root is refused.
3. put shared code in a package directory. `greet/text.tl` is
   `require("greet.text")`; `greet/init.tl` is `require("greet")`.
4. put a test beside the code it tests, named `*_test.tl`.

the tree for a project named `app`:

```text
app/
  cmd/app/main.tl        the entry; builds to o/bin/app
  greet/text.tl          require("greet.text")
  greet/text_test.tl     a test
```

`greet/text.tl` returns a record of functions:

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

`cmd/app/main.tl` imports it by its path:

```teal
local text = require("greet.text")

print(text.greeting("world"))
```

`greet/text_test.tl` defines a `test_*` function. defining it enrols
it; the runner calls every `test_*` function in order. `cosmic --docs
howto.test` has the rest.

```teal file=greet/text_test.tl
local text = require("greet.text")

local function test_greeting()
  assert(text.greeting("x") == "hello, x!")
end
```

## Build and run the artifact

1. run the build from the project root.

   ```bash
   cosmic --make build
   # build: PASS (3 files, 1 binary)
   ```

2. run the artifact. it is one file that runs on Linux, macOS,
   Windows, FreeBSD, OpenBSD and NetBSD.

   ```bash
   ./o/bin/app
   # hello, world!
   ```

every verb prints the root it used as its first line, in the form
`make: root=/home/you/app`. check that line when a build touches the
wrong tree.

## Add a second binary

1. add `cmd/<other>/main.tl`. every `cmd/<name>/` directory is one
   binary.
2. keep a binary's private modules under its own `cmd/<name>/`. a
   sibling `cmd/` may not import them.
3. put code two binaries share in a root package.
4. run `cosmic --make build`. both land in `o/bin/`.

```text
app/
  cmd/app/main.tl          o/bin/app
  cmd/tool/main.tl         o/bin/tool
  cmd/tool/helper.tl       require("cmd.tool.helper"), only from cmd/tool
  greet/text.tl            require("greet.text"), from either binary
```

to build one binary, name its directory:

```bash
cosmic --make build cmd/tool
```

## Ship a file in the artifact

an artifact carries its modules and `embed/**`, and nothing else. a
file that is only in the repo is not in the binary.

1. move the file under `embed/`. `embed/schema.sql` ships as
   `/zip/schema.sql`.
2. read it at that path from your code, with `cosmic.fs`.
3. rebuild.

a test sees the same path. `cosmic --make test` runs tests under a
runner that carries the root `embed/**`, so `/zip/schema.sql` reads in
a test as it does in the artifact.

to give one binary a private payload, put it under
`cmd/<name>/embed/**`. a test cannot see that payload. cover it by
spawning the built `o/bin/<name>`; `cosmic --docs howto.test` shows
how.

## Keep a file out of the artifact

nothing needs excluding from the artifact: `docs/`, a `Makefile`, a
`notes.md` and `testdata/` stay behind on their own.

to keep a file out of the project walk, so no verb reads it:

1. create `.cosmicignore` at the root.
2. write one glob per line. `#` starts a comment.
3. a pattern matches a whole relative path or a bare name. `build/`,
   `*.log` and `vendor` all read the way they behave.

```text
# .cosmicignore
build/
*.log
vendor
```

put test fixtures in a `testdata/` directory beside the test. a test
reads its own source directory, so fixtures need no grant, and
`testdata/` is never embedded.

## Add a pinned dependency

1. write a `*_pin.tl` file where the dependency belongs, as
   `3p/lpeg/lpeg_pin.tl`. it holds literals only: no variables, no
   calls, no concatenation.

   ```teal
   return {
     url = "https://example.test/lpeg-{version}.tar.gz",
     version = "1.0.2",
     sha256 = "9b0f0a...",
   }
   ```

2. give both `url` and `sha256`. a pin without a digest is refused.
3. add `format = "tar.gz"` or `format = "zip"`, and `strip_components`,
   to unpack the archive after the fetch.
4. run `cosmic --make fetch`. it is the only verb that opens a socket.

the bytes land under `o/`, beside the pin's position and named by the
url: `3p/lpeg/lpeg_pin.tl` fetches to `o/3p/lpeg/lpeg-1.0.2.tar.gz`.
an archive unpacks beside itself after the digest matches.

to bump the version, change the `version` line and run `fetch` again.
a `fetch` whose bytes are already present and hash correctly touches
no network.

## Narrow a verb to a path

1. name one or more paths after the verb. your shell expands globs.

   ```bash
   cosmic --make check greet/
   cosmic --make test greet/*_test.tl
   ```

2. name a source for `check`, `fmt`, `lint`, `test` and the other
   graph verbs.
3. name a binary directory for `build`. it refuses a source path.
4. name one script for `run`. it builds first, then runs the script
   against the built tree, with the arguments that follow it.

   ```bash
   cosmic --make run tools/report.tl --out o/report.json
   ```

`clean` and `ci` take no paths. a path that matches nothing fails with
`make: nothing to do under: <path>`.

## Run the whole gate

1. run `ci` from the root.

   ```bash
   cosmic --make ci
   ```

2. read the last line. it is `ci: PASS (N stages)` or
   `ci: FAIL (<stages>)`, and the exit code agrees.

`ci` runs `fmt`, `check`, `example`, `lint` and `coverage`. tests run
once, instrumented, inside `coverage`. a stage skips what its stamps
already proved, so a rerun after a one-file edit redoes only that file's
work. run the whole gate after each edit instead of remembering which
verb checks what.

read the verdict line, or set `set -o pipefail`, when a shell pipes
the output. `cosmic --make ci | tail` returns the status of `tail`.

## Write and commit the coverage floor

the floor is `.cosmic-coverage` at the root, one row per file. a
project with no floor has no ratchet.

1. run the tests with coverage and write the floor.

   ```bash
   cosmic --make coverage --baseline
   ```

2. read the diff. `--baseline` writes this run's exact measurement into
   every row, raises and drops alike.
3. commit `.cosmic-coverage`.
4. add `.cosmic-coverage merge=union` to `.gitattributes`. two branches
   that touch different files then merge without a conflict.

`--baseline` takes no paths. a rewrite that would lower more than half
the committed rows is refused; that shape comes from a partial or
stale run, not from a real decline.

after a merge that produced repeated rows, the ratchet reads the lower
percentage and says how many rows it resolved that way. the next
`--baseline` rewrites the file clean.

## Name the root explicitly

the root is the current directory. `--make` never searches upward.

1. run every verb from the project root, or
2. set `COSMIC_MAKE_ROOT` to the root's path, for a caller that cannot
   `cd`.

   ```bash
   COSMIC_MAKE_ROOT=/home/you/app cosmic --make check
   ```

a directory is a root when it holds `main.tl`, a `cmd/<name>/main.tl`,
or a `.cosmicignore`. to build a directory that declares none of them,
name it with `COSMIC_MAKE_ROOT`.

a run from inside a project fails and prints the root it found, the
command to run from there, and the `COSMIC_MAKE_ROOT` form.

## Set the engine or the job count

the graph verbs run on a make engine that cosmic carries and extracts to
`o/make`. `PATH` is never searched.

1. set `COSMIC_MAKE` to a path to use another make binary.

   ```bash
   COSMIC_MAKE=/usr/bin/gmake cosmic --make build
   ```

2. set `COSMIC_JOBS` to change the job count. the default follows the
   processor count.

   ```bash
   COSMIC_JOBS=2 cosmic --make test
   ```

## Clean the build directory

run `cosmic --make clean`. it removes `o/` and spares `o/bootstrap`,
so the next command reaches for no network.
