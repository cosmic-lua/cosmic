--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl) for a module
--- that declares `system`, and a process such a module's test confines
--- (build.confine's `confine`): the cases of
--- build/test_sandbox_test.tl and build/confine_test.tl
--- that look for the system's own paths, which only a worker given them
--- has to give, and so the ones that declare them themselves.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local confine = require("build.confine")
local stand_in = require("build.stand_in")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local Test = require("cosmic.test")

--- The system's own paths, which the plan and a confined process look
--- for where the host has them, beside what the plan gives every
--- worker; `nests`, since a process it confines has a root of its own;
--- and `tool`: the plan finds this program's core, and a process
--- confined is given the program (the TODO above build.confine's
--- `forbid_running`).
Test.needs{
  host = { "/dev/urandom", "/proc" },
  tool = true,
  nests = true,
  system = true,
}

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- A worker whose module declares `system` is given the system's own
--- paths at their own names.
local function test_a_plan_for_a_module_that_declares_system_gives_the_system_s_paths(tmp: string)
  local root, scratch = tmp .. "/root", tmp .. "/scratch"
  -- Laid out as build.test's `scratch` lays one out, which a plan run
  -- as root hands to the worker's user.
  for _, dir in ipairs({ root .. "/o", scratch .. "/real" }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.symlink("real", scratch .. "/tmp"))
  assert(Fs.write(root .. "/o/cosmic.db", "x"))
  local inputs: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {},
    network = {}, tool = false, store = false, system = true }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  assert(plan.trouble == "", plan.trouble)
  assert(holds(plan.sandbox.unveil.reads, "/usr"))
  assert(plan.sandbox.unveil.at["/usr"] == nil)
end

--- A process a test confines is given the system's own paths beside
--- what the test declared, where its worker has them -- here, since this
--- module declares `system`. Where the kernel cannot confine it, it runs
--- unconfined, and sees /usr all the same.
local function test_a_confined_process_is_given_the_system_s_paths(tmp: string)
  if Fs.exists("/usr") ~= true then return end -- no /usr to give
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own))
  local code: integer = nil
  local ran = confine.call(function()
    confine.confine({ reads = { probe } })
    local r = assert(Child.run({ probe, "present /usr || exit 3" }, { env = {} }))
    confine.confine(nil)
    code = r.code
  end, nil, { own })
  assert(ran.ok, tostring(ran.produced))
  assert(code == 0, "the process did not see /usr: " .. tostring(code))
end
