local Sqlite = require("cosmic.sqlite")
local State = require("cosmic_ci.state")
local SuiteOutput = require("cosmic_ci.suite_output")

local key_parts <const> = "test: key parts: host features 0123456789abcdef, host aaaaaaaaaaaa, " ..
  "system , runtime bbbbbbbbbbbb, compiler cccccccccccc, harness dddddddddddd"

--- A sandboxed run's lines as build/test.tl says them, --census asked.
local function test_a_passing_sandboxed_run()
  local figures = SuiteOutput.parse("boot: PASS (3 targets, 2344 ms)\n" ..
    "test: sandbox: each worker is held to its inputs, the tree at /tree\n" ..
    key_parts .. "\n" ..
    "test: 1994 tests keyed by their declared inputs in 12.5 ms (40 files read)\n" ..
    "test: coverage 71.2% (1/2 lines; informational, never a failure)\n" ..
    "test: PASS (1994 tests, 193 modules; 0 ran, 1994 stood, 2385 ms; sandboxed)\n")
  assert(figures.verdict == "pass" and figures.tests == 1994 and figures.modules == 193)
  assert(figures.ran == 0 and figures.stood == 1994 and figures.shared == 0)
  assert(figures.every == 0 and figures.assumed == 0 and figures.failed == 0)
  assert(figures.elapsed_ms == 2385 and figures.sandbox == "sandboxed", figures.sandbox)
  local parts = assert(figures.parts)
  assert(parts["host features"] == "0123456789abcdef" and parts.host == "aaaaaaaaaaaa")
  assert(parts.system == "" and parts.runtime == "bbbbbbbbbbbb")
  assert(parts.compiler == "cccccccccccc" and parts.harness == "dddddddddddd")
  assert(parts.launcher == nil)
  assert(SuiteOutput.status(figures, 0) == "pass")
end

local function test_a_pass_with_every_optional_count()
  local figures = SuiteOutput.parse("test: PASS (40 tests, 3 modules; 12 ran, 28 stood, " ..
    "2 run every time (no key holds them), 5 assumed (--all runs them), " ..
    "20 of them on another checkout's verdict, 901 ms; unsandboxed (COSMIC_TEST_SANDBOX=0), " ..
    "sharing no verdicts)\n")
  assert(figures.ran == 12 and figures.stood == 28 and figures.every == 2)
  assert(figures.assumed == 5 and figures.shared == 20 and figures.elapsed_ms == 901)
  assert(figures.sandbox == "unsandboxed (COSMIC_TEST_SANDBOX=0), sharing no verdicts",
    figures.sandbox)
  assert(figures.parts == nil)
end

--- A failing run says its failures, then a summary with no ran or stood
--- count; the failures' own lines are not its summary.
local function test_a_failing_run()
  local figures = SuiteOutput.parse(key_parts .. "\n" ..
    "test: FAIL  build/x_test.tl: test_y (assertion failed!)\n" ..
    "test: FAIL (2 of 1994 failed, 1 infrastructure errors, 4100 ms; sandboxed)\n")
  assert(figures.verdict == "fail" and figures.failed == 2 and figures.tests == 1994)
  assert(figures.errors == 1 and figures.elapsed_ms == 4100 and figures.sandbox == "sandboxed")
  assert(figures.ran == nil and figures.stood == nil)
  assert(figures.parts and figures.parts.harness == "dddddddddddd")
  assert(SuiteOutput.status(figures, 1) == "fail")
  local bare = SuiteOutput.parse("test: FAIL (1 of 3 failed, 0 infrastructure errors, 9 ms)\n")
  assert(bare.verdict == "fail" and bare.sandbox == "")
end

--- A run that stood on none of a cache's rows says its key parts in the
--- `unmatched` line in place of the `key parts` one.
local function test_the_unmatched_line_says_the_parts()
  local figures = SuiteOutput.parse("test: shared verdicts: none of 1994 tests looked up " ..
    "stood, though /c/checked.db holds 2000 rows, 1994 of them of those tests: none under " ..
    "the keys this run reached (host features 01, host 02, system 03, runtime 04, " ..
    "compiler 05, harness 06, launcher 07)\n" ..
    "test: PASS (1994 tests, 193 modules; 1994 ran, 0 stood, 250000 ms; sandboxed)\n")
  local parts = assert(figures.parts)
  assert(parts.runtime == "04" and parts.harness == "06" and parts.launcher == "07")
  assert(figures.ran == 1994 and figures.stood == 0)
