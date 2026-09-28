--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl) for a module
--- that declares `system`: the plan's case of
--- build/test_sandbox_system_test.tl, whose plan finds this program's
--- core, as it finds it for every worker.

local Fs = require("cosmic.fs")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local Test = require("cosmic.test")

--- The system's own paths, which the plan looks for where the host has
--- them, beside what it gives every worker: the runtime's paths and this
--- program, whose core it finds.
Test.needs{
  host = { "/dev/urandom", "/proc" },
  tool = true,
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
--- paths at their own names, and a process it starts is keyed by them.
local function test_a_plan_for_a_module_that_declares_system_gives_the_system_s_paths(tmp: string)
  local root, scratch = tmp .. "/root", tmp .. "/scratch"
  for _, dir in ipairs({ root .. "/o", scratch }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.write(root .. "/o/cosmic.db", "x"))
  local inputs: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {},
    network = {}, processes = false, tool = false, store = false, system = true }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  assert(holds(plan.held, "/usr") and holds(plan.sandbox.unveil.reads, "/usr"))
  assert(plan.sandbox.unveil.at["/usr"] == nil)
end
