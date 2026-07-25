# testrun

 Test runner for cosmic executables.
 Provides functions to run test executables and report on results.

## Types

### TestResult

 Test result for a single test.

```teal
local record TestResult
  name: string
  exit_code: integer
  stdout: string
  stderr: string
  status: string
  test_count: integer
end
```

### TestrunModule

```teal
local record TestrunModule
  run: function(argv: {string}, output_base: string): integer
  report: function(paths: {string}): integer
  status_of: function(exit_code: integer): string
  STATUS_ICONS: {string: string}
end
```

## Functions

### status_of

```teal
function status_of(exit_code: integer): string
```

 Classify the exit code recorded in a `.got` file.
 ONE definition of the contract (#779). The build has two reporters —
 this module covers the test/coverage/enforce lanes, lib/build/reporter
 covers teal/format/lint/example/benchmark — and cosmic.build's
 `--build verdict` grades whichever of them wrote a stage's summary. A
 silent disagreement about what exit 2 means would mis-grade `ci`, the
 same failure class as #714 one layer up, so both read it from here.

**Parameters:**

- `exit_code` (integer) - Exit code from the .got file

**Returns:**

- string - "pass" (0), "skip" (2), or "fail" (anything else)

### run

```teal
function run(argv: {string}, output_base: string): integer
```

 Run a test executable and capture output.
 Creates a temporary directory (TEST_TMPDIR) for the test and cleans up after.

**Parameters:**

- `argv` ({string}) - Command and arguments
- `output_base` (string) - Base path for output files

**Returns:**

- integer - Exit code (for CLI return)

### report

```teal
function report(paths: {string}): integer
```

 Report on test results from .got files.

**Parameters:**

- `paths` ({string}) - Paths to .got files or base paths

**Returns:**

- integer - Exit code (0 if all pass, 1 if any fail)

## Examples

### makefile

 Example showing a minimal Makefile-based test harness.
 Demonstrates pattern rules for running tests and collecting results.
 ```makefile
 # Pattern rule: for each test_*.lua, run it and capture output
 o/test/%.got: test_%.lua $(COSMIC)
 	$(COSMIC) --test $@ $< $<
 # Collect all test targets
 tests := $(patsubst test_%.lua,o/test/%.got,$(wildcard test_*.lua))
 # Run all tests and report
 test: $(tests)
 	$(COSMIC) --report $(tests)
 ```

```teal
  local testrun = require("cosmic.testrun")
  local tmpdir = fs.mkdtemp("/tmp/testrun_example_XXXXXX")
  if not tmpdir then return end

  -- Run /bin/true and capture output
  local exit_code = testrun.run({"/bin/true"}, fs.join(tmpdir, "test1"))
  print("exit_code:", exit_code)

  -- Report on the result
  testrun.report({fs.join(tmpdir, "test1")})

  fs.rmrf(tmpdir)
```

Output:
```
exit_code:	0
  -- ✓ test1
  --
  -- 1 checks: 1 passed

```
