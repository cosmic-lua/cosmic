local check = require("cosmic.check")
local driver = require("_fuzz.driver")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local isolation = require("_fuzz.isolation")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local source = require("_fuzz.source")
local testprocess = require("_tool.testprocess")

local function result(): testprocess.Result
  return {
    exit_code = 0, stdout = "output", stderr = "", elapsed_ms = 1,
    timed_out = false, cleanup_error = "", start_error = "",
  }
end

local function test_clean_exit_passes()
  local outcome = isolation.classify(result())
  check.equal(outcome.kind, "pass")
  check.equal(outcome.stdout, "output")
  check.equal(outcome.checkpoint_bytes, "")
end

local function test_zero_exit_with_cleanup_error_is_infrastructure()
  local r = result()
  r.cleanup_error = "capture failed"
  local outcome = isolation.classify(r)
  check.equal(outcome.kind, "infrastructure")
  check.truthy(outcome.detail:find("capture failed", 1, true), "missing evidence")
end

local function test_start_error_preserves_all_error_and_timeout_evidence()
  local r = result()
  r.start_error, r.cleanup_error = "start failed", "close failed"
  r.timed_out, r.signal = true, signal.SIGKILL
  local outcome = isolation.classify(r)
  check.equal(outcome.kind, "infrastructure")
  for _, evidence in ipairs({"start failed", "close failed", "timed out", "signal=9"}) do
    check.truthy(outcome.detail:find(evidence, 1, true), outcome.detail)
  end
end

local function test_timeout_outranks_supervisor_sigkill()
  local r = result()
  r.timed_out, r.signal, r.exit_code = true, signal.SIGKILL, 137
  local outcome = isolation.classify(r)
  check.equal(outcome.kind, "timeout")
  check.equal(outcome.signal, signal.SIGKILL)
end

local function test_cleanup_error_outranks_timeout_and_signal()
  local r = result()
  r.timed_out, r.signal, r.cleanup_error = true, signal.SIGKILL, "reap failed"
  local outcome = isolation.classify(r)
  check.equal(outcome.kind, "infrastructure")
  check.truthy(outcome.detail:find("timed out", 1, true), "missing evidence")
  check.truthy(outcome.detail:find("reap failed", 1, true), "missing evidence")
end

local function test_native_sigterm_is_a_crash()
  local r = result()
  r.signal, r.exit_code = signal.SIGTERM, 143
  check.equal(isolation.classify(r).kind, "crash")
end

local function test_exit143_without_signal_is_an_ordinary_failure()
  local r = result()
  r.exit_code = 143
  local outcome = isolation.classify(r)
  check.equal(outcome.kind, "failure")
  check.equal(outcome.signal, nil)
  check.truthy(outcome.detail:find("child exited 143 without a diagnostic", 1, true), "missing evidence")
end

local function test_failure_preserves_nonempty_stderr()
  local r = result()
  r.exit_code, r.stderr = 1, "property failed\n"
  check.equal(isolation.classify(r).stderr, r.stderr)
end

local function request(argv: {string}): isolation.Request
  return {argv = argv, name = "probe", seed = 7, iters = 8,
    timeout_ms = 2000, diagnostic = false}
end

local function test_missing_interpreter_is_infrastructure()
  local outcome = isolation.run(request({fs.join(os.getenv("TEST_TMPDIR"), "missing")}))
  check.equal(outcome.kind, "infrastructure")
  check.equal(outcome.signal, nil)
  check.truthy(#outcome.detail > 0)
end

local function test_original_child_strips_diagnostic_environment()
  local path = fs.join(os.getenv("TEST_TMPDIR"), "environment.lua")
  assert(fs.write(path, [[
assert(os.getenv("FUZZ_DIAGNOSTIC_DIR") == nil)
assert(os.getenv("FUZZ_ISOLATE") == "probe")
assert(os.getenv("FUZZ_SEED") == "7")
assert(os.getenv("FUZZ_ITERS") == "8")
print("pinned")
]]))
  local saved = env.get("FUZZ_DIAGNOSTIC_DIR")
  assert(env.set("FUZZ_DIAGNOSTIC_DIR", "inherited"))
  local outcome = isolation.run(request({check.must(proc.interpreter()), path}))
  if saved then assert(env.set("FUZZ_DIAGNOSTIC_DIR", saved))
  else assert(env.unset("FUZZ_DIAGNOSTIC_DIR")) end
  check.equal(outcome.kind, "pass", outcome.detail .. outcome.stderr)
  check.equal(outcome.stdout, "pinned\n")
  check.equal(outcome.checkpoint_bytes, "")
end

local function test_directory_cleanup_failure_retains_observed_status()
  local remove_all = fs.remove_all
  local removed_dir = ""
  fs.remove_all = function(path: string): boolean, string
    removed_dir = path
    return false, "injected removal failure"
  end
  local script = fs.join(os.getenv("TEST_TMPDIR"), "clean_exit.lua")
  assert(fs.write(script, "os.exit(0)"))
  local outcome = isolation.run(request({check.must(proc.interpreter()), script}))
  fs.remove_all = remove_all
  assert(remove_all(removed_dir))
  check.equal(outcome.kind, "infrastructure")
  check.truthy(outcome.detail:find("injected removal failure", 1, true), "missing evidence")
  check.truthy(outcome.detail:find("exit_code=0", 1, true), "missing evidence")
end

local function report(r: testprocess.Result): boolean, string
  local run = isolation.run
  isolation.run = function(_request: isolation.Request): isolation.Outcome
    return isolation.classify(r)
  end
  local ok, msg = driver.run({name = "report", iters = 8, timeout_ms = 20,
      gen = function(_src: source.Recorder): string
        error("parent generator must not run")
      end,
      check = function(_input: string): boolean, string
        error("parent check must not run")
      end,
    })
  isolation.run = run
  return ok, msg
end

local function test_driver_reports_empty_stderr_failure()
  local r = result()
  r.exit_code = 143
  local ok, msg = report(r)
  check.equal(ok, false)
  check.truthy(msg:find("isolation failed: child exited 143 without a diagnostic", 1, true), "missing evidence")
  r.stderr = "ordinary failure\n"
  local _, ordinary = report(r)
  check.equal(ordinary, "ordinary failure")
end

local function test_driver_reports_only_observed_crash_and_timeout_context()
  local r = result()
  r.signal, r.exit_code = signal.SIGTERM, 143
  local ok, msg = report(r)
  check.equal(ok, false)
  check.truthy(msg:find("configured_iters=8: crashed: signal 15; original_input=unavailable", 1, true), "missing evidence")
  check.truthy(msg:find("diagnostic=inconclusive; reason=diagnostic-not-enabled", 1, true), "missing evidence")
  check.equal(msg:find("iteration=", 1, true), nil)
  check.equal(msg:find("input(base64)=", 1, true), nil)
  r.timed_out = true
  local _, timeout = report(r)
  check.truthy(timeout:find("configured_iters=8: hung: exceeded 20ms; input=unavailable", 1, true), "missing evidence")
end
