--- How the runner starts a worker and reads what it reports into a
--- verdict ([`worker.invocation`], [`worker.judge`]), and the check of what a
--- worker ran against what its test's key holds.

local type Child = require("cosmic.child")
local type Sandbox = require("cosmic.sandbox")
local Clock = require("cosmic.clock")
local worker = require("build.test_worker")

--- The element of `list` at `index`, which the case knows is there.
local function nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

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

--- A line of hits another report held is not read again: the tables a
--- report holds for it are the ones the first did, which is how the runner
--- tells a module's load hits it has folded already.
local function test_a_line_of_hits_read_twice_is_one_table()
  local function reported(loaded: {integer}, tested: {integer}): worker.Report
    local report = passing({})
    report.load_hits = { ["build.a"] = { [nth(loaded, 1)] = true, [nth(loaded, 2)] = true } }
    report.test_hits = { ["build.a"] = { [nth(tested, 1)] = true } }
    return report
  end
  local first = assert(worker.decode(worker.encode(reported({ 3, 5 }, { 7, 7 }))))
  local second = assert(worker.decode(worker.encode(reported({ 3, 5 }, { 9, 9 }))))
  assert(first.load_hits["build.a"] == second.load_hits["build.a"])
  assert(first.test_hits["build.a"] ~= second.test_hits["build.a"])
  local first_loaded = assert(first.load_hits["build.a"], "the first report has load hits for build.a")
  local first_tested = assert(first.test_hits["build.a"], "the first report has test hits for build.a")
  local second_tested = assert(second.test_hits["build.a"], "the second report has test hits for build.a")
  assert(first_loaded[3] == true and first_loaded[5] == true)
  assert(first_tested[7] == true and second_tested[9] == true)
  local malformed = worker.encode(passing({})):gsub("\nend\n$", "\ntest-hit zz 1\nend\n")
  assert(worker.decode(malformed) == nil)
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
    return worker.judge({ result = ended(passing(modules)), trouble = "", timeout_ns = Clock.seconds(1),
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
  local report = failed.report
  assert(report ~= nil and report.passed)
  -- Given no set of what the tool carries, nothing of what it ran is held.
  assert(judged({ "build.docs" }, false).passed)
end

--- A worker that reported nothing fails its test by what went wrong.
local function test_a_worker_without_a_report_fails_its_test()
  local unsupervised = worker.judge({ trouble = "no fork", timeout_ns = Clock.seconds(1), sandboxed = false })
  assert(not unsupervised.passed and unsupervised.report == nil)
  assert(unsupervised.message == "the test process could not be supervised: no fork")
  local late = worker.judge({ result = { ok = false, timed_out = true, truncated = false,
    captured = {} }, trouble = "", timeout_ns = Clock.seconds(30), sandboxed = true })
  assert(late.message == "timed out after 30 s; its pid namespace was ended", late.message)
  local crashed = worker.judge({ result = { ok = false, signal = 9, timed_out = false,
    truncated = false, captured = {} }, trouble = "", timeout_ns = Clock.seconds(1), sandboxed = false })
  assert(crashed.message == "the test process was killed by signal 9 before it reported " ..
      "(no report)", crashed.message)
  -- A pass whose processes outlived it is not one.
  local outlived = worker.judge({ result = ended(passing({})), trouble = "a process outlived it",
    timeout_ns = Clock.seconds(1), sandboxed = false })
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
    name = "test_x", scratch = "/tmp", needs = "", hold = "forbid",
    closure = { "suite.a_test" }, tree = { "suite.a_test", "suite.b" },
  })
  local argv, options = command.argv, command.options
  local expected = { "/bin/cosmic", "--relaunched", "test", "--worker-no-tool", "/tree",
    "suite.a_test", "test_x", "/tmp/tmp", "/tmp/children", "", "suite.a_test",
    "--tree", "suite.a_test", "suite.b" }
  assert(#argv == #expected, table.concat(argv, " "))
  for i, value in ipairs(expected) do assert(argv[i] == value, tostring(i) .. ": " .. nth(argv, i)) end
  assert(assert(options.env).PATH == "/bin" and assert(options.env).COVERAGE == "1")
  assert(assert(options.env).COSMIC_COVERAGE_STARTUP == "1")
  assert(assert(options.fds)[worker.report_fd] == "capture" and assert(options.fds)[254] == 7)
  assert(options.process_group == true and options.sandbox == nil and options.stdin == "null")
  -- Held by a ruleset that forbids running nothing, or by none.
  for hold, flag in pairs({ mounts = "--worker-held", none = "--worker" } as {string:string}) do
    local held = worker.invocation({
      start = { argv = { "/bin/cosmic" }, env = {}, fds = {} }, env = {}, root = "/tree",
      module_path = "suite.a_test", name = "test_x", scratch = "/tmp", needs = "",
      hold = hold as worker.Hold, closure = {}, tree = {},
    })
    assert(held.argv[3] == flag, hold .. ": " .. table.concat(held.argv, " "))
  end
  -- Given a store, it names it ahead of the closure; one given none
  -- names none, which the worker refuses.
  for _, store in ipairs({ "/stores/a.db", "" }) do
    local given = worker.invocation({
      start = { argv = { "/bin/cosmic" }, env = {}, fds = {} }, env = {}, root = "/tree",
      module_path = "suite.a_test", name = "test_x", scratch = "/tmp", needs = "",
      hold = "none", store = store ~= "" and store or nil, closure = { "suite.a_test" },
      tree = {},
    })
    local said = table.concat(given.argv, " ", 10)
    local wanted = if store ~= "" then "--store /stores/a.db suite.a_test --tree" else
      "suite.a_test --tree" end
    assert(said == wanted, said)
  end
end

--- A worker started under a policy that promises `nest` is handed no
--- descriptor of the program and told of none: [`Child.start`] refuses a
--- nest child one open for reading alone, and the startup opens the
--- artifact and core itself where it is told of none. Any other worker, or
--- one under a policy without `nest`, has both as the relaunch hands them.
local function test_a_nesting_worker_is_handed_no_descriptor_of_the_program()
  local function started(promises: {string}): worker.Command
    return worker.invocation({
      start = { argv = { "/core", "--artifact", "/a" },
        env = { COSMIC_PORTABLE_ARTIFACT_FD = "254", COSMIC_PORTABLE_CORE_FD = "255",
          COSMIC_PORTABLE_CORE_LENGTH = "9" },
        fds = { [254] = 7, [255] = 8 } },
      env = {}, root = "/tree", module_path = "suite.a_test", name = "test_x", scratch = "/tmp",
      needs = "", hold = "none", closure = {}, tree = {},
      policy = { isolate = { "file" }, promises = promises as {Sandbox.Promise} },
    })
  end
  local nesting = started({ "fork", "nest" })
  local env = assert(assert(nesting.options.policy).set_env)
  assert(env.COSMIC_PORTABLE_ARTIFACT_FD == nil and env.COSMIC_PORTABLE_CORE_FD == nil)
  assert(env.COSMIC_PORTABLE_CORE_LENGTH == "9", "the rest of the contract stays")
  assert(assert(nesting.options.fds)[254] == nil and assert(nesting.options.fds)[255] == nil)
  assert(assert(nesting.options.fds)[worker.report_fd] == "capture")
  local plain = started({ "fork" })
  assert(assert(assert(plain.options.policy).set_env).COSMIC_PORTABLE_ARTIFACT_FD == "254")
  assert(assert(plain.options.fds)[254] == 7 and assert(plain.options.fds)[255] == 8)
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
  local skipped = worker.judge({ result = ended(report), trouble = "", timeout_ns = Clock.seconds(1),
    sandboxed = false })
  assert(skipped.passed and skipped.skipped == "no Landlock: ENOSYS; no pledge", skipped.skipped)
  report.passed, report.message = false, "asserted"
  local failed = worker.judge({ result = ended(report), trouble = "", timeout_ns = Clock.seconds(1),
    sandboxed = false })
  assert(not failed.passed and failed.skipped == "", failed.skipped)
  -- A pass whose processes outlived it fails, skip or not.
  report.passed = true
  local outlived = worker.judge({ result = ended(report), trouble = "a process outlived it",
    timeout_ns = Clock.seconds(1), sandboxed = false })
  assert(not outlived.passed and outlived.skipped == "")
end

--- A complete report precedes shutdown: a finalizer can still end the
--- process unsuccessfully. Its report remains useful coverage, never a pass.
local function test_a_report_passes_only_after_successful_process_shutdown()
  local report = passing({})
  report.test_hits = { ["suite.tl"] = { [12] = true } }
  report.skipped = "unchecked"
  local outcomes: {Child.Result} = { ended(report), ended(report), ended(report) }
  nth(outcomes, 1).ok, nth(outcomes, 1).code = false, 7
  nth(outcomes, 2).ok, nth(outcomes, 2).code, nth(outcomes, 2).signal = false, nil, 9
  nth(outcomes, 3).ok = false
  for i, result in ipairs(outcomes) do
    local judged = worker.judge({ result = result, trouble = "", timeout_ns = Clock.seconds(1),
      sandboxed = false })
    assert(not judged.passed and judged.skipped == "")
    local judged_report = judged.report
    assert(judged_report ~= nil)
    local suite_hits = assert(judged_report.test_hits["suite.tl"], "the judged report has test hits for suite.tl")
    assert(suite_hits[12] == true)
    local ending = if i == 2 then "was killed by signal 9" else
      "exited with status " .. (if i == 1 then "7" else "0" end) end
    assert(judged.message:find(ending .. " after it reported", 1, true), judged.message)
  end
  report.passed, report.message = false, "assertion failed"
  local result = ended(report)
  local ordinary = worker.judge({ result = result, trouble = "", timeout_ns = Clock.seconds(1),
    sandboxed = false })
  assert(not ordinary.passed and ordinary.message == "assertion failed")
  result.ok, result.code = false, 7
  local shutdown = worker.judge({ result = result, trouble = "", timeout_ns = Clock.seconds(1),
    sandboxed = false })
  assert(not shutdown.passed and shutdown.message:find("assertion failed", 1, true) ~= nil)
  assert(shutdown.message:find("exited with status 7", 1, true), shutdown.message)
  result = ended(passing({}))
  result.ok, result.timed_out = false, true
  local late = worker.judge({ result = result, trouble = "", timeout_ns = Clock.seconds(30),
    sandboxed = false })
  assert(not late.passed and late.message:find("timed out after 30 s", 1, true) ~= nil)
end
