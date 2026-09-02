# Write and run tests

steps for writing a `*_test.tl` file and running it under `cosmic --make test`, for
a reader who has a project that builds.

## write a test file

1. name the file `<name>_test.tl` and put it beside the source it tests.
2. put `#!/usr/bin/env cosmic` on line 1.
3. define one top-level `local function test_<case>()` per case. do not call it. the
   definition is the enrolment, and source order is the run order.
4. fail a case by throwing. `assert` and `cosmic.check` are the whole vocabulary.
   a case that returns has passed.

```teal file=decode_test.tl
#!/usr/bin/env cosmic
local json = require("cosmic.json")

local function test_decode_object()
  local result = json.decode('{"a":1}') as {string: any} -- cast: decode returns any
  assert(type(result) == "table", "expected table")
  assert(result.a == 1, "expected a=1")
end

local function test_decode_error()
  local result, err = json.decode("{invalid}")
  assert(result == nil, "expected nil for invalid json")
  assert(err ~= nil, "expected error message")
end
```

the `test_` prefix is reserved. the toolchain treats every top-level `local function
test_*` in a `*_test.tl` as a case. name helpers something else, for example
`make_fixture` or `db_path_for`.

pick one mode per file. a file where every `test_*` calls itself on the line after
its `end` is legacy mode and still runs. a file with no self-calls is runner mode. a
file that mixes the two fails `--check lint` with `call-after-define`, because its
uncalled half would never run. write new files in runner mode.

in runner mode every case runs even when an earlier one fails. the report names each
failed case and ends with a counts line, for example `3 checks: 2 passed, 1 failed`.

## assert

use `cosmic.check` for assertions that format their own failure message.
`cosmic --docs cosmic.check` has the signatures.

```teal
local check = require("cosmic.check")

local result = "expected"

check.equal(result, "expected", "label") -- equality with diff on failure
check.not_equal(result, nil, "should not be nil")
check.truthy(#result > 0, "expected non-empty")
```

plain `assert(condition, "message")` also works.

```teal
local result = "expected"
local err: string | nil = nil
local failed = false
local output = "an expected value"

assert(result == "expected", "got: " .. tostring(result))
assert(#result > 0, "expected non-empty")
assert(result ~= nil, "should not be nil")
assert(err == nil, "should be nil")
assert(type(result) == "string", "expected string")
assert(not failed, "should not fail")
assert(output:find("expected"), "output should contain 'expected'")
```

a test file passes the same lint gate as library code. an `as` cast needs a
`-- cast: <reason>` comment, and `require("cosmo")` is refused in a test.
`cosmic --docs reference.lint` lists the rules. to narrow a fallible return, prefer
`check.must`. it returns the value or throws, and needs no cast.

## use TEST_TMPDIR

the runner sets `TEST_TMPDIR` to a fresh directory for each test file and removes it
after the file. the cases in one file share it, in definition order. a test that
creates files writes there.

```teal file=tmpdir_test.tl
#!/usr/bin/env cosmic
local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local function test_write_file()
  local tmpdir = check.must(env.get("TEST_TMPDIR"), "TEST_TMPDIR must be set")
  local path = fs.join(tmpdir, "test.txt")
  local ok, err = fs.write(path, "hello")
  assert(ok, "write failed: " .. tostring(err))
  local data = fs.read(path)
  assert(data == "hello", "read back mismatch")
end
```

when two cases would collide on one path, give each its own subdirectory with
`fs.temp_dir(fs.join(tmpdir, "case_XXXXXX"))`.

## run the tests

`--make test` finds every `*_test.tl` in the project. nothing registers a test.

1. build first, so the tests run under the binary your change produces and not the
   pinned release.
2. run the whole suite, or narrow it to a file or a directory.

```bash
cosmic --make build
cosmic --make test                       # every test
cosmic --make test cosmic/string_test.tl # one file
cosmic --make test cosmic/fs             # one directory
```

