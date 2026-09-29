--- The cases of build/test_audit_test.tl that run `cosmic test --audit`
--- on a project of their own. They declare `tool` because they start
--- this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

--- The program itself, which its tests start.
Test.needs{ tool = true }

--- Runs `cosmic test --audit` on `root`, answering whether it passed and
--- what it printed.
local function audit(root: string, output: string): boolean, string
  local fd = assert(Fs.open_write(output))
  -- Unsandboxed: a sandboxed worker's undeclared read finds nothing,
  -- and fails its test before the audit could name it.
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  local started = this_program.program({ "test", "--audit" }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return result.ok, text
end

--- A project whose test reads its helper's source, which its import
--- closure holds; a file of the tree it declares or not, as `declared`
--- says; and a file that is not there, which no sandbox would show it
--- either.
local function project(root: string, declared: boolean)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/data"))
  assert(Fs.write(root .. "/data/extra.txt", "extra\n"))
  assert(Fs.write(root .. "/suite/helper.tl", "return { answer = 42 }\n"))
  assert(Fs.write(root .. "/suite/reads_test.tl", table.concat({
    'local Fs = require("cosmic.fs")',
    'local helper = require("suite.helper")',
    declared and 'local Test = require("cosmic.test")' or "",
    declared and 'Test.needs { reads = { "data/" } }' or "",
    "local function test_reads()",
    "  assert(helper.answer == 42)",
    '  assert(Fs.read("suite/helper.tl") ~= nil)',
    '  assert(Fs.read("data/extra.txt") == "extra\\n")',
    '  assert(Fs.read("data/missing.txt") == nil)',
    "end",
  }, "\n") .. "\n"))
end

--- The audit fails a run whose test read a file it does not declare,
--- naming it and the declaration that would hold it, and passes once the
--- test declares it.
local function test_an_undeclared_read_fails_the_audit_until_it_is_declared(tmp: string)
  local root = tmp .. "/project"
  project(root, false)
  local ok, text = audit(root, tmp .. "/first.out")
  assert(not ok, text)
  assert(text:find("audit: suite.reads_test (suite/reads_test.tl): 1 of 1 test read " ..
    "what they do not declare\n  test_reads:\n    reads        data/extra.txt\n" ..
    '  declare: Test.needs { reads = { "data/extra.txt" } }\n', 1, true), text)
  assert(not text:find("helper.tl", 1, true) and not text:find("missing", 1, true), text)
  assert(text:find("test: PASS", 1, true), text)
  project(root, true)
  ok, text = audit(root, tmp .. "/second.out")
  assert(ok, text)
  assert(text:find("audit: 1 test read only its inputs\n", 1, true), text)
end

--- A `needs` call the build did not read from the source -- reached
--- another way than a top-level call on a local bound to
--- `require("cosmic.test")` -- fails its module's load when it runs,
--- naming what it was handed and what the build read.
local function test_a_needs_call_the_build_did_not_read_fails_the_load(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/dynamic_test.tl", table.concat({
    'require("cosmic.test").needs { tool = true }',
    "local function test_x() end",
  }, "\n") .. "\n"))
  local ok, text = audit(root, tmp .. "/dynamic.out")
  assert(not ok, text)
  assert(text:find("the module failed to load: its cosmic.test needs call was handed what " ..
    "the build did not read", 1, true), text)
  assert(text:find("  handed:\n    tool true\n  read:\n    nothing", 1, true), text)
end

--- A `needs` call made once the module has loaded -- from inside a test,
--- where the build would refuse one it could see -- fails that test.
local function test_a_needs_call_inside_a_test_fails_it(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/late_test.tl", table.concat({
    "local function test_late()",
    '  require("cosmic.test").needs { tool = true }',
    "end",
  }, "\n") .. "\n"))
  local ok, text = audit(root, tmp .. "/late.out")
  assert(not ok, text)
  assert(text:find("test_late: ", 1, true) and text:find("cosmic.test: needs is called at the " ..
    "top of a test module, while it loads", 1, true), text)
end
