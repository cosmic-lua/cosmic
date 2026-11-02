--- `cosmic test --show-output` prints, beneath each test that ran, what the
--- test printed, in the `| ` form a failure shows it in. A test that stands
--- runs nothing, so the flag must not move a key to make it run.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start. A test that runs `cosmic test`
--- takes minutes where the host is loaded.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  timeout = 120,
}

--- A project of one module: a test that prints two lines and passes, one
--- that prints nothing, and one that prints and fails.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/chatty_test.tl", [[
local function test_prints_values()
  print("value=42")
  print("second line")
  assert(true)
end

local function test_prints_nothing()
  assert(true)
end

local function test_prints_and_fails()
  print("before the failure")
  error("boom")
end
]]))
  return root
end

--- Runs `cosmic test` with `words` in `root`, unsandboxed whatever this
--- run's switch, and answers what it said.
local function invoke(root: string, output: string, words: {string}): string
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_VERDICT_CACHE"] = "0"
  env["COSMIC_TEST_ALL"] = nil
  env["TMPDIR"] = Fs.dirname(output)
  local argv: mut {string} = { "test" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local started = this_program.program(argv, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(100),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  assert(result ~= nil, trouble)
  return (assert(Fs.read(output)))
end

--- Lines of `text` from the first that holds `head` to the one before the
--- next that starts `test: `.
local function beneath(text: string, head: string): string
  local at = assert(text:find(head, 1, true), head .. " is not in: " .. text)
  local rest = text:sub(at)
  local stop = rest:find("\ntest: ", 2, true)
  return stop and rest:sub(1, stop) or rest
end

--- A passing test's output is shown beneath it with the flag and is not
--- without. The flag moves no key: a run with it stands on the verdicts of
--- the run before, and says that those tests printed nothing because they did
--- not run, where `--all` with it runs them and shows the output. (The
--- failing test never stands, so it runs, and prints, every time.)
local function test_show_output_prints_what_a_passing_test_printed(tmp: string)
  local root = project(tmp)

  local plain = invoke(root, tmp .. "/plain.out", {})
  assert(plain:find("1 of 3 tests failed", 1, true), plain)
  assert(not plain:find("value=42", 1, true), "a passing test's output is shown unasked: " .. plain)
  assert(plain:find("  | before the failure", 1, true), plain)
  assert(not plain:find("test: PASS", 1, true), plain)

  local stood = invoke(root, tmp .. "/stood.out", { "--show-output" })
  assert(not stood:find("value=42", 1, true), stood)
  assert(stood:find("test: show-output: 2 tests stood and so printed nothing; --all runs them", 1, true),
    stood)

  local shown = invoke(root, tmp .. "/shown.out", { "--all", "--show-output" })
  local passing = beneath(shown, "test: PASS  suite.chatty_test test_prints_values")
  assert(passing:find("\n  | value=42\n  | second line", 1, true), passing)
  assert(not shown:find("test: PASS  suite.chatty_test test_prints_nothing", 1, true), shown)
  assert(shown:find("test: FAIL  suite.chatty_test test_prints_and_fails", 1, true), shown)
  assert(shown:find("  | before the failure", 1, true), shown)
  assert(not shown:find("show-output: ", 1, true), shown)

  -- The verdicts it kept are the plain run's: a run without the flag stands on them too.
  local after = invoke(root, tmp .. "/after.out", { "--show-output" })
  assert(after:find("test: show-output: 2 tests stood and so printed nothing", 1, true), after)
end

--- Named with other flags and on one test, the output is that test's alone.
local function test_show_output_follows_the_tests_chosen(tmp: string)
  local root = project(tmp)
  local shown = invoke(root, tmp .. "/one.out",
    { "--show-output", "--all", "suite/chatty_test.tl:test_prints_values" })
  assert(shown:find("  | value=42", 1, true), shown)
  assert(not shown:find("before the failure", 1, true), shown)
  assert(shown:find("1 test passed", 1, true), shown)
end
