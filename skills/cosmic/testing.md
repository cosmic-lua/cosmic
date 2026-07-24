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
- use `assert(condition, "message")` for assertions — there is no test framework
- each test function runs independently at file scope
- a test fails if any assert fails or the script exits nonzero

## Assert Patterns

the preferred way to write assertions is with `cosmic.check`, which produces auto-formatted failure messages:

```teal
local check = require("cosmic.check")

check.eq(result, "expected", "label")      -- equality with diff on failure
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

`TEST_TMPDIR` is cleaned up automatically after each test.

## The Test Sandbox

`bin/make test` runs every test under a landlock-make sandbox. the default grants (the `$(o)/%.tl.test.got` pledge/unveil lines in the Makefile; the coverage lane is identical) are:

- `.PLEDGE = stdio rpath wpath cpath proc exec`
- `.UNVEIL = rx:o/bootstrap r:lib r:3p rwcx:o rwc:$TMP rx:/usr rx:/proc r:/etc r:/dev/null`

what that means for a test author:

- **filesystem**: read `lib/` and `3p/`, write only under `o/` and `TEST_TMPDIR`. writes anywhere else fail.
- **loopback TCP works** — despite no `inet` promise in the pledge list. binding and connecting on `127.0.0.1` is fine; the precedent is `lib/cosmic/net/connect_test.tl:247` (`net.listen_tcp("127.0.0.1", 0)`), which the whole `net`/`serve` test surface leans on. bind port 0 and use the assigned port; never hardcode ports.
- **DNS and egress do NOT work**. a lookup or outbound connect fails or the child is killed. only write such a call if the test expects the failure (e.g. asserting that a dial to a non-allowed host errors).
- **process control works**: fork/exec are granted (`proc exec`), so `cosmic.child` spawns are fine — but the child inherits the same sandbox.

### opting out

two escalation paths exist; prefer the tight default whenever the test can live with it:

- **namespace tests** (anything calling `unshare(2)` or writing `/proc/self/*_map` — the quicksand netns/proxy/box suites): no pledge promise covers unshare, so these tests are listed in `quicksand_sandbox_tests` in the Makefile, which sets empty `.PLEDGE`/`.UNVEIL` for exactly those `.got` targets. to add one, append its plain and `coverage/` target paths to that list.
- **enforcement tests** (pledge/unveil/landlock primitives asserting that restriction *actually* blocks): under the outer sandbox their assertions degrade to visible skips. the separate privileged `enforce` lane (`bin/make enforce`) reruns them unsandboxed with `COSMIC_ENFORCE=1`, where a skip becomes a loud failure, plus a tripwire that fails the lane if nothing enforced at all.

a per-rule override (custom `.PLEDGE`/`.UNVEIL` for one `.got` target) is possible but rare; reach for it only when a test needs one extra grant (say, an additional read path) and neither list above fits.

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

with `bin/make`, test targets are generated automatically from `*_test.tl` files:

```bash
bin/make test              # run all tests
bin/make test only=sqlite  # filter by pattern
```

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
cosmic --check-examples file.tl       # run examples in one file
cosmic --make . test                  # examples are included in test target
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
