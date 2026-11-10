--- How the runner starts a worker and reads what it reports into a
--- verdict ([`worker.invocation`], [`worker.judge`]), and the check of what a
--- worker ran against what its test's key holds.

local type Child = require("cosmic.child")
local type Sandbox = require("cosmic.sandbox")
local Clock = require("cosmic.clock")
local Globals = require("cosmic.internal.globals")
local worker = require("build.test_worker")
local test_key = require("build.test_key")
local support = require("build.test_support_fixture")

--- A worker's end, having written `report` to the report's descriptor.
local function ended(report: worker.Report): Child.Result
  return { ok = true, code = 0, timed_out = false, truncated = false,
    captured = { [worker.report_fd] = worker.encode(report) } }
end

--- A passing report whose worker loaded `modules`.
local function passing(modules: mut {string}): worker.Report
  return { loaded = true, passed = true, message = "", elapsed_ns = 1,
    load_hits = {}, test_hits = {}, modules = modules }
end

local function test_a_report_carries_what_its_worker_loaded()
  local back = assert(worker.decode(worker.encode(passing({ "build.a", "cosmic.fs", "string" }))))
  assert(#back.modules == 3 and back.modules[1] == "build.a" and back.modules[3] == "string")
  -- A report of another shape, an older worker's, is none.
  local older = worker.encode(passing({})):gsub("^cosmic%-test%-report%-5", "cosmic-test-report-4")
  assert(worker.decode(older) == nil)
end

--- A line of hits another report held is not read again: the tables a
--- report holds for it are the ones the first did, which is how the runner
--- tells a module's load hits it has folded already.
local function test_a_line_of_hits_read_twice_is_one_table()
  local function reported(loaded: {integer}, tested: {integer}): worker.Report
    local report = passing({})
    report.load_hits = { ["build.a"] = { [support.nth(loaded, 1)] = true, [support.nth(loaded, 2)] = true } }
    report.test_hits = { ["build.a"] = { [support.nth(tested, 1)] = true } }
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

--- A module's lines are written as runs of consecutive lines, dense ones (a pure store's import, a line an
--- instruction) walked rather than sorted, and read back whole; a run that ends before it starts or is longer than
--- a chunk's instructions can be, an empty item or an empty list is no report.
local function test_hits_are_written_as_runs_of_lines_and_read_back_whole()
  local report = passing({})
  local dense: mut {integer:boolean} = {}
  for line = 16777217, 16777300 do dense[line] = true end
  dense[16777250] = nil
  local sparse: {integer:boolean} = { [1] = true, [2] = true, [900] = true, [40000] = true }
  report.load_hits = { ["build.a"] = dense, ["build.b"] = sparse }
  local text = worker.encode(report)
  assert(text:find(" 16777217%-16777249,16777251%-16777300\n") ~= nil, text)
  assert(text:find(" 1%-2,900,40000\n") ~= nil, text)
  local back = assert(worker.decode(text))
  local a = assert(back.load_hits["build.a"])
  local b = assert(back.load_hits["build.b"])
  local count = 0
  for line in pairs(a) do
    count = count + 1
    assert(dense[line] == true, "a line was read that was not written: " .. tostring(line))
  end
  assert(count == 83 and a[16777250] == nil, "the dense lines were not read back whole")
  assert(b[1] == true and b[2] == true and b[900] == true and b[40000] == true and b[3] == nil)
  for _, bad in ipairs({ "2-1", "1,,2", ",1", "1,", "", "1-16777217", "1-99999999999" }) do
    local malformed = text:gsub(" 1%-2,900,40000\n", " " .. bad .. "\n")
    assert(worker.decode(malformed) == nil, "a malformed list of lines was read: " .. bad)
  end
  -- A module none of whose lines was hit is not written, so what is written is never an empty list.
  local none = passing({})
  none.test_hits = { ["build.c"] = {} }
  assert(not worker.encode(none):find("test-hit", 1, true), "a module with no line hit was written")
end

--- A pass whose worker ran a module of the tree the tool carries that
--- is neither of its closure nor of what every worker loads fails,
--- naming it: no key of its test holds it. What the tool does not
--- carry -- the core's own modules, Lua's -- is the runtime's to key.
local function test_a_worker_that_ran_an_unkeyed_module_fails_its_test()
  local carried = { ["build.docs"] = true, ["build.lib"] = true, ["build.test_worker"] = true,
    ["cosmic.removed"] = true }
  local closure = { ["build.lib"] = true, ["build.lib_test"] = true }
  local function judged(modules: mut {string}, held?: boolean): worker.Judgement
    return worker.judge({ result = ended(passing(modules)), trouble = "", timeout_ns = Clock.seconds(1),
      sandboxed = true, carried = if held ~= false then carried else nil end,
      closure = if held ~= false then closure else nil end })
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

