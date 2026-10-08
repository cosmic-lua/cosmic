--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl) for a module
--- that declares `system`, and a process such a module's test confines
--- (build.confine's `confine`): the cases of
--- build/test_sandbox_test.tl and build/confine_test.tl
--- that look for the system's own paths, which only a worker given them
--- has to give, and so the ones that declare them themselves. The cases
--- that need a file of the host are in
--- build/test_sandbox_system_confined_test.tl and
--- build/test_sandbox_system_hint_test.tl.

local Fs = require("cosmic.fs")
local paths = require("build.paths")
local test_inputs = require("build.test_inputs")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local Test = require("cosmic.test")

--- The system's own paths, which the plan looks for where the host has
--- them, beside what it gives every worker; `nests`, since the plan reads
--- the root a worker's process would confine.
Test.policy{
  profiles = { "system", "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/dev/urandom", letters = "r" }, { path = "/proc", letters = "r" } },
  promises = { "nest" },
}

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- A worker whose module declares `system` is given the system's own
--- paths by its policy's profile "system", which is no path of its plan.
local function test_a_module_that_declares_system_is_given_the_system_profile(tmp: string)
  local root, scratch = tmp .. "/root", tmp .. "/scratch"
  -- Laid out as build.test's `scratch` lays one out.
  for _, dir in ipairs({ root, scratch .. "/real" }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.symlink("real", scratch .. "/tmp"))
  assert(Fs.write(assert(paths.prepare(root)) .. "/cosmic.db", "x"))
  local inputs: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {},
    network = {}, tool = false, store = false, system = true }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  assert(plan.trouble == "", plan.trouble)
  assert(not holds(plan.sandbox.unveil.reads, "/usr"))
  local policy = assert(test_policy.worker(plan, inputs))
  assert(holds(policy.profiles or {}, "system"))
end
