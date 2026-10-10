--- A file above the project root (`/parent/<file>` in [`Test.policy`]), end to
--- end: a `cosmic test` run on a suite whose tree lies in a directory of
--- its own reads the file beside the tree through [`Test.parent`], sandboxed
--- at a fixed place and unsandboxed in the real parent directory, and a
--- file the host lacks fails the module's tests. They start this program, so
--- they declare `tool`, and `nests` for the workers of that run, as
--- build/test_sandbox_run_tool_test.tl does.

local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local confine = require("build.confine")
local fixture = require("build.test_sandbox_fixture")
local Test = require("cosmic.test")

Test.policy{
  profiles = { "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/dev/urandom", letters = "r" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  requires = { "nest" },
}

--- Writes `root`/suite/up_test.tl, whose one test grants `/parent/up.txt`
--- and fails with `read|<path Test.parent gives>|<its contents>|<whether a
--- path never declared raises>|end`.
local function up_suite(root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/up_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "/parent/up.txt", letters = "r" } } }

local function test_read()
  local path = Test.parent("up.txt")
  local ok, _ = pcall(Test.parent, "other.txt")
  error("read|" .. path .. "|" .. tostring((Fs.read(path))) .. "|" .. tostring(ok) .. "|end")
end
]]))
end

--- The environment of a run: nothing shared, every test run.
local function run_environment(sandbox: string | nil): {string:string}
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_SANDBOX = sandbox
  return env
end

--- Sandboxed, the worker reads the file at /tree-up beside /tree and only
--- that file of the parent directory; unsandboxed, it reads it in the real
--- parent directory. A file the host lacks fails the module's tests,
--- naming it, in either mode.
local function test_a_worker_reads_a_file_above_the_project_through_parent(tmp: string)
  local base = assert(Fs.absolute(tmp))
  local root = base .. "/root"
  up_suite(root)
  assert(Fs.write(base .. "/up.txt", "above"))
  assert(Fs.write(base .. "/sibling.txt", "beside"))
  local ran = fixture.run(root, base .. "/sandboxed", run_environment(nil))
  if ran.text:find("no worker can be sandboxed here", 1, true) ~= nil then
    Test.skip(confine.unsandboxed_reason(ran.text))
  end
  assert(not ran.ok and ran.text:find("read|/tree-up/up.txt|above|false|end", 1, true),
    ran.text)
  local plain = fixture.run(root, base .. "/plain", run_environment("0"))
  assert(not plain.ok and plain.text:find("read|" .. base .. "/root/../up.txt|above|false|end", 1, true),
    plain.text)
  assert(Fs.remove(base .. "/up.txt"))
  for _, mode in ipairs({ "0", "" }) do
    local lacking = fixture.run(root, base .. "/lacking" .. mode, run_environment(mode ~= "" and mode or nil))
    assert(not lacking.ok and lacking.text:find("grant of /parent/up.txt", 1, true) and
        lacking.text:find("is not there", 1, true) and not lacking.text:find("read|", 1, true),
      lacking.text)
  end
end
