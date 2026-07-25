--- Test runner for cosmic executables.
--- Provides functions to run test executables and report on results.
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local instrument = require("cosmic._cli.instrument")

--- Display icons for a `.got` status.
local STATUS_ICONS: {string: string} = {
  pass = "✓",
  fail = "✗",
  skip = "→",
  ignore = "○",
}

--- Classify the exit code recorded in a `.got` file.
---
--- ONE definition of the contract (#779). The build has two reporters —
--- this module covers the test/coverage/enforce lanes, _build/reporter
--- covers teal/format/lint/example/benchmark — and cosmic._build's
--- `--build verdict` grades whichever of them wrote a stage's summary. A
--- silent disagreement about what exit 2 means would mis-grade `ci`, the
--- same failure class as #714 one layer up, so both read it from here.
--- @param exit_code integer Exit code from the .got file
--- @return string "pass" (0), "skip" (2), or "fail" (anything else)
local function status_of(exit_code: integer): string
  if exit_code == 0 then
    return "pass"
  elseif exit_code == 2 then
    return "skip"
  end
  return "fail"
end

--- Run a test executable and capture output.
--- Creates a temporary directory (TEST_TMPDIR) for the test and cleans up after.
--- @param argv {string} Command and arguments
--- @param output_base string Base path for output files
--- @return integer Exit code (for CLI return)
local function run(argv: {string}, output_base: string): integer
  -- determine file for instrumentation from argv
  local inst_file = argv[#argv] or output_base
  local span = instrument.begin("test", inst_file)

  if not output_base then
    io.stderr:write("testrun: missing output path\n")
    instrument.finish(span, 1)
    return 1
  end

  -- Create parent directories if needed
  local dir = fs.dirname(output_base)
  if dir ~= "." and dir ~= "/" then
    local ok, err = fs.makedirs(dir)
    if not ok then
      io.stderr:write("testrun: " .. err .. "\n")
      instrument.finish(span, 1)
      return 1
    end
  end

  -- Create temp directory for the test
  local tmpbase = env.get("TMP") or "/tmp"
  local tmpdir, tmpdir_err = fs.mkdtemp(fs.join(tmpbase, "testrun_XXXXXX"))
  if not tmpdir then
    io.stderr:write("testrun: " .. (tmpdir_err or "failed to create temp dir") .. "\n")
    instrument.finish(span, 1)
    return 1
  end

  -- Build environment with TEST_TMPDIR
  local child_env: {string} = {}
  local cov_requested = false
  for key, val in pairs(env.all()) do
    if key == "COSMIC_COVERAGE" then
      cov_requested = val ~= "" and val ~= "0"
    else
      child_env[#child_env + 1] = key .. "=" .. val
    end
  end
  child_env[#child_env + 1] = "TEST_TMPDIR=" .. tmpdir
  if cov_requested then
    -- Per-test coverage directory: replaces the inherited value so the
    -- test process (and any cosmic children it spawns) dumps its .cov
    -- files here, isolated from parallel sibling tests.
    local covdir = output_base .. ".cov.d"
    fs.rmrf(covdir)
    child_env[#child_env + 1] = "COSMIC_COVERAGE=" .. covdir
  end

  -- Run the process to completion, capturing both streams without deadlock.
  local result, err = child.run(argv, {env = child_env})
  local stdout_content = ""
  local stderr_content = ""
  local exit_code: integer = 1
  if not result then
    -- The executable could not be started (e.g. a missing binary): report the
    -- conventional 127 "command not found" code and surface the error.
    exit_code = 127
    stderr_content = err or "spawn failed"
  else
    local r = result as child.Result -- cast: record union after guard
    stdout_content = r.stdout
    stderr_content = r.stderr
    -- Signal death is reported as the conventional 128+signal exit code.
    if r.code ~= nil then
      exit_code = r.code
    elseif r.signal ~= nil then
      exit_code = (128 + r.signal) as integer -- cast: number to integer
    end
  end

  -- Clean up temp directory
  fs.rmrf(tmpdir)

  -- Write output files
  local ok: boolean
  ok, err = fs.write(output_base .. ".got", tostring(exit_code) .. "\n")
  if not ok then
    io.stderr:write("testrun: " .. (err or "failed to write .got") .. "\n")
    instrument.finish(span, 1)
    return 1
  end

  ok, err = fs.write(output_base .. ".out", stdout_content)
  if not ok then
    io.stderr:write("testrun: " .. (err or "failed to write .out") .. "\n")
    instrument.finish(span, 1)
    return 1
  end

  ok, err = fs.write(output_base .. ".err", stderr_content)
  if not ok then
    io.stderr:write("testrun: " .. (err or "failed to write .err") .. "\n")
    instrument.finish(span, 1)
    return 1
  end

  -- Best-effort: record the test_* functions defined in the test file so
  -- report() can show how many a passing file contains (files follow the
  -- define-then-call-immediately convention enforced by --check-style).
  local test_names: {string} = {}
  for _, a in ipairs(argv) do
    if a:match("_test%.tl$") then
      local src = fs.read(a)
      if src then
        for line in string.gmatch(src, "[^\n]+") do
          local tname = line:match("^local function (test_[%w_]+)")
          if tname then
            test_names[#test_names + 1] = tname
          end
        end
      end
    end
  end
  if #test_names > 0 then
    local tok, terr = fs.write(output_base .. ".tests", table.concat(test_names, "\n") .. "\n")
    if not tok then
      io.stderr:write("testrun: " .. (terr or "failed to write .tests") .. "\n")
    end
  end

  instrument.finish(span, exit_code)
  return exit_code
end

--- Test result for a single test.
local record TestResult
  name: string
  exit_code: integer
  stdout: string
  stderr: string
  status: string -- "pass", "fail", "skip"
  test_count: integer -- test_* functions in the file (0 when unknown)
end

--- Normalize a path to a .got file base path.
--- @param path string A .got file path or base path
--- @return string The base path (without .got extension)
local function normalize_path(path: string): string
  if path:match("%.got$") then
    return path:sub(1, -5) -- Remove .got
  end
  return path
end

--- Report on test results from .got files.
--- @param paths {string} Paths to .got files or base paths
--- @return integer Exit code (0 if all pass, 1 if any fail)
local function report(paths: {string}): integer
  local results: {TestResult} = {}
  local passed = 0
  local failed = 0
  local skipped = 0

  for _, path in ipairs(paths) do
    local base = normalize_path(path)
    local name = fs.basename(base)

    -- Read exit code from .got file
    local got_content, err = fs.read(base .. ".got")
    if not got_content then
      io.stderr:write("testrun: cannot read " .. base .. ".got: " .. (err or "unknown error") .. "\n")
      failed = failed + 1
      table.insert(results, {
          name = name,
          exit_code = -1,
          stdout = "",
          stderr = "cannot read .got file",
          status = "fail",
          test_count = 0,
        })
    else
      -- cast: number to integer
      local exit_code = (tonumber(string.match(got_content, "^(%d+)")) or -1) as integer

      -- Read stdout and stderr
      local stdout_content = fs.read(base .. ".out") or ""
      local stderr_content = fs.read(base .. ".err") or ""

      -- Read recorded test_* function names, when present
      local test_count = 0
      local tests_content = fs.read(base .. ".tests")
      if tests_content then
        for _ in string.gmatch(tests_content, "[^\n]+") do
          test_count = test_count + 1
        end
      end

      local status = status_of(exit_code)
      if status == "pass" then
        passed = passed + 1
      elseif status == "skip" then
        skipped = skipped + 1
      else
        failed = failed + 1
      end

      table.insert(results, {
          name = name,
          exit_code = exit_code,
          stdout = stdout_content,
          stderr = stderr_content,
          status = status,
          test_count = test_count,
        })
    end
  end

  -- Print results
  local total_wall_ms = 0
  local slowest_name = ""
  local slowest_ms = 0

  for _, result in ipairs(results) do
    local icon = STATUS_ICONS[result.status] or STATUS_ICONS.fail
    -- extract timing from stderr instrumentation lines
    local timing = ""
    if result.stderr ~= "" then
      local data = instrument.parse_lines(result.stderr)
      if #data > 0 then
        local d = data[#data]
        timing = string.format("  %dms", d.wall_ms)
        total_wall_ms = total_wall_ms + d.wall_ms
        if d.wall_ms > slowest_ms then
          slowest_ms = d.wall_ms
          slowest_name = result.name
        end
      end
    end
    local count_note = ""
    if result.status == "pass" and result.test_count > 0 then
      count_note = string.format(" (%d test functions)", result.test_count)
    end
    io.write(icon .. " " .. result.name .. count_note .. timing .. "\n")
  end

  -- Print summary
  local total = passed + failed + skipped
  io.write("\n" .. total .. " checks: " .. passed .. " passed")
  if failed > 0 then
    io.write(", " .. failed .. " failed")
  end
  if skipped > 0 then
    io.write(", " .. skipped .. " skipped")
  end
  if total_wall_ms > 0 then
    io.write(string.format(
        "\nwall: %dms  slowest: %s (%dms)",
        total_wall_ms, slowest_name, slowest_ms))
  end
  io.write("\n")

  -- Print failure details
  if failed > 0 then
    io.write("\nFailures:\n")
    for _, result in ipairs(results) do
      if result.status == "fail" then
        io.write("\n" .. result.name .. " (exit " .. result.exit_code .. "):\n")
        if result.stderr ~= "" then
          io.write("  stderr:\n")
          for line in result.stderr:gmatch("[^\n]+") do
            io.write("    " .. line .. "\n")
          end
        end
        if result.stdout ~= "" then
          io.write("  stdout:\n")
          for line in result.stdout:gmatch("[^\n]+") do
            io.write("    " .. line .. "\n")
          end
        end
      end
    end
  end

  return failed > 0 and 1 or 0
end

--- Example showing a minimal Makefile-based test harness.
--- Demonstrates pattern rules for running tests and collecting results.
---
--- ```makefile
--- # Pattern rule: for each test_*.lua, run it and capture output
--- o/test/%.got: test_%.lua $(COSMIC)
--- 	$(COSMIC) --test $@ $< $<
---
--- # Collect all test targets
--- tests := $(patsubst test_%.lua,o/test/%.got,$(wildcard test_*.lua))
---
--- # Run all tests and report
--- test: $(tests)
--- 	$(COSMIC) --report $(tests)
--- ```
local function Example_makefile()
  local testrun = require("cosmic.testrun")
  local tmpdir = fs.mkdtemp("/tmp/testrun_example_XXXXXX")
  if not tmpdir then return end

  -- Run /bin/true and capture output
  local exit_code = testrun.run({"/bin/true"}, fs.join(tmpdir, "test1"))
  print("exit_code:", exit_code)

  -- Report on the result
  testrun.report({fs.join(tmpdir, "test1")})

  fs.rmrf(tmpdir)
  -- Output:
  -- exit_code:	0
  -- ✓ test1
  --
  -- 1 checks: 1 passed
end

-- Suppress unused warning
local _ = Example_makefile

local record TestrunModule
  run: function(argv: {string}, output_base: string): integer
  report: function(paths: {string}): integer
  status_of: function(exit_code: integer): string
  STATUS_ICONS: {string: string}
end

local M: TestrunModule = {
  run = run,
  report = report,
  status_of = status_of,
  STATUS_ICONS = STATUS_ICONS,
}

return M