--- A checked run's worker reports whether the hooks it defined are the harness's own when it reports; one that
--- does not say so fails a checked run's test, since its pass would have checked nothing, and no other run's.
local function test_a_checked_run_fails_a_worker_that_installed_no_hooks()
  local function judged(checked: boolean?, checks: boolean?): worker.Judgement
    local report = passing({})
    report.checked = checked
    return worker.judge({ result = ended(report), trouble = "", timeout_ns = Clock.seconds(1),
      sandboxed = true, checks = checks })
  end
  local missing = judged(nil, true)
  assert(not missing.passed and missing.message:find("harness's own hook", 1, true) ~= nil, missing.message)
  assert(judged(false, true).passed == false)
  assert(judged(true, true).passed)
  assert(judged(nil, false).passed, "an unchecked run needs no hooks")
  assert(judged(nil, nil).passed)
  local back = assert(worker.decode(worker.encode((function(): worker.Report
    local report = passing({})
    report.checked = true
    return report
  end)())))
  assert(back.checked == true)
end

--- A worker reports `checked` only while `__fact` and `__cosmic_tc` are the harness's own hooks: one a test took
--- away or replaced reports false, so a pass that checked nothing keeps no verdict.
local function test_the_hooks_are_held_only_while_they_are_the_harness_s_own()
  local function run(text: string)
    assert(load(text, "=hooks", "t", Globals.table()))()
  end
  worker.install_checks()
  assert(worker.hooks_held())
  run("local fact = __fact; __fact = function(v) return v end; _G.__kept_fact = fact")
  assert(not worker.hooks_held(), "a replaced __fact was taken for the harness's")
  run("__fact = __kept_fact; __kept_fact = nil")
  assert(worker.hooks_held())
  run("_G.__kept_tc = __cosmic_tc; __cosmic_tc = nil")
  assert(not worker.hooks_held(), "a missing __cosmic_tc was taken for the harness's")
  run("__cosmic_tc = __kept_tc; __kept_tc = nil")
  assert(worker.hooks_held())
end

