--- `cosmic test --check-types` end to end, in a project of its own: it reports a value of another kind than a parameter
--- declares, at its caller, in the summary and in the working database, and changes no verdict (a project outside
--- cosmic/); and neither it nor the variable that asks for it puts a check into what `cosmic build` writes.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local artifact = require("build.artifact")
local build_paths = require("build.paths")
local this_program = require("build.this_program")

--- The program itself, which this test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Whether a module of the database file at `path` holds `needle` in its bytecode, which the database stores
--- deflated: the file's own bytes show none of it.
local function carries(path: string, needle: string): boolean
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT count(*) FROM modules WHERE instr(inflate(bytecode), CAST(?1 AS BLOB)) > 0", { { text = needle } }))
  assert(db:close())
  return assert(rows[1]):text(1) ~= "0"
end

--- The module under test: `hello` takes nil out of `name` with an `assert`, and the checker takes the `assert` for what it
--- is, so the read of `name` after it is wrapped in a call of `__fact` in a checked run.
local greeting = table.concat({
  "local record greet",
  "  hello: function(string?): string",
  "end",
  "",
  "local module: greet = {",
  "  hello = function(name: string?): string",
  "    assert(name)",
  "    return name",
  "  end,",
  "}",
  "return module",
  "",
}, "\n")

--- The tests: a call with a name passes, and a call a chunk of Lua text makes with an integer for a string is found where
--- it is made, and passes all the same: the report changes no verdict. A chunk is not checked against the types of the
--- function it is passed, as a library written in C would not be.
local suite = table.concat({
  "local greet = require(\"greet\")",
  "",
  "local function test_hello_with_a_value_of_another_kind()",
  "  local send = assert(load(\"local hello = ...; return hello(42)\", \"=sender\"))",
  "  assert(tostring(send(greet.hello)) == \"42\")",
  "end",
  "",
  "local function test_hello_with_a_name()",
  "  assert(greet.hello(\"you\") == \"you\")",
  "end",
  "",
}, "\n")

local main = table.concat({
  "local greet = require(\"greet\")",
  "",
  "return function(argv: {string}): integer",
  "  print(greet.hello(argv[1]))",
  "  return 0",
  "end",
  "",
}, "\n")

--- The project under `tmp`.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/cmd/hello"))
  assert(Fs.write(root .. "/greet.tl", greeting))
  assert(Fs.write(root .. "/greet_test.tl", suite))
  assert(Fs.write(root .. "/cmd/hello/main.tl", main))
  return root
end

