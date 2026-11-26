--- [`cosmic.fake`] in a project of its own: a fake whose main requires a
--- module of the standard library carries that module, so the fake runs.
--- In cosmic's own tree the library's modules are the tree's, and the
--- edges to them were always kept; a project's were dropped, as the
--- library is no module the project plans, and its fakes failed at start
--- with "module 'cosmic.clock' not found".

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which this test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The fake's main: it reads the clock, which only the library holds.
local main = table.concat({
  "local Clock = require(\"cosmic.clock\")",
  "",
  "return function(_: {string}): integer",
  "  local _ = Clock.monotonic_ns()",
  "  print(\"ran\")",
  "  return 0",
  "end",
  "",
}, "\n")

--- The test of the project: it builds the fake and runs it.
local suite = table.concat({
  "local Child = require(\"cosmic.child\")",
  "local Clock = require(\"cosmic.clock\")",
  "local Fake = require(\"cosmic.fake\")",
  "local _ = require(\"clock_fake\")",
  "",
  "local function test_a_fake_that_reads_the_clock_runs(tmp: string)",
  "  local program = assert(Fake.build(tmp .. \"/fake\", \"clock_fake\"))",
  "  local ran = assert(Child.run({ program }, { stdout = \"capture\", stderr = \"capture\",",
  "    timeout_ns = Clock.seconds(30) }))",
  "  assert(ran.code == 0 and ran.stdout == \"ran\\n\", tostring(ran.stderr))",
  "end",
  "",
}, "\n")

--- Runs the program with `words` in `root`, unsandboxed (a sandbox nested
--- in this test's own may be refused where the host nests only two deep),
--- and returns what it said.
local function invoke(root: string, tmp: string, words: {string}): Child.Result, string
  local output = tmp .. "/out"
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

--- The project's test passes: its fake carries [`cosmic.clock`].
local function test_a_project_fake_carries_the_library_modules_its_main_requires(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/clock_fake.tl", main))
  assert(Fs.write(root .. "/clock_fake_test.tl", suite))
  local ran, text = invoke(root, tmp, { "test" })
  assert(ran.code == 0, text)
  assert(text:find("1 test passed", 1, true) ~= nil, text)
end
