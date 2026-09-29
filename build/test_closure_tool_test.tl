--- The cases of build/test_closure_test.tl that run `cosmic test` on a
--- project of their own, whose worker holds its tests' `require` and
--- store to their closure. They declare `tool` because they start this
--- program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its tests start.
Test.needs{ tool = true }

--- Runs `cosmic test` on `root`, answering whether it passed and what
--- it printed. Its workers run unsandboxed (`COSMIC_TEST_SANDBOX=0`):
--- the worker holds `require` and the store to the closure sandboxed or
--- not, and a sandbox nested in this test's own is one a host may
--- refuse (root nests one only two deep, where its runner cannot run
--- its workers as a user of their own), so the run means the same
--- everywhere.
local function run(root: string, output: string): boolean, string
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
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
--- rather than by `require` fails, naming `store`, whether its module
--- declares `tool` or not; one whose module declares `store`, whose key
--- holds the whole projection, reads it.
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
    "      -- The worker's own gate on `require` raises; the store's does not.",
    '      local loaded, helper = pcall(loader, "suite.helper", extra)',
    "      if loaded and helper is {string:integer} and helper.answer == 42 then return end",
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
    "Test.needs{ store = true }",
  }, "\n") .. "\n" .. reads))
  -- `tool` gives the program, not the rest of the store.
  assert(Fs.write(root .. "/suite/tool_test.tl", table.concat({
    'local Test = require("cosmic.test")',
    "Test.needs{ tool = true }",
  }, "\n") .. "\n" .. reads))
  local ok, text = run(root, tmp .. "/run.out")
  assert(not ok, text)
  for _, module in ipairs({ "held_test", "tool_test" }) do
    for _, name in ipairs({ "test_bytecode", "test_searcher" }) do
      assert(text:find("test: FAIL  suite." .. module .. " " .. name .. ": ", 1, true), text)
    end
    assert(text:find("module 'suite.helper' is held from the store: suite." .. module .. "'s " ..
      "verdict is keyed by what the store holds of its import closure alone", 1, true), text)
  end
  assert(text:find("declare store = true in its Test.needs", 1, true), text)
  assert(not text:find("suite.whole_test", 1, true), text)
  assert(text:find("(4 of 6 failed", 1, true), text)
end

--- A finalizer a test leaves runs after it -- whenever the worker
--- allocates, and as the process closes after its report -- and the
--- store's hold is up still: a module outside the closure it reads
--- then is none of the store's, so it can neither read the module nor
--- spoil the verdict for having read it.
local function test_a_finalizer_a_test_leaves_reads_nothing_outside_its_closure(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/helper.tl", "return { answer = 42 }\n"))
  assert(Fs.write(root .. "/suite/finalizer_test.tl", table.concat({
    'local Store = require("cosmic.store")',
    'local sys = require("cosmic.sys")',
    "local function test_leaves_a_finalizer()",
    "  local cg = collectgarbage as function(string, ? integer, ? integer): any",
    '  pcall(cg, "incremental", 0, 100)',
    "  local done = false",
    "  local function arm()",
    "    setmetatable({} as {string:any}, { __gc = function(_: {string:any})",
    "      if done then return end",
    '      local bytes, _ = Store.bytecode("suite.helper")',
    "      if bytes ~= nil then",
    "        done = true",
    '        sys.write(3, "spoiled\\n")',
    "        sys.exit(1)",
    "      end",
    "      arm()",
    "    end } as metatable<{string:any}>)",
    "  end",
    "  arm()",
    "end",
  }, "\n") .. "\n"))
  local ok, text = run(root, tmp .. "/run.out")
  assert(ok, text)
  assert(text:find("(1 test, 1 module; 1 ran", 1, true), text)
end