--- Runs the program with `words` in `root`, unsandboxed (a sandbox nested
--- in this test's own may be refused where the host nests only two deep),
--- with `extra` added to its environment, and answers what it said.
local function invoke(root: string, tmp: string, words: {string}, extra?: {string:string}):
    Child.Result, string
  local output = tmp .. "/out." .. tostring(Clock.monotonic_ns())
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  env.TMPDIR = tmp
  for name, value in pairs(extra or {}) do env[name] = value end
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

--- A checked run reports the parameter that is false, at its caller, and passes the tests it passes without it; a run
--- without the flag says nothing of types.
local function test_a_checked_run_reports_a_false_value_and_changes_no_verdict(tmp: string)
  local root = project(tmp)
  local plain, plain_text = invoke(root, tmp, { "test", "--all" })
  assert(plain.ok and plain_text:find("test: 2 tests passed in ", 1, true) ~= nil, plain_text)
  assert(not plain_text:find("run-time types", 1, true), "an unchecked run reported types")

  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok and text:find("test: 2 tests passed in ", 1, true) ~= nil, text)
  assert(text:find("run-time types: 1 violation, 1 distinct, at 1 place", 1, true), text)
  assert(text:find("greet_test.tl:5: parameter name of function (greet.tl:6) declared string|nil got integer (1 time)", 1,
    true), text)
  assert(text:find("2 ran, 0 stood", 1, true), "a standing verdict hid a test from the report: " .. text)

  local rows = violations(root)
  assert(#rows == 1, tostring(#rows) .. " rows")
  assert(table.concat(rows[1]:texts(), " | ") == "parameter | greet_test.tl:5 | parameter name of function (greet.tl:6) | string|nil | integer | 1",
    table.concat(rows[1]:texts(), " | "))

  -- The same variable asks for the same.
  local variable, variable_text = invoke(root, tmp, { "test" }, { COSMIC_TEST_CHECK_TYPES = "1" })
  assert(variable.ok and variable_text:find("run-time types: 1 violation", 1, true) ~= nil, variable_text)
end

--- A second checked run stands on the first's verdicts, but for the test that met a violation: it runs again, so
--- the run reports the violation again and `type_violations` holds it, whatever stood.
local function test_a_second_checked_run_stands_but_for_the_test_that_met_a_violation(tmp: string)
  local root = project(tmp)
  local first, first_text = invoke(root, tmp, { "test", "--check-types" })
  assert(first.ok and first_text:find("2 ran, 0 stood", 1, true) ~= nil, first_text)
  local second, second_text = invoke(root, tmp, { "test", "--check-types" })
  assert(second.ok, second_text)
  assert(second_text:find("1 ran, 1 stood", 1, true) ~= nil, "the clean test did not stand: " .. second_text)
  assert(second_text:find("run-time types: 1 violation, 1 distinct, at 1 place", 1, true) ~= nil,
    "a standing verdict hid the violation: " .. second_text)
  assert(#violations(root) == 1, tostring(#violations(root)) .. " rows")
  -- An unchecked run stands on none of the checked run's verdicts, and a checked run is told apart from it.
  local plain, plain_text = invoke(root, tmp, { "test" })
  assert(plain.ok and plain_text:find("2 ran, 0 stood", 1, true) ~= nil, plain_text)
end

--- A pass that meets a violation where a verdict stood under its key takes the verdict out, as a failure does:
--- the test reads a file it does not declare (an unsandboxed run lets it, and no key holds it), so its outcome
--- moves while its key does not.
local function test_a_pass_that_meets_a_violation_takes_its_verdict_out(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet.tl", greeting))
  local flag = tmp .. "/flag.txt"
  assert(Fs.write(root .. "/flip_test.tl", table.concat({
    "local Fs = require(\"cosmic.fs\")",
    "local greet = require(\"greet\")",
    "",
    "local function test_flip()",
    "  local flag = assert(Fs.read(\"" .. flag .. "\"))",
    "  if flag == \"bad\" then",
    "    local send = assert(load(\"local hello = ...; return hello(42)\", \"=sender\"))",
    "    assert(tostring(send(greet.hello)) == \"42\")",
    "  else",
    "    assert(greet.hello(\"you\") == \"you\")",
    "  end",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(flag, "ok"))
  local first, first_text = invoke(root, tmp, { "test", "--check-types" })
  assert(first.ok and first_text:find("1 ran, 0 stood", 1, true) ~= nil, first_text)
  local stood, stood_text = invoke(root, tmp, { "test", "--check-types" })
  assert(stood.ok and stood_text:find("0 ran, 1 stood", 1, true) ~= nil, stood_text)
  assert(Fs.write(flag, "bad"))
  local met, met_text = invoke(root, tmp, { "test", "--check-types", "--all" })
  assert(met.ok and met_text:find("run-time types: 1 violation", 1, true) ~= nil, met_text)
  assert(Fs.write(flag, "ok"))
  local after, after_text = invoke(root, tmp, { "test", "--check-types" })
  assert(after.ok, after_text)
  assert(after_text:find("1 ran, 0 stood", 1, true) ~= nil,
    "a verdict stood after its test met a violation: " .. after_text)
end

--- A checked run records which test met each violation and says how many tests did: a test that meets one is
--- the cost of standing on checked verdicts, since it never stands.
local function test_a_checked_run_counts_the_tests_that_met_a_violation(tmp: string)
  local root = project(tmp)
  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok, text)
  assert(text:find("run-time types: 1 test met one (", 1, true), text)
  local db = assert(Sqlite.open(assert(build_paths.directory(root)) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db, "SELECT test, kind, count FROM type_violation_tests"))
  assert(db:close())
  assert(#rows == 1, tostring(#rows) .. " rows")
  local row = assert(rows[1]):texts()
  assert(assert(row[1]):find("test_hello_with_a_value_of_another_kind", 1, true) ~= nil, row[1])
  assert(row[2] == "parameter" and row[3] == "1", table.concat(row, " | "))
end

--- Neither a checked run nor the variable that asks for one puts a check
--- into an executable: the tree's projection stays as an unchecked run
--- wrote it, a checked run writes its own beside it, and `cosmic build`
--- carries the first.
local function test_no_executable_carries_a_check(tmp: string)
  local root = project(tmp)
  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok, text)
  local directory = assert(build_paths.directory(root))
  assert(carries(directory .. "/cosmic.checked.db", "__fact"), "the checked projection carries no check")

  local built, built_text = invoke(root, tmp, { "build", "--host" },
    { COSMIC_TEST_CHECK_TYPES = "1" })
  assert(built.ok, built_text)
  local executable = assert(Fs.read(directory .. "/bin/hello"))
  assert(executable:find("hello", 1, true), "the executable does not carry the program's code")
  local parts = assert(artifact.split(executable))
  assert(Fs.write(tmp .. "/hello.db", parts.database))
  assert(carries(tmp .. "/hello.db", "greet"), "the executable's database lacks the program's module")
  assert(not carries(tmp .. "/hello.db", "__fact"), "an executable carries a run-time check")
  assert(not carries(directory .. "/cosmic.db", "__fact"), "the tree's projection carries a check")
  assert(carries(directory .. "/cosmic.db", "greet"))
end