end

--- Timed out, or stopped before its summary: a status, no figures.
local function test_a_run_without_its_summary()
  local timed = SuiteOutput.parse("test: sandbox: each worker is held to its inputs\n")
  assert(timed.verdict == nil and timed.tests == nil and timed.parts == nil)
  assert(SuiteOutput.status(timed, 124) == "timeout")
  assert(SuiteOutput.status(timed, 1) == "unreported")
  assert(SuiteOutput.status(SuiteOutput.parse(""), 0) == "unreported")
  -- A summary cut short is no summary.
  local cut = SuiteOutput.parse("test: PASS (1994 tests, 193 mod")
  assert(cut.verdict == nil)
  -- A timeout's status stands over a summary a nested run printed.
  assert(SuiteOutput.status(SuiteOutput.parse("test: PASS (1 tests, 1 modules; 1 ran, " ..
    "0 stood, 3 ms)\n"), 124) == "timeout")
end

--- The last summary is the suite's: a test's own output may hold one.
local function test_the_last_summary_is_the_suites()
  local figures = SuiteOutput.parse(
    "test: PASS (1 tests, 1 modules; 1 ran, 0 stood, 3 ms)\r\n" ..
    "test: PASS (10 tests, 2 modules; 4 ran, 6 stood, 30 ms; sandboxed)\r\n")
  assert(figures.tests == 10 and figures.stood == 6 and figures.sandbox == "sandboxed")
end

--- A row written and read back, and the summary's table of it.
local function test_rows_round_trip_into_the_summary_table(tmp: string)
  local path = tmp .. "/operations.db"
  local figures = SuiteOutput.parse(key_parts .. "\n" ..
    "test: PASS (200 tests, 20 modules; 1 ran, 199 stood, 2385 ms; sandboxed)\n")
  State.suite(path, { worker = "linux-x86_64", run = "7", attempt = "1", phase = "build",
    suite = "local", status = SuiteOutput.status(figures, 0), exit_code = 0,
    tests = figures.tests, modules = figures.modules, ran = figures.ran,
    stood = figures.stood, shared = figures.shared, every = figures.every,
    assumed = figures.assumed, failed = figures.failed, elapsed_ms = figures.elapsed_ms,
    sandbox = figures.sandbox, parts = figures.parts })
  State.suite(path, { worker = "linux-x86_64", run = "7", attempt = "1", phase = "fixtures",
    suite = "fixture runtime|regression", status = "timeout", exit_code = 124 })
  local db = assert(Sqlite.open(path))
  local rows = State.suite_rows(db)
  assert(db:close())
  assert(#rows == 2)
  assert(rows[1].ran == 1 and rows[1].stood == 199 and rows[1].elapsed_ms == 2385)
  assert(rows[1].parts.runtime == "bbbbbbbbbbbb" and rows[1].parts.system == "")
  assert(rows[2].tests == nil and rows[2].exit_code == 124 and rows[2].parts.runtime == nil)
  local text = SuiteOutput.markdown(rows)
  assert(text:find("| linux-x86_64 | build | local | pass | 0 | 200 | 1 | 199 | 99.5 | 0 | " ..
    "2385 | bbbbbbbbbbbb | dddddddddddd | cccccccccccc | aaaaaaaaaaaa |  | 0123456789abcdef |",
    1, true), text)
  assert(text:find("| linux-x86_64 | fixtures | fixture runtime\\|regression | timeout | 124 " ..
    "|  |  |  |  |  |  |", 1, true), text)
  -- An operations database from before the table has no rows.
  local old = tmp .. "/old.db"
  local handle = assert(Sqlite.open(old, true))
  assert(handle:exec("CREATE TABLE operation_events (id INTEGER PRIMARY KEY)"))
  assert(#State.suite_rows(handle) == 0)
  assert(handle:close())
end
