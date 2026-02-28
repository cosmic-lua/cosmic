# Testing

cosmic tests are `*_test.tl` files that run as standalone scripts. each test function is defined and then immediately called — this is the "function-followed-by-call" pattern.

## Writing Tests

test files live alongside source in `lib/cosmic/` and are named `*_test.tl`. they must start with a shebang line:

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
- each test gets an isolated `TEST_TMPDIR` environment variable

## Assert Patterns

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

tests that create files should use the provided temp directory:

```teal
#!/usr/bin/env cosmic
local fs = require("cosmic.fs")

global TEST_TMPDIR: string

local function test_write_file()
  local path = fs.join(TEST_TMPDIR, "test.txt")
  local cio = require("cosmic.io")
  local ok, err = cio.barf(path, "hello")
  assert(ok, "write failed: " .. tostring(err))
  local data = cio.slurp(path)
  assert(data == "hello", "read back mismatch")
end
test_write_file()
```

`TEST_TMPDIR` is cleaned up automatically after each test.

## Running Tests

```bash
cosmic --make . test          # generate Makefile and run tests
make test                     # if you have a saved Makefile
```

### Makefile Rules for Testing

`cosmic --make` generates these test rules (see `cosmic --skill make` for the full Makefile):

```makefile
test_results := $(patsubst %.tl,$(BUILD_DIR)/%.tl.test.got,$(tests))

## Run tests and report results
test: $(test_results)
	$(COSMIC) --report $(test_results)

$(BUILD_DIR)/%.tl.test.got: %.tl
	@mkdir -p $(@D)
	$(COSMIC) --test $(BUILD_DIR)/$<.test $(COSMIC) $<
```

each test file is run with `cosmic --test`, which captures stdout/stderr/exit-code to `.out`/`.err`/`.got` files. `cosmic --report` aggregates results and reports pass/fail.

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
bin/make example                      # run all examples
cosmic --check-examples file.tl       # run examples in one file
```

## Benchmarks

benchmark functions use the `Benchmark_*` naming pattern:

```teal
local function Benchmark_encode()
  local json = require("cosmic.json")
  json.encode({a = 1, b = "hello"})
end
```

run with `cosmic --benchmark file.tl` or `bin/make benchmark`.