--- A checked run keeps no verdict of a test whose worker met a violation: a row in its report, or rows it kept
--- no record of (`dropped`) each count.
local function test_a_report_with_a_row_or_dropped_rows_met_something()
  local function reported(violations: {worker.Violation}?, dropped: integer?): worker.Report
    return { loaded = true, passed = true, message = "", elapsed_ns = 1, load_hits = {}, test_hits = {},
      modules = {}, violations = violations, dropped = dropped }
  end
  assert(test_key.met_nothing(nil))
  assert(test_key.met_nothing(reported(nil, nil)))
  assert(test_key.met_nothing(reported({}, 0)))
  local row: worker.Violation = { kind = "fact", at = "x.tl:1:1", target = "x", declared = "not nil", actual = "nil", count = 1 }
  assert(not test_key.met_nothing(reported({ row }, nil)))
  assert(not test_key.met_nothing(reported({}, 3)), "rows past the worker's limit were taken for none")
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
  for i, value in ipairs(expected) do
    assert(argv[i] == value, tostring(i) .. ": " .. support.nth(argv, i))
  end
  assert(assert(options.env)["PATH"] == "/bin" and assert(options.env)["COVERAGE"] == "1")
  assert(assert(options.env)["COSMIC_COVERAGE_STARTUP"] == "1")
  assert(assert(options.fds)[worker.report_fd] == "capture" and assert(options.fds)[254] == 7)
  assert(options.process_group == true and options.sandbox == nil and options.stdin == "null")
  -- Held by a ruleset that forbids running nothing, or by none.
  for hold, flag in pairs({ mounts = "--worker-held", none = "--worker" } as {string:string}) do -- checked: cast_refused
    local held = worker.invocation({
      start = { argv = { "/bin/cosmic" }, env = {}, fds = {} }, env = {}, root = "/tree",
      module_path = "suite.a_test", name = "test_x", scratch = "/tmp", needs = "",
      hold = hold as worker.Hold, closure = {}, tree = {}, -- checked: cast_refused
    })
    assert(held.argv[3] == flag, hold .. ": " .. table.concat(held.argv, " "))
  end
  -- Given a store, it names it ahead of the closure; one given none
  -- names none, which the worker refuses.
  for _, store in ipairs({ "/stores/a.db", "" }) do
    local given = worker.invocation({
      start = { argv = { "/bin/cosmic" }, env = {}, fds = {} }, env = {}, root = "/tree",
      module_path = "suite.a_test", name = "test_x", scratch = "/tmp", needs = "",
      hold = "none", store = if store ~= "" then store else nil end, closure = { "suite.a_test" },
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
      policy = { isolate = { "file" }, promises = promises as {Sandbox.Promise} }, -- checked: cast_refused
    })
  end
  local nesting = started({ "fork", "nest" })
  local env = assert(assert(nesting.options.policy).set_env)
  assert(env["COSMIC_PORTABLE_ARTIFACT_FD"] == nil and env["COSMIC_PORTABLE_CORE_FD"] == nil)
  assert(env["COSMIC_PORTABLE_CORE_LENGTH"] == "9", "the rest of the contract stays")
  assert(assert(nesting.options.fds)[254] == nil and assert(nesting.options.fds)[255] == nil)
  assert(assert(nesting.options.fds)[worker.report_fd] == "capture")
  local plain = started({ "fork" })
  assert(assert(assert(plain.options.policy).set_env)["COSMIC_PORTABLE_ARTIFACT_FD"] == "254")
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
  local ran = ended(report)
  local outcomes: {Child.Result} = { { ...ran, ok = false, code = 7 },
    { ...ran, ok = false, code = nil, signal = 9 }, { ...ran, ok = false } }
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
  local shutdown = worker.judge({ result = { ...result, ok = false, code = 7 }, trouble = "", timeout_ns = Clock.seconds(1),
    sandboxed = false })
  assert(not shutdown.passed and shutdown.message:find("assertion failed", 1, true) ~= nil)
  assert(shutdown.message:find("exited with status 7", 1, true), shutdown.message)
  local late = worker.judge({ result = { ...ended(passing({})), ok = false, timed_out = true }, trouble = "", timeout_ns = Clock.seconds(30),
    sandboxed = false })
  assert(not late.passed and late.message:find("timed out after 30 s", 1, true) ~= nil)
end

--- A forking worker's records are read one at a time, each whole or not yet: a result holds its report and its
--- output by their lengths, whatever bytes they are, and a line no worker writes is said to be one.
local function test_a_forking_workers_records_are_read_whole_or_not_at_all()
  local report, output = "cosmic-test-report\nend\n", "printed\ndone\nresult 0 0 0 0\n"
  local text = "cosmic-test-forks-1\ntest 74657374 12345\noutput 11\nresult 0 0\nresult 0 -1 " .. tostring(#report) .. " " ..
    tostring(#output) .. "\n" .. report .. output .. "done\nretire 776879\nunforkable 6e6f\nwhat is this\n"
  local kinds: mut {string} = {}
  local at = 1
  while true do
    local found = worker.record_at(text, at)
    if found == nil then break end
    kinds[#kinds + 1] = found.kind
    if found.kind == "test" then
      assert(found.name == "test" and found.started_ns == 12345)
    elseif found.kind == "output" then
      assert(found.output == "result 0 0\n", found.output)
    elseif found.kind == "result" then
      assert(found.code == 0 and found.signal == -1)
      assert(found.report == report, found.report)
      assert(found.output == output, found.output)
    elseif found.kind == "retire" then
      assert(found.why == "why")
    elseif found.kind == "unforkable" then
      assert(found.why == "no")
    end
    at = found.after
  end
  assert(table.concat(kinds, " ") == "forks test output result retire unforkable malformed", table.concat(kinds, " "))
  assert(at == #text + 1, "every byte is read")
  -- Cut anywhere inside a record, there is none yet: nothing of a result is taken before its last byte.
  local result_from = assert(text:find("result 0 -1", 1, true))
  local result_to = assert(text:find("retire", 1, true)) - 1
  for cut = result_from, result_to - 1 do
    assert(worker.record_at(text:sub(1, cut), result_from) == nil, "a result cut at " .. tostring(cut))
  end
  assert(assert(worker.record_at(text:sub(1, result_to), result_from)).kind == "result")
end
