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

the preferred way to write assertions is with `cosmic.assert`, which produces auto-formatted failure messages:

```teal
local a = require("cosmic.assert")

a.eq(result, "expected", "label")      -- equality with diff on failure
a.ne(result, nil, "should not be nil")
a.ok(result > 0, "expected positive")
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
