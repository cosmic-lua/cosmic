--- How the runner starts a worker and reads what it reports into a
--- verdict ([`worker.invocation`], [`worker.judge`]), and the hold of what a
--- worker ran to what its test's key holds.

local type Child = require("cosmic.child")
local worker = require("build.test_worker")
local Time = require("cosmic.time")

--- A worker's end, having written `report` to the report's descriptor.
local function ended(report: worker.Report): Child.Result
  return { ok = true, code = 0, timed_out = false, truncated = false,
    captured = { [worker.report_fd] = worker.encode(report) } }
end

--- A passing report whose worker loaded `modules`.
local function passing(modules: {string}): worker.Report
  return { loaded = true, passed = true, message = "", elapsed_ns = 1,
    load_hits = {}, test_hits = {}, modules = modules }
end

local function test_a_report_carries_what_its_worker_loaded()
  local back = assert(worker.decode(worker.encode(passing({ "build.a", "cosmic.fs", "string" }))))
  assert(#back.modules == 3 and back.modules[1] == "build.a" and back.modules[3] == "string")
  -- A report of another shape, an older worker's, is none.
  local older = worker.encode(passing({})):gsub("^cosmic%-test%-report%-4", "cosmic-test-report-3")
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
    return worker.judge({ result = ended(passing(modules)), trouble = "", timeout_ns = Time.seconds(1),
      sandboxed = true, carried = held ~= false and carried or nil,
      closure = held ~= false and closure or nil })
  end
  local kept = judged({ "build.lib", "build.lib_test", "build.test_worker",
    "cosmic.sys", "string" })
  assert(kept.passed, kept.message)
  -- Nor is the catalog of removed names any worker's but its closure's:
  -- what a refusal or the core quotes of it is what a test read.
  local catalog = judged({ "build.lib", "build.test_worker", "cosmic.removed" })
  assert(not catalog.passed)
  assert(catalog.message:find("its worker ran cosmic.removed,", 1, true), catalog.message)
  local failed = judged({ "build.docs", "build.lib", "build.test_worker" })
  assert(not failed.passed)
  assert(failed.message:find("its worker ran build.docs,", 1, true), failed.message)
  assert(failed.message:find("worker.loads", 1, true), failed.message)
  assert(failed.report ~= nil and failed.report.passed)
  -- Given no set of what the tool carries, nothing of what it ran is held.
  assert(judged({ "build.docs" }, false).passed)
end

--- A worker that reported nothing fails its test by what went wrong.
local function test_a_worker_without_a_report_fails_its_test()
  local unsupervised = worker.judge({ trouble = "no fork", timeout_ns = Time.seconds(1), sandboxed = false })
  assert(not unsupervised.passed and unsupervised.report == nil)
  assert(unsupervised.message == "the test process could not be supervised: no fork")
  local late = worker.judge({ result = { ok = false, timed_out = true, truncated = false,
    captured = {} }, trouble = "", timeout_ns = Time.seconds(30), sandboxed = true })
  assert(late.message == "timed out after 30 s; its pid namespace was ended", late.message)
  local crashed = worker.judge({ result = { ok = false, signal = 9, timed_out = false,
    truncated = false, captured = {} }, trouble = "", timeout_ns = Time.seconds(1), sandboxed = false })
  assert(crashed.message == "the test process was killed by signal 9 before it reported " ..
      "(no report)", crashed.message)
  -- A pass whose processes outlived it is not one.
  local outlived = worker.judge({ result = ended(passing({})), trouble = "a process outlived it",
    timeout_ns = Time.seconds(1), sandboxed = false })
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
    name = "test_x", scratch = "/tmp", needs = "", hold = "forbid", open = true,
    closure = { "suite.a_test" }, tree = { "suite.a_test", "suite.b" }, declared = { "d" },
  })
  local argv, options = command.argv, command.options
  local expected = { "/bin/cosmic", "--relaunched", "test", "--worker-no-tool", "/tree",
    "suite.a_test", "test_x", "/tmp/tmp", "/tmp/children", "", "--open", "suite.a_test",
    "--tree", "suite.a_test", "suite.b", "--declared", "d" }
  assert(#argv == #expected, table.concat(argv, " "))
  for i, value in ipairs(expected) do assert(argv[i] == value, i .. ": " .. argv[i]) end
  assert(options.env.PATH == "/bin" and options.env.COVERAGE == "1")
  assert(options.env.COSMIC_COVERAGE_STARTUP == "1")
  assert(options.fds[worker.report_fd] == "capture" and options.fds[254] == 7)
  assert(options.process_group and options.sandbox == nil and options.stdin == "null")
  -- Held by a ruleset that forbids running nothing, or by none.
  for hold, flag in pairs({ mounts = "--worker-held", none = "--worker" } as {string:string}) do
    local held = worker.invocation({
      start = { argv = { "/bin/cosmic" }, env = {}, fds = {} }, env = {}, root = "/tree",
      module_path = "suite.a_test", name = "test_x", scratch = "/tmp", needs = "",
      hold = hold as worker.Hold, open = false, closure = {}, tree = {}, declared = {},
    })
    assert(held.argv[3] == flag, hold .. ": " .. table.concat(held.argv, " "))
  end
  -- Given the store of its closure, it names it ahead of the closure;
  -- `open`, which gives it the whole projection, names none.
  for _, open in ipairs({ false, true }) do
    local given = worker.invocation({
      start = { argv = { "/bin/cosmic" }, env = {}, fds = {} }, env = {}, root = "/tree",
      module_path = "suite.a_test", name = "test_x", scratch = "/tmp", needs = "",
      hold = "none", open = open, store = "/stores/a.db", closure = { "suite.a_test" },
      tree = {}, declared = {},
    })
    local said = table.concat(given.argv, " ", 10)
    local wanted = open and "--open suite.a_test --tree --declared" or
      "--store /stores/a.db suite.a_test --tree --declared"
    assert(said == wanted, said)
  end
end

--- A test that said it could not check what it exists to check
--- ([`Test.skip`]) reports why, and is judged skipped where it passed:
--- only a pass is, since a failure is one whether it skipped or not.
local function test_a_skip_is_reported_and_judged_only_of_a_pass()
  local report = passing({})
  report.skipped = "no Landlock: ENOSYS; no pledge"
  local back = assert(worker.decode(worker.encode(report)))
  assert(back.skipped == "no Landlock: ENOSYS; no pledge", back.skipped)
  assert(assert(worker.decode(worker.encode(passing({})))).skipped == "")
  local skipped = worker.judge({ result = ended(report), trouble = "", timeout_ns = Time.seconds(1),
    sandboxed = false })
  assert(skipped.passed and skipped.skipped == "no Landlock: ENOSYS; no pledge", skipped.skipped)
  report.passed, report.message = false, "asserted"
  local failed = worker.judge({ result = ended(report), trouble = "", timeout_ns = Time.seconds(1),
    sandboxed = false })
  assert(not failed.passed and failed.skipped == "", failed.skipped)
  -- A pass whose processes outlived it fails, skip or not.
  report.passed = true
  local outlived = worker.judge({ result = ended(report), trouble = "a process outlived it",
    timeout_ns = Time.seconds(1), sandboxed = false })
  assert(not outlived.passed and outlived.skipped == "")
end
