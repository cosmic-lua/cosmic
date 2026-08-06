# Testing

cosmic runs tests with `cosmic --test`, which executes a test file and captures stdout, stderr, and exit code. test files are `*_test.tl` scripts that define and immediately call test functions.

## Writing Tests

test files are named `*_test.tl` and placed alongside source files. they must start with a shebang line:

```teal
#!/usr/bin/env cosmic
local json = require("cosmic.json")

local function test_decode_object()
  local result = json.decode('{"a":1}') as {string: any}
  assert(type(result) == "table", "expected table")
  assert(result.a == 1, "expected a=1")
end
test_decode_object()

local function test_decode_error()
  local result, err = json.decode("{invalid}")
  assert(result == nil, "expected nil for invalid json")
  assert(err ~= nil, "expected error message")
end
test_decode_error()
```

key rules:
- shebang `#!/usr/bin/env cosmic` on line 1
- define a `local function test_*()` then call it on the next line
  (enforced by lint's `call-after-define` rule, so a failing run names
  the function)
- the `test_` prefix is reserved for tests: the linter treats ANY
  top-level `local function test_*()` in a `*_test.tl` as a test that
  must call itself. name helpers something else (`make_fixture`,
  `db_path_for`, ...)
- use `assert(condition, "message")` for assertions — there is no test framework
- each test function runs independently at file scope
- a test fails if any assert fails or the script exits nonzero

## Assert Patterns

the preferred way to write assertions is with `cosmic.check`, which produces auto-formatted failure messages:

```teal
local check = require("cosmic.check")

check.eq(result, "expected", "label") -- equality with diff on failure
check.ne(result, nil, "should not be nil")
check.ok(result > 0, "expected positive")
```

plain `assert()` also works and is fine for simple checks:

```teal
-- value equality
assert(result == "expected", "got: " .. tostring(result))

-- nil/non-nil checks
assert(result ~= nil, "should not be nil")
assert(result == nil, "should be nil")

-- type checks
assert(type(result) == "table", "expected table")
assert(type(err) == "string", "error should be a string")

-- boolean conditions
assert(result > 0, "expected positive")
assert(not failed, "should not fail")

-- string matching
assert(output:find("expected"), "output should contain 'expected'")
```

## Using TEST_TMPDIR

`cosmic --test` sets the `TEST_TMPDIR` environment variable to an isolated temp directory for each test. tests that create files should use it:

```teal
#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local env = require("cosmic.env")

local function test_write_file()
  local tmpdir = env.get("TEST_TMPDIR")
  assert(tmpdir, "TEST_TMPDIR must be set")
  local path = fs.join(tmpdir, "test.txt")
  local fs = require("cosmic.fs")
  local ok, err = fs.write(path, "hello")
  assert(ok, "write failed: " .. tostring(err))
  local data = fs.read(path)
  assert(data == "hello", "read back mismatch")
end
test_write_file()
```

`TEST_TMPDIR` is cleaned up automatically after each test FILE — the
functions within one file share it, in definition order. tests that
would collide on a shared path should each mint their own subdirectory
(`fs.temp_dir(fs.join(tmpdir, "case_XXXXXX"))`) rather than reuse one
well-known name.

## The Test Sandbox

`--make test` runs every test under a sandbox whose grants are
**derived, never declared**. the recipe vocabulary is closed, so the
verb's own signature says what it touches: `test <out> <cmd> [args...]`
grants write on `<out>` (the base name of `.got`/`.out`/`.err` and the
step's scratch directory), exec on the command, and read on positions
3..n — the test's compiled file plus the transitive import closure the
graph put there.

there is no per-rule grant to edit, and no way for a rule to
over-declare: a rule declares nothing.

what that means for a test author:

- **filesystem**: read what you import, write only under `o/` and
  `TEST_TMPDIR` (the verb points `TMP` inside its own scratch directory,
  so it needs no grant of its own). writes anywhere else fail.
- **loopback TCP works** — despite no `inet` promise in the pledge list. binding and connecting on `127.0.0.1` is fine; the precedent is `cosmic/net/connect_test.tl:247` (`net.listen_tcp("127.0.0.1", 0)`), which the whole `net`/`serve` test surface leans on. bind port 0 and use the assigned port; never hardcode ports.
- **DNS and egress do NOT work**. a lookup or outbound connect fails or the child is killed. only write such a call if the test expects the failure (e.g. asserting that a dial to a non-allowed host errors).
- **process control works**: fork/exec are granted (`proc exec`), so `cosmic.child` spawns are fine — but the child inherits the same sandbox.

### opting out

two escalation paths exist; prefer the tight default whenever the test can live with it:

- **namespace tests** (anything calling `unshare(2)` or writing `/proc/self/*_map` — the quicksand netns/proxy/box suites): no pledge promise covers unshare, so these run unfenced.
- **enforcement tests** (pledge/unveil/landlock primitives asserting that restriction *actually* blocks): under an outer sandbox their assertions degrade to visible skips. `COSMIC_ENFORCE=1` turns such a skip into a loud failure, for a privileged lane that reruns them unsandboxed. no lane sets it yet — `enforce` is a named, planned verb, and until it lands those skips are tolerated everywhere.

the fence itself is ON by default; `COSMIC_FENCE=0` opts out.

## Running Tests

`cosmic --test` runs a test file and captures its output. the command form is:

```bash
cosmic --test <output_prefix> <cosmic_binary> <test_file>
```

**end-to-end example.** given `foo_test.tl`:

```bash
# run the test, capturing output to o/foo.{out,err,got}
cosmic --test o/foo ./cosmic foo_test.tl
```

this produces three files:
- `o/foo.out` — the test's stdout
- `o/foo.err` — the test's stderr
- `o/foo.got` — the exit code (a single integer, e.g. `0` for pass, `1` for fail)

`--test` propagates the test's exit code, so it is safe in shell `&&`-chains:

```bash
cosmic --test o/foo ./cosmic foo_test.tl && echo "passed"
```

to see a passing summary:

```bash
cosmic --report o/foo.got
# foo_test.tl ... ok
```

when a test fails the `.out` and `.err` files contain the failure output:

```bash
# after a failing run:
cat o/foo.out
# assertion failed: expected 1, got 2

cosmic --report o/foo.got
# foo_test.tl ... FAIL
# 1 failed
```

`--report` accepts multiple `.got` files and aggregates results across a whole test suite:

```bash
cosmic --report o/*.tl.test.got
```

test targets are derived from `*_test.tl` files — nothing registers them:

```bash
o/bin/cosmic --make test                       # run all tests
o/bin/cosmic --make test cosmic/string_test.tl # narrow by path
```

run them under the binary your change builds (`--make build` first), or
the tests exercise the pinned release instead.

## Writing Examples

examples are `*_example.tl` files with `Example_*` functions. expected output is declared in `-- Output:` comment blocks:

```teal
--- Examples for cosmic.json module.

local function Example_decode()
  local json = require("cosmic.json")
  local result = json.decode('{"a":1}')
  print((json.encode(result)))
  -- Output:
  -- {"a":1}
end

local function Example_error()
  local json = require("cosmic.json")
  local result, err = json.decode("{invalid}")
  if err then
    print("error: " .. err)
  end
  -- Output:
  -- error: illegal character
end

return {}
```

run examples with:

```bash
cosmic --check example file.tl       # run examples in one file
```

## Benchmarks

benchmark functions use the `Benchmark_*` naming pattern:

```teal
local function Benchmark_encode()
  local json = require("cosmic.json")
  json.encode({a = 1, b = "hello"})
end
```

run with `cosmic --benchmark file.tl`.
