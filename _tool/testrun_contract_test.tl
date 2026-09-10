#!/usr/bin/env cosmic
--- Hermetic contract tests for bounded execution and capability policy.

local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local records = require("_tool.records")
local time = require("cosmic.time")
local testprocess = require("_tool.testprocess")
local testplan = require("_tool.testplan")
local testrun = require("_tool.testrun")
local tresult = require("_tool.testrun_result")

local tmpdir = os.getenv("TEST_TMPDIR")
local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")

local function decoded(base: string): tresult.Result
  return check.must(tresult.decode(check.must(fs.read(base .. ".result"))))
end

local function capability_source(name: string): string
  local path = fs.join(tmpdir, name .. "_test.tl")
  assert(fs.write(path, "--- requires: loopback-listen\n"))
  return path
end

-- The deadline owns the direct child and its process group. A TERM-ignoring
-- shell and its TERM-ignoring descendant must both be gone when run returns.
local function test_timeout_escalates_and_reaps()
  local script = fs.join(tmpdir, "hang.lua")
  assert(fs.write(script, [[
local child = require("cosmic.child")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local time = require("cosmic.time")
assert(signal.sigaction(signal.SIGTERM, signal.SIG_IGN))
local sleeper = assert(child.start({"sleep", "60"}, {
  stdout = "inherit", stderr = "inherit",
}))
print("parent " .. proc.getpid() .. " descendant " .. sleeper.pid)
io.flush()
while true do time.sleep_ms(1000) end
]]))
  local base = fs.join(tmpdir, "timeout_cleanup")
  assert(fs.make_dirs(base))
  local started = time.monotonic_ms()
  local result = testprocess.run({cosmic, script}, {
      env = env.list(), temp_dir = base, timeout_ms = 1000,
    })
  local elapsed = time.monotonic_ms() - started
  assert(result.timed_out, "process did not time out")
  assert(elapsed < 3000, "timeout was not bounded: " .. tostring(elapsed) .. "ms")
  assert(result.cleanup_error == "",
    "timeout cleanup reported an error: " .. result.cleanup_error)
  local parent = result.stdout:match("parent (%d+)")
  local descendant = result.stdout:match("descendant (%d+)")
  parent = check.must(parent, "missing parent in: " .. result.stdout)
  descendant = check.must(descendant, "missing descendant in: " .. result.stdout)
  local ppid = check.must(math.tointeger(check.must(tonumber(parent))))
  local dpid = check.must(math.tointeger(check.must(tonumber(descendant))))
  assert(proc.getpgid(ppid) == nil, "timed-out parent survived")
  assert(proc.getpgid(dpid) == nil, "timed-out descendant survived")
end

-- A descendant may inherit stdout/stderr after the test file itself exits.
-- File-backed capture lets the runner return without waiting for pipe EOF.
local function test_descendant_held_output_does_not_block()
  local script = fs.join(tmpdir, "descendant.sh")
  assert(fs.write(script, "#!/bin/sh\nsleep 2 &\necho parent-exit\n",
      {mode = tonumber("755", 8)}))
  local base = fs.join(tmpdir, "descendant-capture")
  assert(fs.make_dirs(base))
  local started = time.monotonic_ms()
  local result = testprocess.run({script}, {
      env = env.list(), temp_dir = base, timeout_ms = 1000,
    })
  local elapsed = time.monotonic_ms() - started
  assert(not result.timed_out and result.exit_code == 0,
    "direct child should finish normally")
  assert(elapsed < 1000, "descendant-held output blocked for " .. elapsed .. "ms")
  assert(result.stdout:find("parent%-exit"), "parent output was not captured")
end

-- A hostile test can replace its predictable capture pathname with a FIFO.
-- Finalization reads the already-open regular inode and must still record the
-- typed timeout result within the supervisor's bounded cleanup window.
local function test_capture_path_replacement_cannot_block_result()
  local base = fs.join(tmpdir, "fifo_capture_result.test")
  local command = [[rm "$TEST_TMPDIR/capture.out"
mkfifo "$TEST_TMPDIR/capture.out"
echo marker >&2
sleep 60]]
  local started = time.monotonic_ms()
  local code, err = testrun.run({"/bin/sh", "-c", command}, base, {
      timeout_ms = 100, profile = "local",
    })
  local elapsed = time.monotonic_ms() - started
  assert(code == 124 and err == nil, "FIFO replacement must remain a timeout")
  assert(elapsed < 2000, "FIFO capture blocked for " .. tostring(elapsed) .. "ms")
  assert(fs.is_file(base .. ".result"), "timeout result sidecar was not recorded")
  local result = decoded(base)
  assert(result.status == "timeout" and result.fatal, "wrong FIFO timeout result")
  assert(check.must(fs.read(base .. ".err")):find("marker", 1, true),
    "stderr from the retained capture inode was lost")
end

