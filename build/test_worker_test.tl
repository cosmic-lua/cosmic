--- How the runner starts a worker and reads what it reports into a
--- verdict (`worker.invocation`, `worker.judge`), and the hold of what a
--- worker ran to what its test's key holds.

local type Child = require("cosmic.child")
local worker = require("build.test_worker")

--- A worker's end, having written `report` to the report's descriptor.
local function ended(report: worker.Report): Child.Result
  return { ok = true, code = 0, timed_out = false, truncated = false,
    captured = { [worker.report_fd] = worker.encode(report) } }
end

--- A passing report whose worker loaded `modules`.
local function passing(modules: {string}): worker.Report
  return { loaded = true, passed = true, message = "", elapsed_ns = 1,
    load_reads = {}, test_reads = {}, load_hits = {}, test_hits = {}, modules = modules }
end

local function test_a_report_carries_what_its_worker_loaded()
  local back = assert(worker.decode(worker.encode(passing({ "build.a", "cosmic.fs", "string" }))))
  assert(#back.modules == 3 and back.modules[1] == "build.a" and back.modules[3] == "string")
  -- A report of another shape, an older worker's, is none.
  local older = worker.encode(passing({})):gsub("^cosmic%-test%-report%-2", "cosmic-test-report-1")
  assert(worker.decode(older) == nil)
end

--- A pass whose worker ran a module of the tree the tool carries that
--- is neither of its closure nor of what every worker loads fails,
--- naming it: no key of its test holds it. What the tool does not
--- carry -- the core's own modules, Lua's -- is the runtime's to key.
local function test_a_worker_that_ran_an_unkeyed_module_fails_its_test()
  local carried = { ["build.docs"] = true, ["build.lib"] = true, ["build.test_worker"] = true,
    ["cosmic.removed"] = true }
  local closure = { ["build.lib"] = true, ["build.lib_test"] = true }
  local function judged(modules: {string}, held?: boolean): worker.Judgement
    return worker.judge({ result = ended(passing(modules)), trouble = "", timeout_ms = 1000,
      sandboxed = true, carried = held ~= false and carried or nil,
      closure = held ~= false and closure or nil })
  end
  local kept = judged({ "build.lib", "build.lib_test", "build.test_worker", "cosmic.removed",
    "cosmic.sys", "string" })
  assert(kept.passed, kept.message)
  local failed = judged({ "build.docs", "build.lib", "build.test_worker" })
  assert(not failed.passed)
  assert(failed.message:find("its worker ran build.docs,", 1, true), failed.message)
  assert(failed.message:find("worker.loads", 1, true), failed.message)
  assert(failed.report ~= nil and failed.report.passed)
  -- Unsandboxed, what a test read keys it, and nothing is held.
  assert(judged({ "build.docs" }, false).passed)
end

--- A worker that reported nothing fails its test by what went wrong.
local function test_a_worker_without_a_report_fails_its_test()
  local unsupervised = worker.judge({ trouble = "no fork", timeout_ms = 1000, sandboxed = false })
  assert(not unsupervised.passed and unsupervised.report == nil)
  assert(unsupervised.message == "the test process could not be supervised: no fork")
  local late = worker.judge({ result = { ok = false, timed_out = true, truncated = false,
    captured = {} }, trouble = "", timeout_ms = 30000, sandboxed = true })
  assert(late.message == "timed out after 30 s; its pid namespace was ended", late.message)
  local crashed = worker.judge({ result = { ok = false, signal = 9, timed_out = false,
    truncated = false, captured = {} }, trouble = "", timeout_ms = 1000, sandboxed = false })
  assert(crashed.message == "the test process was killed by signal 9 before it reported " ..
    "(no report)", crashed.message)
  -- A pass whose processes outlived it is not one.
  local outlived = worker.judge({ result = ended(passing({})), trouble = "a process outlived it",
    timeout_ms = 1000, sandboxed = false })
  assert(not outlived.passed and outlived.message == "a process outlived it")
end

--- A worker is this program again, with the test's command line after
--- the program's own, and its report captured; unsandboxed it leads a
--- process group of its own.
local function test_a_worker_is_started_as_its_command_line_says()
  local command = worker.invocation({
    start = { argv = { "/bin/cosmic", "--relaunched" }, env = { COVERAGE = "1" },
      fds = { [254] = 7 } },
    env = { PATH = "/bin", COVERAGE = "0" }, root = "/tree", module_path = "suite.a_test",
    name = "test_x", scratch = "/tmp", needs = "", held = "", no_tool = true, open = true,
    closure = { "suite.a_test" }, tree = { "suite.a_test", "suite.b" }, declared = { "d" },
  })
  local argv, options = command.argv, command.options
  local expected = { "/bin/cosmic", "--relaunched", "test", "--worker-no-tool", "/tree",
    "suite.a_test", "test_x", "/tmp/tmp", "/tmp/children", "", "", "--open", "suite.a_test",
    "--tree", "suite.a_test", "suite.b", "--declared", "d" }
  assert(#argv == #expected, table.concat(argv, " "))
  for i, value in ipairs(expected) do assert(argv[i] == value, i .. ": " .. argv[i]) end
  assert(options.env.PATH == "/bin" and options.env.COVERAGE == "1")
  assert(options.env.COSMIC_COVERAGE_STARTUP == "1")
  assert(options.fds[worker.report_fd] == "capture" and options.fds[254] == 7)
  assert(options.process_group and options.sandbox == nil and options.stdin == "null")
end
