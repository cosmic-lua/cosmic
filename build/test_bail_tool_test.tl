--- `cosmic test --bail` starts no test after the first failure. The child
--- project's first test fails and the two after it would pass; each
--- test leaves a marker file, so a test that started is told from one
--- that did not.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.policy{ cpu_features = true, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A project of one module, whose tests run in the order of their names
--- and each mark `marks/<name>`. A name that starts `a_` fails; one
--- that starts `b_` first sleeps a second.
local function project(tmp: string, names: {string}): string
  local root = tmp .. "/project"
  local marks = tmp .. "/marks"
  assert(Fs.mkdirs(root .. "/suite") and Fs.mkdirs(marks))
  local source = ""
  for _, name in ipairs(names) do
    source = source .. string.format([[
local function test_%s()
  %s
  assert(require("cosmic.fs").write(%q, "ran"))
  %s
end
]], name, if name:sub(1, 2) == "b_" then 'require("cosmic.clock").sleep_ns(1000000000)' else "" end,
      marks .. "/" .. name,
      if name:sub(1, 2) == "a_" then 'error("first test failed")' else "assert(true)" end)
  end
  assert(Fs.write(root .. "/suite/bail_test.tl", source))
  return root
end

--- Runs `cosmic test` with `words` in `root`, unsandboxed whatever this
--- run's switch (a sandbox nested in this test's own may be refused
--- where the host nests only two deep), one worker at a time so the
--- order of the tests is the order they start in.
local function invoke(root: string, output: string, words: {string},
                      jobs?: string): Child.Result
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.TMPDIR = Fs.dirname(output)
  local argv: mut {string} = { "test", "--jobs", jobs or "1" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local started = this_program.program(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

local function marked(tmp: string, name: string): boolean
  return Fs.read(tmp .. "/marks/" .. name) ~= nil
end

--- Without the flag every test runs. With it, the failure is recorded,
--- the tests after it never start and leave no verdict, and the run
--- fails. A run after it, without the flag, starts the tests that did
--- not start before.
local function test_a_bailing_run_starts_no_test_after_the_first_failure(tmp: string)
  local root = project(tmp, { "a_fails", "b_passes", "c_passes" })
  local plain = invoke(root, tmp .. "/plain.out", {})
  local plain_text = assert(Fs.read(tmp .. "/plain.out"))
  assert(not plain.ok and plain_text:find("1 of 3 tests failed", 1, true) ~= nil, plain_text)
  assert(marked(tmp, "a_fails") and marked(tmp, "b_passes") and marked(tmp, "c_passes"),
    "a run without --bail left a test unstarted")

  local other = tmp .. "/other"
  local fresh = project(other, { "a_fails", "b_passes", "c_passes" })
  local bailed = invoke(fresh, other .. "/bail.out", { "--bail" })
  local text = assert(Fs.read(other .. "/bail.out"))
  assert(not bailed.ok, text)
  assert(text:find("test: FAIL  suite.bail_test test_a_fails", 1, true), text)
  assert(text:find("2 not run after the first failure", 1, true), text)
  assert(marked(other, "a_fails"), "the failing test did not run")
  assert(not marked(other, "b_passes") and not marked(other, "c_passes"),
    "a test started after the first failure")

  local build_db = assert(build_paths.directory(fresh)) .. "/build.db"
  local db = assert(Sqlite.open(build_db))
  local rows = assert(Sqlite.text_rows(db, "SELECT test, passed FROM runs ORDER BY test"))
  assert(db:close())
  assert(#rows == 1 and rows[1]:text(1) == "test_a_fails" and rows[1]:text(2) == "0",
    "the run kept a verdict for a test that did not start")

  local again = invoke(fresh, other .. "/again.out", {})
  local again_text = assert(Fs.read(other .. "/again.out"))
  assert(not again.ok and again_text:find("1 of 3 tests failed", 1, true) ~= nil, again_text)
  assert(marked(other, "b_passes") and marked(other, "c_passes"))
end

--- With two workers, a test in flight when the failure lands finishes and
--- keeps its own verdict; the tests after it never start.
local function test_a_test_in_flight_at_the_first_failure_finishes(tmp: string)
  local root = project(tmp, { "a_fails", "b_passes", "c_passes", "d_passes" })
  local result = invoke(root, tmp .. "/two.out", { "--bail" }, "2")
  local text = assert(Fs.read(tmp .. "/two.out"))
  assert(not result.ok and text:find("test: FAIL  suite.bail_test test_a_fails", 1, true), text)
  assert(text:find("2 not run after the first failure", 1, true), text)
  assert(marked(tmp, "a_fails") and marked(tmp, "b_passes"), "the in-flight test did not finish")
  assert(not marked(tmp, "c_passes") and not marked(tmp, "d_passes"),
    "a test started after the first failure")
  local db = assert(Sqlite.open(assert(build_paths.directory(root)) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db, "SELECT test, passed FROM runs ORDER BY test"))
  assert(db:close())
  assert(#rows == 2 and rows[1]:text(1) == "test_a_fails" and rows[1]:text(2) == "0" and
      rows[2]:text(1) == "test_b_passes" and rows[2]:text(2) == "1", "the runs kept: " .. tostring(#rows))
end
