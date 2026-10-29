--- `cosmic test --check-types` end to end for the facts of the new checker: a project's source is read, checked and written
--- by the new checker (`COSMIC_GRAMMAR=new`), each read of a place a test narrowed is wrapped in a call of `__fact`
--- ([`lang.fact_wraps`]), and the tool's worker runs the tests with the hook that checks them. A narrowing that is false at
--- run time is reported at its read in the summary and in the working database's `type_violations`, as kind "fact"; a
--- correct program reports nothing. The narrowing is made false by a lying declaration: `liar.d.tl` declares the union of
--- records a function answers, and `liar.tl` answers a record of another kind, which no program of the checker's grammar
--- can do by a cast.
---
--- The project is compiled by the tool the test starts, in the new mode whatever the mode of the suite that runs this test.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local Pipeline = require("build.pipeline")
local build_paths = require("build.paths")
local this_program = require("build.this_program")

--- The program itself, which this test starts; it carries the declarations of the standard library.
Test.policy{ profiles = { "cosmic" }, grants = {
  { path = "o/bin", letters = "rx" },
  { path = "testdata/fuzz/checker-sound", letters = "r" },
} }

--- The module that lies: `liar.d.tl` declares a circle or a square, which a caller tells apart by the tag `kind`, where
--- `liar.tl` answers a line, whose tag is neither.
local LIAR_DECLARATION <const> = table.concat({
  "local enum Circle_kind \"circle\" end",
  "local enum Square_kind \"square\" end",
  "local record Circle",
  "  kind: Circle_kind",
  "  radius: integer",
  "end",
  "local record Square",
  "  kind: Square_kind",
  "  side: integer",
  "end",
  "local type Shape = Circle | Square",
  "local record Liar",
  "  shape: function(): Shape",
  "end",
  "return Liar",
  "",
}, "\n")

--- The module that answers what `liar.d.tl` does not declare.
local LIAR <const> = table.concat({
  "local enum Line_kind \"line\" end",
  "local record Line",
  "  kind: Line_kind",
  "  length: integer",
  "end",
  "local record Honest",
  "  shape: function(): Line",
  "end",
  "local honest: Honest = {",
  "  shape = function(): Line return { kind = \"line\", length = 5 } end,",
  "}",
  "return honest",
  "",
}, "\n")

--- The module under test: `read` takes nil out of `x` with an `assert` and returns it; the checker takes the `assert`
--- for what it is. `sound` takes nil out with a test. `area` takes the circle out of the shape with a test of its tag,
--- and reads the shape as a square: a read that is false where `liar` answers a line.
local LIB <const> = table.concat({
  "local Liar = require(\"liar\")",
  "",
  "local record Lib",
  "  read: function(string?): string",
  "  sound: function(string?): string",
  "  area: function(): integer",
  "end",
  "",
  "local lib: Lib = {",
  "  read = function(x: string?): string",
  "    assert(x)",
  "    return x",
  "  end,",
  "  sound = function(x: string?): string",
  "    if x == nil then",
  "      return \"none\"",
  "    end",
  "    return x",
  "  end,",
  "  area = function(): integer",
  "    local shape = Liar.shape()",
  "    if shape.kind == \"circle\" then",
  "      return shape.radius",
  "    end",
  "    return shape.side",
  "  end,",
  "}",
  "return lib",
  "",
}, "\n")

--- The tests of the project: a sound read passes, and a read of the shape as a square, after a test that took the circle
--- out of it, is found where it is false.
local SUITE <const> = table.concat({
  "local Lib = require(\"lib\")",
  "",
  "local function test_a_sound_read_passes()",
  "  assert(Lib.sound(\"a\") == \"a\" and Lib.sound(nil) == \"none\")",
  "  assert(Lib.read(\"b\") == \"b\")",
  "end",
  "",
  "local function test_an_unsound_read_is_found()",
  "  local ok, message = pcall(Lib.area)",
  "  assert(not ok and tostring(message):find(\"fact violated at lib.tl:\", 1, true) ~= nil, tostring(message))",
  "end",
  "",
}, "\n")

--- The project under `tmp`.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/liar.d.tl", LIAR_DECLARATION))
  assert(Fs.write(root .. "/liar.tl", LIAR))
  assert(Fs.write(root .. "/lib.tl", LIB))
  assert(Fs.write(root .. "/facts_test.tl", SUITE))
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

--- The place in `LIB` of the read of `shape` the fact is about: "line:column".
local function read_site(): string
  local line = 0
  for each in (LIB .. "\n"):gmatch("([^\n]*)\n") do
    line = line + 1
    local at = each:find("return shape.side", 1, true)
    if at ~= nil then return tostring(line) .. ":" .. tostring(at + 7) end
  end
  error("no such line")
end