a path that matches nothing is an error, not an empty pass. the run ends with a
verdict line, `test: PASS (N files)` or `test: FAIL (...)`, and the exit code says the
same.

to run only the cases whose names contain a substring, set `COSMIC_TEST_FILTER`. it is
a plain substring, not a pattern. a filter that matches nothing exits 2.

```bash
COSMIC_TEST_FILTER=decode cosmic --make test cosmic/json_test.tl
```

run a runner-mode file through `--make test`, never as a plain script. `cosmic
foo_test.tl` defines the cases and exits 0 without running one.

`--make test` runs neither `fmt` nor `lint`. `cosmic --make ci` runs every gate.

## spawn the built binary from a test

binaries build before tests run, and the sandbox grants exec. a test spawns its own
project's `o/bin/<name>` and asserts on the real stdout and exit code. `TEST_BIN` names
the directory (`o/bin`), and the runner puts it first on `PATH`.

```teal file=cli_test.tl
#!/usr/bin/env cosmic
local check = require("cosmic.check")
local child = require("cosmic.child")

local function test_cli_greets()
  local r = check.must(child.run({"o/bin/greet", "world"}))
  check.truthy(r.ok, "expected exit zero")
  check.equal(r.stdout, "hello, world!\n", "stdout")
end
```

for a server binary, have it print a readiness line such as `READY <port>`. read that
line from the child's stdout instead of sleeping. `cosmic --docs howto.spawn-child`
has the steps.

keep logic tests at the library layer, where a test calls the function directly. spawn
the binary only for the argv parsing and output formatting in `cmd/<name>/main.tl`.

## what the sandbox allows

`--make test` runs every test under a sandbox. the grants derive from the recipe's own
argv, so there is nothing to declare and nothing to edit.

- filesystem: read the project and the operating system. write only under `o/` and
  `TEST_TMPDIR`. a write anywhere else fails.
- loopback TCP works. bind `127.0.0.1` on port 0 and use the assigned port. never
  hardcode a port.
- DNS and outbound connections do not work. a lookup or an outbound connect fails, or
  the child is killed. write such a call only when the test expects the failure.
- fork and exec work, so `cosmic.child` spawns are fine. the child inherits the same
  sandbox.

## read the embedded payload from a test

with a root `embed/` directory, `--make test` runs every test under
`o/.testrun/cosmic`. that runner is this cosmic plus the payload at its artifact
paths, so `/zip/R` resolves inside a test exactly as inside the artifact.

a per-binary payload under `cmd/<name>/embed/**` is that artifact's private cargo. a
test does not see it. cover it by spawning `o/bin/<name>` as above.

## opt out of the sandbox

the sandbox is on by default. prefer it whenever the test can live with it.

- `COSMIC_FENCE=0` turns the sandbox off for the run.
- a test that calls `unshare(2)` or writes `/proc/self/*_map` runs unfenced, because no
  pledge promise covers unshare.
- a test that asserts a restriction blocks something degrades to a visible skip under
  an outer sandbox. `COSMIC_ENFORCE=1` turns that skip into a failure, for a privileged
  lane that reruns such tests unsandboxed.

## run one test by hand

`cosmic --test` is the low-level form `--make test` uses for each file. it runs a
command, captures its streams, and propagates the exit code.

1. compile the test. the compiler appends the runner tail to a runner-mode file.
2. run the compiled file under `--test` with an output prefix.
3. read the verdict with `--report`.

```bash
cosmic --compile foo_test.tl > o/foo_test.lua
cosmic --test o/foo cosmic o/foo_test.lua
cosmic --report o/foo.got
```

`--test` writes `o/foo.out` (stdout), `o/foo.err` (stderr), `o/foo.got` (the exit
code, one integer) and `o/foo.time` (the wall time). it exits with the test's own
code, so it is safe in a shell `&&` chain. `--report` accepts many `.got` files and
prints one summary with every failure's output.

```bash
cosmic --report o/*.test.got
```