-- Timeout diagnostics retain only the useful tail of large captured output.
local function test_timeout_report_captures_tail()
  local script = fs.join(tmpdir, "large_output.lua")
  assert(fs.write(script, [[
io.write(string.rep("A", 20000))
io.write("TAIL-MARK\n")
io.flush()
require("cosmic.time").sleep_ms(60000)
]]))
  local base = fs.join(tmpdir, "timeout_tail")
  assert(testrun.run({cosmic, script}, base,
      {timeout_ms = 40, profile = "local"}) == 124)
  local chunks: {string} = {}
  local old_write = io.write
  io.write = function(...: any): FILE, string, integer
    for _, value in ipairs({...}) do chunks[#chunks + 1] = tostring(value) end
    return io.stdout
  end
  local code = testrun.report({base})
  io.write = old_write
  local report = table.concat(chunks)
  assert(code == 1, "timeout must fail its report")
  assert(report:find("TAIL%-MARK") ~= nil, "captured tail missing")
  assert(#report < 19000, "report streamed more than the bounded tail")
end

-- A declared, independently-probed absence prevents execution and remains a
-- distinct UNAVAILABLE result on a local host.
local function test_declared_capability_absence_is_unavailable()
  local marker = fs.join(tmpdir, "must-not-run")
  local script = fs.join(tmpdir, "would_run.sh")
  assert(fs.write(script, "#!/bin/sh\necho ran > " .. marker .. "\n",
      {mode = tonumber("755", 8)}))
  local base = fs.join(tmpdir, "unavailable.tl.test")
  local code = testrun.run({script}, base, {
      timeout_ms = 1000, profile = "local",
      source_path = capability_source("unavailable"),
      capabilities = {["loopback-listen"] = {
          available = false, detail = "injected absence",
        }},
    })
  local result = decoded(base)
  assert(code == 2 and result.status == "unavailable" and not result.fatal,
    "local absence must be unavailable")
  assert(not fs.is_present(marker), "unavailable test process was spawned")
end

-- An ordinary test failure remains a product failure even when it declared a
-- capability; arbitrary stderr is never matched into UNAVAILABLE.
local function test_assertion_failure_is_product_failure()
  local base = fs.join(tmpdir, "ordinary_failure.tl.test")
  local code = testrun.run({cosmic, "-e", "error('ordinary assertion')"}, base, {
      timeout_ms = 1000, profile = "local",
      source_path = capability_source("ordinary_failure"),
      capabilities = {["loopback-listen"] = {available = true, detail = ""}},
    })
  local result = decoded(base)
  assert(code ~= 0 and result.status == "fail", "ordinary failure classification")
  assert(result.status ~= "unavailable", "stderr must not drive capability policy")
end

-- Exit 2 predates structured result sidecars and remains the explicit SKIP
-- contract. It is structured when recorded, but never reclassified as FAIL.
local function test_legacy_exit_two_remains_skip()
  local base = fs.join(tmpdir, "legacy_skip")
  local code = testrun.run({"sh", "-c", "exit 2"}, base, {
      timeout_ms = 1000, profile = "local",
      source_path = capability_source("legacy_skip"),
    })
  local result = decoded(base)
  assert(code == records.EXIT_SKIP and result.status == "skip" and not result.fatal,
    "legacy exit 2 must remain a nonfatal skip")
  assert(testrun.report({base}) == 0, "legacy skip must not fail report")
end

-- Linux CI names the supported lane explicitly and treats every registered
-- required capability as mandatory.
local function test_linux_ci_capability_absence_fails()
  local base = fs.join(tmpdir, "strict_unavailable.tl.test")
  local code = testrun.run({"true"}, base, {
      timeout_ms = 1000, profile = "linux-ci",
      source_path = capability_source("strict_unavailable"),
      capabilities = {["loopback-listen"] = {
          available = false, detail = "injected absence",
        }},
    })
  local result = decoded(base)
  assert(code == 1 and result.status == "unavailable" and result.fatal,
    "linux-ci absence must be fatal but remain unavailable")
  assert(testrun.report({base}) == 1, "strict unavailability must fail report")
end

-- The make prerequisite includes live probe evidence; otherwise a cached PASS
-- could stand in after the host capability disappeared.
local function test_policy_evidence_changes_with_probe_answer()
  local available = {
    ["loopback-listen"] = {available = true, detail = ""},
    ["ape-assimilation"] = {available = true, detail = ""},
    ["nanosecond-timestamps"] = {available = true, detail = ""},
  }
  local absent = {
    ["loopback-listen"] = {available = false, detail = "injected"},
    ["ape-assimilation"] = {available = true, detail = ""},
    ["nanosecond-timestamps"] = {available = true, detail = ""},
  }
  assert(testplan.policy_evidence(tmpdir, available) ~=
    testplan.policy_evidence(tmpdir, absent),
    "capability answer must invalidate the record prerequisite")
end

-- A whole-file execution requirement must not suppress static checks of that
-- source. Formatting and lint still run on an unsupported local host.
local function test_capability_requirement_only_gates_execution()
  local plan = testplan.resolve(fs.join(tmpdir, "fixture.tl.fmt"), tmpdir, {
      timeout_ms = 1000, profile = "local",
      source_path = capability_source("static_check"),
      capabilities = {["loopback-listen"] = {
          available = false, detail = "injected absence",
        }},
    })
  assert(plan.error == "" and plan.unavailable == "",
    "static checks must not be classified unavailable")
end

local function test_malformed_result_sidecar_is_refused()
  local result, err = tresult.decode("testrun-result 1\nstatus timeout\n")
  assert(result == nil and err:find("missing field", 1, true),
    "malformed sidecar was accepted: " .. tostring(err))
end

local function test_non_integer_timeout_sidecars_are_refused()
  local function sidecar(value: string): string
    return "testrun-result 1\nstatus timeout\nfatal 1\ntimeout_ms " .. value ..
    "\ndetail deadline\ncleanup_error \n"
  end
  for _, value in ipairs({"0.5", "1e999", "999999999999999999999999"}) do
    local ok, result, err = pcall(tresult.decode, sidecar(value))
    assert(ok, "decoder crashed for timeout_ms " .. value)
    assert(result == nil and err:find("non%-negative integer"),
      "decoder accepted timeout_ms " .. value .. ": " .. tostring(err))
  end
end

print("testrun contract tests passed")
