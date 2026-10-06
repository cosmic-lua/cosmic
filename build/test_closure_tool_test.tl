--- The cases of build/test_closure_test.tl that run `cosmic test` on a
--- project of their own, whose worker holds its tests' `require` to
--- their closure and is given the store of it. They declare `tool`
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

--- In a project of its own, a test that requires its helper by a
--- computed name fails, naming it; one that requires it by a literal
--- name passes, and so does a computed require of the standard
--- library, which the binary carries rather than the project's tree.
local function test_a_project_test_requiring_outside_its_closure_fails(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/helper.tl", "return { answer = 42 }\n"))
  assert(Fs.write(root .. "/suite/static_test.tl", table.concat({
    'local helper = require("suite.helper")',
    "local function test_static()",
    "  assert(helper.answer == 42)",
    "end",
  }, "\n") .. "\n"))
  assert(Fs.write(root .. "/suite/dynamic_test.tl", table.concat({
    'local name = "suite." .. "helper"',
    "local function test_dynamic()",
    "  local helper: any = require(name)",
    "  assert(helper ~= nil)",
    "end",
    "local function test_standard_library()",
    '  local json: any = require("cosmic." .. "json")',
    "  assert(json ~= nil)",
    "end",
  }, "\n") .. "\n"))
  local ok, text = run(root, tmp .. "/run.out")
  assert(not ok, text)
  assert(text:find("test: FAIL  suite.dynamic_test test_dynamic: suite.dynamic_test:3: " ..
      "module 'suite.helper' is outside the import closure of suite.dynamic_test", 1, true), text)
  assert(text:find("(1 of 3 failed", 1, true), text)
end

--- In a project of its own, a test that reads its helper through the
--- store by hand -- its bytecode, or a searcher called itself --
--- rather than by `require` fails, since the store its worker is given
--- holds its closure alone, whether its module declares `tool` or not;
--- one whose module declares `store`, whose key holds the whole
--- projection, reads it.
local function test_a_project_test_reading_the_store_outside_its_closure_needs_store(
    tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/helper.tl", "return { answer = 42 }\n"))
  local reads = table.concat({
    'local Store = require("cosmic.store")',
    "local function test_bytecode()",
    '  local bytes, why = Store.bytecode("suite.helper")',
    "  assert(bytes ~= nil, why)",
    "end",
    "local function test_searcher()",
    "  local said = ''",
    "  for _, searcher in ipairs(package.searchers as {function(string): any, any}) do",
    '    local loader, extra = searcher("suite.helper")',
    "    if loader is function(string, any): any then",
    "      -- The worker's own gate on `require` raises; a searcher called by hand does not.",
    '      local loaded, helper = pcall(loader, "suite.helper", extra)',
    "      if loaded and helper is {string:integer} and helper.answer == 42 then assert(true, 'a searcher called by hand found the helper'); return end",
    "    elseif loader is string then",
    "      said = said .. loader",
    "    end",
    "  end",
    "  error(said)",
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
    for _, name in ipairs({ "test_bytecode", "test_searcher" }) do
      assert(text:find("test: FAIL  suite." .. module .. " " .. name .. ": ", 1, true), text)
    end
    assert(text:find("no module 'suite.helper' in the store", 1, true), text)
  end
  assert(not text:find("suite.whole_test", 1, true), text)
  assert(text:find("(4 of 6 failed", 1, true), text)
end
