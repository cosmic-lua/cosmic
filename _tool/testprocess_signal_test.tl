local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local testprocess = require("_tool.testprocess")

local function run_fixture(name: string, script: string): testprocess.Result
  local dir = fs.join(os.getenv("TEST_TMPDIR"), name)
  assert(fs.make_dir(dir))
  local path = fs.join(dir, "child.lua")
  assert(fs.write(path, script))
  return testprocess.run({check.must(proc.interpreter()), path}, {
      temp_dir = dir, env = env.list(), timeout_ms = 2000,
    })
end

local function test_real_sigterm_retains_native_signal_and_exit_code()
  local result = run_fixture("sigterm", [[
local signal = require("cosmic.signal")
assert(signal.raise(signal.SIGTERM))
]])
  check.equal(result.signal, signal.SIGTERM)
  check.equal(result.exit_code, 128 + signal.SIGTERM)
  check.equal(result.timed_out, false)
  check.equal(result.start_error, "")
  check.equal(result.cleanup_error, "")
end

local function test_real_exit143_has_no_native_signal()
  local result = run_fixture("exit143", "os.exit(143)")
  check.equal(result.signal, nil)
  check.equal(result.exit_code, 143)
  check.equal(result.timed_out, false)
  check.equal(result.start_error, "")
  check.equal(result.cleanup_error, "")
end