local function test_a_checked_run_reports_the_fact_that_is_false(tmp: string)
  local root = project(tmp)
  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok, text)
  assert(text:find("test: 2 tests passed in ", 1, true) ~= nil, text)
  assert(text:find("run-time types: 1 violation, 1 distinct, at 1 place", 1, true) ~= nil, text)
  assert(text:find("lib.tl:" .. read_site() .. ": shape declared kind one of square got a table whose kind is " ..
      "string \"line\" (1 time)", 1, true) ~= nil, text)

  local rows = violations(root)
  assert(#rows == 1, tostring(#rows) .. " rows")
  local row = assert(rows[1])
  assert(table.concat(row:texts(), " | ") == "fact | lib.tl:" .. read_site() ..
      " | shape | kind one of square | a table whose kind is string \"line\" | 1", table.concat(row:texts(), " | "))
  -- the module the run was made of carries the wrap of the read `assert` narrowed too
  local aside = assert(Fs.read(assert(build_paths.directory(root)) .. "/cosmic.checked.db"))
  assert(aside:find("__fact", 1, true) ~= nil, "the checked projection carries no wrap")
end

--- What a drawn program leaves unused of its header, read, so that the tool, which refuses a warning, takes it, and the
--- module's export: the program is run by `run` and not as the module loads, so that a test can catch a failed `assert`.
local FOOTER <const> = table.concat({
  "local _nums, _opts = nums, opts",
  "local _maybe, _pick, _touch, _id = maybe, pick, touch, id",
  "local _r, _s, _st = r, s, st",
  "local record Drawn",
  "  run: function(): integer",
  "end",
  "local drawn: Drawn = { run = main }",
  "return drawn",
  "",
}, "\n")

--- The text of the drawn program `adapted` as a module of the project.
local function module_of(adapted: string): string
  return (adapted:gsub("local _ = main%(%)\n$", "")) .. FOOTER
end

--- Writes into `root` the programs of the soundness property for narrowing (`testdata/fuzz/checker-sound`, which the
--- flow's fuzz property in [`lang.check_flow_fuzz_test`] draws from too) that the new checker takes, as the text the
--- tool reads, each a module `draw<N>`; at most `most`. The lines of the test that loads them (their `require`s and the calls
--- of `run`), and how many.
local function write_drawn(root: string, most: integer): string, string, integer
  local options = assert(Pipeline.alone())
  local dir = "testdata/fuzz/checker-sound"
  -- sorted: the same programs in every checkout
  local names = assert(Fs.list(dir))
  local requires, calls = "", ""
  local count = 0
  for _, name in ipairs(names) do
    local drawn = assert(Fs.read(dir .. "/" .. name))
    local module = "draw" .. tostring(count + 1)
    if count < most and Pipeline.lone(module .. ".tl", module_of(drawn), options) ~= nil then
      assert(Fs.write(root .. "/" .. module .. ".tl", module_of(drawn)))
      requires = requires .. "local " .. module .. " = require(\"" .. module .. "\")\n"
      calls = calls .. "  run_one(\"" .. module .. "\", " .. module .. ".run)\n"
      count = count + 1
    end
  end
  return requires, calls, count
end

--- The programs the checker took, compiled by the tool with the facts of the new checker wrapped, run where the tool's
--- worker holds the hook: none breaks a fact, which the property of the flow holds on the Lua [`lang.check_programs`]
--- writes and this holds on the Lua the build writes.
local function test_the_programs_the_flows_property_draws_break_no_fact_when_the_tool_compiles_them(tmp: string)
  local root = tmp .. "/drawn"
  assert(Fs.mkdirs(root))
  local requires, calls, count = write_drawn(root, 5)
  assert(count >= 4, "the checker takes " .. tostring(count) .. " of the corpus")
  assert(Fs.write(root .. "/drawn_test.tl", requires .. table.concat({
    "",
    "local function run_one(name: string, run: function(): integer)",
    "  local ok, message = pcall(run)",
    "  assert(ok or tostring(message):find(\"assertion failed\", 1, true) ~= nil, name .. \": \" .. tostring(message))",
    "end",
    "",
    "local function test_each_drawn_program_runs_to_its_end_or_to_an_assert_that_failed()",
    calls .. "end",
    "",
  }, "\n")))
  local checked, text = invoke(root, tmp, { "test", "--check-types" })
  assert(checked.ok, text)
  assert(text:find("test: 1 test passed in ", 1, true) ~= nil, text)
  for _, row in ipairs(violations(root)) do
    assert(row:text(1) ~= "fact", table.concat(row:texts(), " | "))
  end
  -- the modules the run was made of carry the wraps
  local aside = assert(Fs.read(assert(build_paths.directory(root)) .. "/cosmic.checked.db"))
  assert(aside:find("__fact", 1, true) ~= nil, "the checked projection carries no wrap")
end
