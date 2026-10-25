--- `cosmic test --check-types` end to end, in a project of its own: it reports a fact the checker took from a test that is
--- false at run time, at its read, in the summary and in the working database, and changes no verdict; and neither it nor
--- the variable that asks for it puts a check into what `cosmic build` writes.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local this_program = require("build.this_program")

--- The program itself, which this test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

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

--- The tests: a read with a name passes, and a read after an `assert` that does not raise (the global is replaced by one
--- that answers its arguments, as a program that shadows `assert` would) is found where it is false.
local suite = table.concat({
  "local greet = require(\"greet\")",
  "",
  "local function test_hello_with_nothing()",
  "  local plant = assert(load(\"planted = assert; assert = function(...) return ... end\", \"=plant\"))",
  "  local restore = assert(load(\"assert = planted\", \"=restore\"))",
  "  plant()",
  "  local ok, message = pcall(greet.hello, nil)",
  "  restore()",
  "  assert(ok or tostring(message):find(\"fact violated at greet.tl:\", 1, true) ~= nil, tostring(message))",
  "end",
  "",
  "local function test_hello_with_a_name()",
  "  assert(greet.hello(\"you\") == \"you\")",
  "end",
  "",
}, "\n")

-- (`ok` is true where no hook checks the fact: the read answers nil.)
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

--- The place in `greeting` of the read of `name` the fact is about: "line:column".
local function read_site(): string
  local line = 0
  for each in (greeting .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    local at = each:find("return name", 1, true)
    if at ~= nil then return tostring(line) .. ":" .. tostring(at + 7) end
  end
  error("no such line")
end

--- A checked run reports the read of `name` that is false, at its place, and passes the tests it passes without it; a run
--- without the flag says nothing of types.
local function test_a_checked_run_reports_a_false_fact_and_changes_no_verdict(tmp: string)
  local root = project(tmp)
  local plain, plain_text = invoke(root, tmp, { "test", "--all" })
  assert(plain.ok and plain_text:find("test: 2 tests passed in ", 1, true), plain_text)
  assert(not plain_text:find("run-time types", 1, true), "an unchecked run reported types")

  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok and text:find("test: 2 tests passed in ", 1, true), text)
  assert(text:find("run-time types: 1 violation, 1 distinct, at 1 place", 1, true), text)
  assert(text:find("greet.tl:" .. read_site() .. ": name declared not nil got nil (1 time)", 1, true), text)
  assert(text:find("2 ran, 0 stood", 1, true), "a standing verdict hid a test from the report: " .. text)

  local rows = violations(root)
  assert(#rows == 1, #rows .. " rows")
  assert(table.concat(rows[1]:texts(), " | ") == "fact | greet.tl:" .. read_site() .. " | name | not nil | nil | 1",
    table.concat(rows[1]:texts(), " | "))

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
  assert(aside:find("__fact", 1, true), "the checked projection carries no check")

  local built, built_text = invoke(root, tmp, { "build", "--host" },
    { COSMIC_TEST_CHECK_TYPES = "1" })
  assert(built.ok, built_text)
  local executable = assert(Fs.read(directory .. "/bin/hello"))
  assert(executable:find("hello", 1, true), "the executable does not carry the program's code")
  assert(not executable:find("__fact", 1, true), "an executable carries a run-time check")
  local projection = assert(Fs.read(directory .. "/cosmic.db"))
  assert(not projection:find("__fact", 1, true), "the tree's projection carries a check")
  assert(projection:find("greet", 1, true))
end
