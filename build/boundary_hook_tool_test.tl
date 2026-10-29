--- `cosmic test --check-types` end to end for the declared parameters of a function: a project's source is read, checked
--- and written by the new checker (`COSMIC_GRAMMAR=new`), each function with typed parameters begins with a check of them
--- ([`lang.boundary_checks`]), and the tool's worker runs the tests with the hook that records a value of another kind
--- ([`build.test_worker`]'s `install_checks`). A violation is reported at the line of the caller in the summary and in the working
--- database's `type_violations`, as kind "parameter", and fails nothing, since the project declares it outside cosmic/ (a parameter declared there fails
--- the test, [`build.boundary_hook_test`]); a correct call reports nothing.
---
--- The project is compiled by the tool the test starts, in the new mode whatever the mode of the suite that runs this test.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local this_program = require("build.this_program")

--- The program itself, which this test starts; it carries the declarations of the standard library.
Test.policy{ profiles = { "cosmic" }, grants = {
  { path = "o/bin", letters = "rx" },
} }

--- The module under test: `take` declares a string and an optional integer, `half` an integer, and `loose` an `any` and a
--- variadic, which no check is made of.
local LIB <const> = table.concat({
  "local function take(name: string, count?: integer): string",
  "  return tostring(name) .. tostring(count)",
  "end",
  "",
  "local function half(n: integer): integer",
  "  return n // 2",
  "end",
  "",
  "local function loose(a: any, ...: integer): any",
  "  return a",
  "end",
  "",
  "local record Lib",
  "  take: function(string, count?: integer): string",
  "  half: function(integer): integer",
  "  loose: function(any, ...: integer): any",
  "end",
  "",
  "local lib: Lib = { take = take, half = half, loose = loose }",
  "return lib",
  "",
}, "\n")

--- The module that lies, as the declaration of the tool's own libraries cannot: `liar.d.tl` declares a string and an
--- integer where `liar.tl` answers an integer and a float. A project's callers take their types from the declaration
--- file, and nothing holds the module to it, so the values reach the boundary of a function in the project's own Teal.
local LIAR_DECLARATION <const> = table.concat({
  "local record Liar",
  "  text: function(): string",
  "  count: function(): integer",
  "end",
  "return Liar",
  "",
}, "\n")

--- The module that answers what `liar.d.tl` does not declare.
local LIAR <const> = table.concat({
  "local record Honest",
  "  text: function(): integer",
  "  count: function(): number",
  "end",
  "local honest: Honest = {",
  "  text = function(): integer return 42 end,",
  "  count = function(): number return 1.5 end,",
  "}",
  "return honest",
  "",
}, "\n")

--- The tests of the project: sound calls pass; a call that sends an integer for the string and a float for the integer is
--- one row each at the line of the call, and the functions run on. The values come from `liar`, as a library whose
--- declaration is wrong would send them: a program of the checker's grammar has no cast to send them by.
local SUITE <const> = table.concat({
  "local Liar = require(\"liar\")",
  "local Lib = require(\"lib\")",
  "",
  "local function test_a_sound_call_passes()",
  "  assert(Lib.take(\"a\") == \"anil\" and Lib.take(\"b\", 2) == \"b2\" and Lib.half(7) == 3)",
  "  assert(Lib.loose(\"x\", 1, 2) == \"x\" and Lib.loose(nil) == nil)",
  "end",
  "",
  "local function test_a_value_of_another_kind_is_found_at_the_caller_and_the_function_runs_on()",
  "  local taken = Lib.take(Liar.text())",
  "  assert(taken == \"42nil\", taken)",
  "  local halved = Lib.half(Liar.count())",
  "  assert(halved == 0, tostring(halved))",
  "end",
  "",
}, "\n")

--- The project under `tmp`.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/lib.tl", LIB))
  assert(Fs.write(root .. "/liar.d.tl", LIAR_DECLARATION))
  assert(Fs.write(root .. "/liar.tl", LIAR))
  assert(Fs.write(root .. "/boundary_test.tl", SUITE))
  return root
end

--- Runs the program with `words` in `root`, unsandboxed (a sandbox nested in this test's own may be refused where the
--- host nests only two deep), compiling with the new checker, and answers what it said.
local function invoke(root: string, tmp: string, words: {string}): Child.Result, string
  local output = tmp .. "/out." .. tostring(Clock.monotonic_ns())
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["TMPDIR"] = tmp
  env["COSMIC_GRAMMAR"] = "new"
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

local function test_a_checked_run_reports_the_parameter_that_is_false_at_the_caller(tmp: string)
  local root = project(tmp)
  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok, text)
  assert(text:find("test: 2 tests passed in ", 1, true) ~= nil, text)
  assert(text:find("run-time types: 2 violations, 2 distinct, at 2 places", 1, true) ~= nil, text)

  local rows = violations(root)
  local seen: mut {string} = {}
  for _, row in ipairs(rows) do
    seen[#seen + 1] = table.concat(row:texts(), " | ")
  end
  local want = {
    "parameter | boundary_test.tl:10 | parameter name of take (lib.tl:1) | string | integer | 1",
    "parameter | boundary_test.tl:12 | parameter n of half (lib.tl:5) | integer | float | 1",
  }
  assert(#seen == 2, table.concat(seen, "\n"))
  assert(seen[1] == want[1], seen[1])
  assert(seen[2] == want[2], seen[2])
end

--- An unchecked run writes no check: the same calls report nothing, because the Lua carries no call of the hook.
local function test_an_unchecked_run_carries_no_check(tmp: string)
  local root = project(tmp)
  local plain, text = invoke(root, tmp, { "test" })
  assert(plain.ok, text)
  assert(text:find("run-time types", 1, true) == nil, text)
end
