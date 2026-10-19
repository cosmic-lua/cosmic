--- `cosmic test --check-types` end to end for the facts of the new checker: a project's test runs Lua the new
--- checker's code generator wrote with the wraps of [`lang.fact_wraps`] (the build still compiles with the fork, so the
--- Lua is generated here and carried into the project as text). A narrowing that is false at run time is reported at its
--- read in the summary and in the working database's `type_violations`, as kind "fact", beside the fork's checks; a
--- correct program reports nothing.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local programs = require("build.fact_programs")
local this_program = require("build.this_program")

--- The program itself, which this test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The test of the project: it loads the Lua of a sound program and of one `assert` leaves unsound, and reads each.
local function suite(sound: string, unsound: string): string
  return table.concat({
    "local sound = " .. string.format("%q", sound),
    "local unsound = " .. string.format("%q", unsound),
    "",
    "local record Api",
    "  read: function(string | nil): string",
    "end",
    "",
    "local function loaded(code: string, name: string, lax: boolean): Api",
    "  local env: {string:any} = {}",
    "  if lax then",
    "    env.assert = function(...: any): any...",
    "      return ...",
    "    end",
    "  end",
    "  setmetatable(env, { __index = _G })",
    "  return (assert(load(code, \"=\" .. name, \"t\", env))() as Api)",
    "end",
    "",
    "local function test_a_sound_read_passes()",
    "  local api = loaded(sound, \"sound.tl\", false)",
    "  assert(api.read(\"a\") == \"a\" and api.read(nil) == \"none\")",
    "end",
    "",
    "local function test_an_unsound_read_is_found()",
    "  local api = loaded(unsound, \"unsound_assert.tl\", true)",
    "  local ok, message = pcall(api.read, nil)",
    "  assert(not ok and tostring(message):find(\"fact violated at unsound_assert.tl:3:10: x is nil\", 1, true),",
    "    tostring(message))",
    "end",
    "",
  }, "\n")
end

--- The project under `tmp`.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/facts_test.tl", suite(programs.compiled("sound.tl", programs.sound, true),
    programs.compiled("unsound_assert.tl", programs.unsound_assert, true))))
  return root
end

--- Runs the program with `words` in `root`, unsandboxed (a sandbox nested in this test's own may be refused where the
--- host nests only two deep), and answers what it said.
local function invoke(root: string, tmp: string, words: {string}): Child.Result, string
  local output = tmp .. "/out." .. tostring(Clock.monotonic_ns())
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["TMPDIR"] = tmp
  local started = this_program.program(words, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(120),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return assert(result, trouble), (assert(Fs.read(output)))
end

--- The rows of `type_violations` the project's last checked run kept.
local function violations(root: string): Sqlite.Rows
  local db = assert(Sqlite.open(assert(build_paths.directory(root)) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT kind, site, target, declared, actual, count FROM type_violations ORDER BY site"))
  assert(db:close())
  return rows
end

local function test_a_checked_run_reports_the_fact_that_is_false(tmp: string)
  local root = project(tmp)
  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok, text)
  assert(text:find("test: 2 tests passed in ", 1, true) ~= nil, text)
  assert(text:find("run-time types: 1 violation, 1 distinct, at 1 place", 1, true) ~= nil, text)
  assert(text:find("unsound_assert.tl:3:10: x declared not nil got nil (1 time)", 1, true) ~= nil, text)

  local rows = violations(root)
  assert(#rows == 1, tostring(#rows) .. " rows")
  local row = assert(rows[1])
  assert(table.concat(row:texts(), " | ") == "fact | unsound_assert.tl:3:10 | x | not nil | nil | 1",
    table.concat(row:texts(), " | "))
end

--- What `chunk` prints in a `cosmic` started with `set` among its variables.
local function printed(chunk: string, set: {string: string}): string
  local env = this_program.environment()
  for name, value in pairs(set) do
    env[name] = value
  end
  local started = this_program.program({ "-e", chunk }, {
    env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  return result.stdout or ""
end

-- A wrapped read in a process a test of a checked run starts would otherwise raise "attempt to call a nil value (global
-- '__fact')": only the worker holds the checking hook.
local function test_a_process_a_checked_run_starts_answers_the_value_of_a_wrapped_read()
  local chunk = "print(type(__fact), __fact ~= nil and __fact(41, 'string', 'x') or 'none')"
  assert(printed(chunk, { COSMIC_TEST_TYPES = "1" }) == "function\t41\n", printed(chunk, { COSMIC_TEST_TYPES = "1" }))
  -- no other run has the global
  assert(printed(chunk, {}) == "nil\tnone\n", printed(chunk, {}))
  assert(printed(chunk, { COSMIC_TEST_TYPES = "0" }) == "nil\tnone\n", printed(chunk, { COSMIC_TEST_TYPES = "0" }))
end
