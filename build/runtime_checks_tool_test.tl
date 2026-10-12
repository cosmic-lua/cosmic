--- `cosmic test --check-types` end to end, in a project of its own: it reports
--- the value that crossed a typed boundary as a kind its type does not
--- admit, at the caller's line, in the summary and in the working
--- database, and changes no verdict; and neither it nor the variable that
--- asks for it puts a check into what `cosmic build` writes.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local this_program = require("build.this_program")

--- The program itself, which this test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local greeting = table.concat({
  "local record greet",
  "end",
  "",
  "function greet.hello(name: string): string",
  "  return \"hello, \" .. (name or \"?\")",
  "end",
  "",
  "return greet",
  "",
}, "\n")

local suite = table.concat({
  "local greet = require(\"greet\")",
  "",
  "local function test_hello_with_nothing()",
  "  local names: {string:string} = {}",
  "  assert(greet.hello(names.nobody) == \"hello, ?\")",
  "end",
  "",
  "local function test_hello_with_a_name()",
  "  assert(greet.hello(\"you\") == \"hello, you\")",
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

--- The line of `suite` the call of `hello` with nothing is on.
local function nothing_line(): integer
  local line = 0
  for each in (suite .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    if each:find("greet.hello(names.nobody)", 1, true) then return line end
  end
  error("no such line")
end

--- A checked run reports the nil given the parameter, at the line of the
--- call, and passes the tests it passes without it; a run without the
--- flag says nothing of types.
local function test_a_checked_run_reports_a_nil_parameter_and_changes_no_verdict(tmp: string)
  local root = project(tmp)
  local plain, plain_text = invoke(root, tmp, { "test", "--all" })
  assert(plain.ok and plain_text:find("test: 2 tests passed in ", 1, true), plain_text)
  assert(not plain_text:find("run-time types", 1, true), "an unchecked run reported types")

  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok and text:find("test: 2 tests passed in ", 1, true), text)
  assert(text:find("run-time types: 1 violation, 1 distinct, at 1 place", 1, true), text)
  assert(text:find("greet_test.tl:" .. nothing_line() .. ": parameter name of hello " ..
      "(greet.tl:4) declared string got nil (1 time)", 1, true), text)
  assert(text:find("2 ran, 0 stood", 1, true), "a standing verdict hid a test from the report: " .. text)

  local rows = violations(root)
  assert(#rows == 1, #rows .. " rows")
  assert(rows[1]:text(1) == "parameter" and rows[1]:text(2) == "greet_test.tl:" .. nothing_line() and
      rows[1]:text(3) == "parameter name of hello (greet.tl:4)" and rows[1]:text(4) == "string" and
      rows[1]:text(5) == "nil" and rows[1]:text(6) == "1", table.concat(rows[1]:texts(), " | "))

  -- The same variable asks for the same.
  local variable, variable_text = invoke(root, tmp, { "test" }, { COSMIC_TEST_CHECK_TYPES = "1" })
  assert(variable.ok and variable_text:find("run-time types: 1 violation", 1, true), variable_text)
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
  local aside = assert(Fs.read(directory .. "/cosmic.checked.db"))
  assert(aside:find("__cosmic_tc", 1, true), "the checked projection carries no check")

  local built, built_text = invoke(root, tmp, { "build", "--host" },
    { COSMIC_TEST_CHECK_TYPES = "1" })
  assert(built.ok, built_text)
  local executable = assert(Fs.read(directory .. "/bin/hello"))
  assert(executable:find("hello, ", 1, true), "the executable does not carry the program's code")
  assert(not executable:find("__cosmic_tc", 1, true), "an executable carries a run-time check")
  local projection = assert(Fs.read(directory .. "/cosmic.db"))
  assert(not projection:find("__cosmic_tc", 1, true), "the tree's projection carries a check")
  assert(projection:find("greet", 1, true))
end
