--- The cases of build/test_closure_test.tl that run `cosmic test` on a
--- project of their own, whose worker is given the store of its tests' closure. They declare `tool`
--- because they start this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- Runs `cosmic test` on `root`, answering whether it passed and what
--- it printed. Its workers run unsandboxed (`COSMIC_TEST_SANDBOX=0`):
--- the worker holds `require` to the closure sandboxed or not, and
--- attaches the store of the closure in the projection's place, as a
--- sandbox gives it. A sandbox nested in this test's own is one a host
--- may refuse (root nests one only two deep, where its runner cannot
--- run its workers as a user of their own), so the run means the same
--- everywhere.
local function run(root: string, output: string): boolean, string
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return result.ok, text
end

--- The helper module of the projects below.
local HELPER <const> = "local record helper\n  answer: integer\nend\nlocal h: helper = { answer = 42 }\nreturn h\n"

--- In a project of its own, a test that probes its helper with `pcall(require, "<name>")` finds it: the probe is an import
--- as a `require` is, so the helper is in the test's closure and its worker is given it.
local function test_a_project_test_probing_a_module_with_pcall_has_it_in_its_closure(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/helper.tl", HELPER))
  assert(Fs.write(root .. "/suite/probe_test.tl", table.concat({
    "local function test_probe()",
    '  local found, helper = pcall(require, "suite.helper")',
    "  assert(found, tostring(helper))",
    '  assert(type(helper) == "table")',
    "end",
  }, "\n") .. "\n"))
  local ok, text = run(root, tmp .. "/run.out")
  assert(ok, text)
end

--- In a project of its own, a test that reads its helper through the store by hand, its bytecode, rather than by
--- `require` fails, since the store its worker is given holds its closure alone, whether its module declares `tool` or
--- not; one whose module declares `store`, whose key holds the whole projection, reads its bytecode. (A computed
--- `require` and a searcher called by hand are no program of a project: the checker refuses the one and the other
--- reads `package`; [`build/test_closure_test.tl`] holds the worker's `require` to the closure in the tree.)
local function test_a_project_test_reading_the_store_outside_its_closure_needs_store(
    tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/helper.tl", HELPER))
  local reads = table.concat({
    'local Store = require("cosmic.store")',
    "local function test_bytecode()",
    '  local bytes, why = Store.bytecode("suite.helper")',
    "  assert(bytes ~= nil, why)",
    "end",
  }, "\n") .. "\n"
  assert(Fs.write(root .. "/suite/held_test.tl", reads))
  assert(Fs.write(root .. "/suite/whole_test.tl", table.concat({
    'local Test = require("cosmic.test")',
    'Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }',
  }, "\n") .. "\n" .. reads))
  -- `tool` gives the program, not the rest of the store.
  assert(Fs.write(root .. "/suite/tool_test.tl", table.concat({
    'local Test = require("cosmic.test")',
    'Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }',
  }, "\n") .. "\n" .. reads))
  local ok, text = run(root, tmp .. "/run.out")
  assert(not ok, text)
  for _, module in ipairs({ "held_test", "tool_test" }) do
    assert(text:find("test: FAIL  suite." .. module .. " test_bytecode: ", 1, true), text)
    assert(text:find("no module 'suite.helper' in the store", 1, true), text)
  end
  assert(not text:find("suite.whole_test test_bytecode", 1, true), text)
  assert(text:find("2 of 3 tests failed", 1, true), text)
end
