--- Test runner for cosmic executables.
--- Provides functions to run test executables and report on results.
local child = require("cosmic.child")
local cio = require("cosmic.io")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

--- Run a test executable and capture output.
--- Creates a temporary directory (TEST_TMPDIR) for the test and cleans up after.
--- @param argv {string} Command and arguments
--- @param output_base string Base path for output files
--- @return integer Exit code (for CLI return)
local function run(argv: {string}, output_base: string): integer
  if not output_base then
    io.stderr:write("testrun: missing output path\n")
    return 1
  end

  -- Create parent directories if needed
  local dir = fs.dirname(output_base)
  if dir ~= "." and dir ~= "/" then
    local ok, err = fs.makedirs(dir)
    if not ok then
      io.stderr:write("testrun: " .. err .. "\n")
      return 1
    end
  end

  -- Create temp directory for the test
  local tmpbase = env.get("TMP") or "/tmp"
  local tmpdir, tmpdir_err = fs.mkdtemp(fs.join(tmpbase, "testrun_XXXXXX"))
  if not tmpdir then
    io.stderr:write("testrun: " .. (tmpdir_err or "failed to create temp dir") .. "\n")
    return 1
  end

  -- Build environment with TEST_TMPDIR
  local child_env: {string} = {}
  for key, val in pairs(env.all()) do
    child_env[#child_env + 1] = key .. "=" .. val
  end
  child_env[#child_env + 1] = "TEST_TMPDIR=" .. tmpdir

  -- Spawn the process
  local handle, err = child.spawn(argv, {env = child_env})
  if not handle then
    fs.rmrf(tmpdir)
    io.stderr:write("testrun: " .. (err or "spawn failed") .. "\n")
    return 1
  end

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
    return 1
  end

  ok, err = cio.barf(output_base .. ".out", stdout_content)
  if not ok then
    io.stderr:write("testrun: " .. (err or "failed to write .out") .. "\n")
    return 1
  end

  ok, err = cio.barf(output_base .. ".err", stderr_content)
  if not ok then
    io.stderr:write("testrun: " .. (err or "failed to write .err") .. "\n")
    return 1
  end

  return exit_code
end

--- Test result for a single test.
local record TestResult
  name: string
  exit_code: integer
  stdout: string
  stderr: string
  status: string -- "pass", "fail", "skip"
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
        } as TestResult)
    else
      local exit_code = (tonumber(got_content:match("^(%d+)")) or -1) as integer

      -- Read stdout and stderr
      local stdout_content = cio.slurp(base .. ".out") or ""
      local stderr_content = cio.slurp(base .. ".err") or ""

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
        } as TestResult)
    end
  end

  -- Print results
  for _, result in ipairs(results) do
    local icon: string
    if result.status == "pass" then
      icon = "✓"
    elseif result.status == "skip" then
      icon = "→"
    else
      icon = "✗"
    end
    io.write(icon .. " " .. result.name .. "\n")
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
