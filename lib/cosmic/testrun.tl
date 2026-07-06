--- Test runner for cosmic executables.
--- Provides functions to run test executables and report on results.
local child = require("cosmic.child")
local cio = require("cosmic.io")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local instrument = require("cosmic.instrument")

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
  for key, val in pairs(env.all()) do
    child_env[#child_env + 1] = key .. "=" .. val
  end
  child_env[#child_env + 1] = "TEST_TMPDIR=" .. tmpdir

  -- Spawn the process
  local handle0, err = child.spawn(argv, {env = child_env})
  if not handle0 then
    fs.rmrf(tmpdir)
    io.stderr:write("testrun: " .. (err or "spawn failed") .. "\n")
    instrument.finish(span, 1)
    return 1
  end
  local handle = handle0 as child.Handle

  -- Close stdin, read stdout and stderr
  if handle.stdin then
    handle.stdin:close()
  end

  local stdout_content = ""
  local stderr_content = ""

  if handle.stdout then
    stdout_content = handle.stdout:read() or ""
    handle.stdout:close()
  end

  if handle.stderr then
    stderr_content = handle.stderr:read() or ""
    handle.stderr:close()
  end

  -- Wait for exit
  local _, status = child.wait(handle.pid)
  local exit_code: integer = 1
  if child.WIFEXITED(status) then
    exit_code = child.WEXITSTATUS(status) as integer
  elseif child.WIFSIGNALED(status) then
    exit_code = (128 + child.WTERMSIG(status)) as integer
  end

  -- Clean up temp directory
  fs.rmrf(tmpdir)

  -- Write output files
  local ok: boolean
  ok, err = cio.barf(output_base .. ".got", tostring(exit_code) .. "\n")
  if not ok then
    io.stderr:write("testrun: " .. (err or "failed to write .got") .. "\n")
    instrument.finish(span, 1)
    return 1
  end

  ok, err = cio.barf(output_base .. ".out", stdout_content)
  if not ok then
    io.stderr:write("testrun: " .. (err or "failed to write .out") .. "\n")
    instrument.finish(span, 1)
    return 1
  end

  ok, err = cio.barf(output_base .. ".err", stderr_content)
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
      local src = cio.slurp(a)
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
    local tok, terr = cio.barf(output_base .. ".tests", table.concat(test_names, "\n") .. "\n")
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
    local got_content, err = cio.slurp(base .. ".got")
    if not got_content then
      io.stderr:write("testrun: cannot read " .. base .. ".got: " .. (err or "unknown error") .. "\n")
      failed = failed + 1
      table.insert(results, {
          name = name,
          exit_code = -1 as integer,
          stdout = "",
          stderr = "cannot read .got file",
          status = "fail",
          test_count = 0 as integer,
        } as TestResult)
    else
      local exit_code = (tonumber(string.match(got_content, "^(%d+)")) or -1) as integer

      -- Read stdout and stderr
      local stdout_content = cio.slurp(base .. ".out") or ""
      local stderr_content = cio.slurp(base .. ".err") or ""

      -- Read recorded test_* function names, when present
      local test_count = 0
      local tests_content = cio.slurp(base .. ".tests")
      if tests_content then
        for _ in string.gmatch(tests_content, "[^\n]+") do
          test_count = test_count + 1
        end
      end

      local status: string
      if exit_code == 0 then
        status = "pass"
        passed = passed + 1
      elseif exit_code == 2 then
        status = "skip"
        skipped = skipped + 1
      else
        status = "fail"
        failed = failed + 1
      end

      table.insert(results, {
          name = name,
          exit_code = exit_code,
          stdout = stdout_content,
          stderr = stderr_content,
          status = status,
          test_count = test_count as integer,
        } as TestResult)
    end
  end

  -- Print results
  local total_wall_ms = 0
  local slowest_name = ""
  local slowest_ms = 0

  for _, result in ipairs(results) do
    local icon: string
    if result.status == "pass" then
      icon = "✓"
    elseif result.status == "skip" then
      icon = "→"
    else
      icon = "✗"
    end
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
  local fs = require("cosmic.fs")
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
end

local M: TestrunModule = {
  run = run,
  report = report,
}

return M
