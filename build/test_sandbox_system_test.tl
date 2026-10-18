--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl) for a module
--- that declares `system`, and a process such a module's test confines
--- (build.confine's `confine`): the cases of
--- build/test_sandbox_test.tl and build/confine_test.tl
--- that look for the system's own paths, which only a worker given them
--- has to give, and so the ones that declare them themselves, and the
--- count of a plan's grants that holds them (build/test_sandbox_tool_test.tl
--- has the rest of a plan past the most paths). The cases
--- that need a file of the host are in
--- build/test_sandbox_system_confined_test.tl and
--- build/test_sandbox_system_hint_test.tl.

local Fs = require("cosmic.fs")
local test_inputs = require("build.test_inputs")
local test_policy = require("build.test_policy")
local test_sandbox = require("build.test_sandbox")
local Test = require("cosmic.test")
local Sandbox = require("cosmic.sandbox")
local confine = require("build.confine")

--- The system's own paths, which the plan looks for where the host has
--- them, beside what it gives every worker; `nests`, since the plan reads
--- the root a worker's process would confine.
Test.policy{
  profiles = { "system", "cosmic", "proc" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/dev/urandom", letters = "r" } },
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
  for _, dir in ipairs({ root .. "/o", scratch .. "/real" }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.symlink("real", scratch .. "/tmp"))
  assert(Fs.write(root .. "/o/cosmic.db", "x"))
  local inputs: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {},
    network = {}, tool = false, store = false, system = true }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  assert(plan.trouble == "", plan.trouble)
  assert(not holds(assert(plan.sandbox.unveil).reads, "/usr"))
  local policy = assert(test_policy.worker(plan, inputs))
  assert(holds(policy.profiles or {}, "system"))
end

--- Makes `count` files of the closure, half directly beneath `root`/a and
--- half beneath `root`/b; answers them.
local function spread(root: string, count: integer): {string:boolean}
  local files: {string:boolean} = {}
  for i = 1, count do
    local file = string.format("%s/m%03d.tl", i % 2 == 0 and "a" or "b", i)
    assert(Fs.mkdirs(root .. "/" .. Fs.dirname(file)))
    assert(Fs.write(root .. "/" .. file, "return " .. tostring(i)))
    files[file] = true
  end
  return files
end

--- A worker that declares `system` is given the system's paths besides
--- its plan's, which a start counts: a closure that fits without them is
--- given as copies where it does not fit with them.
local function test_a_closure_is_counted_with_the_system_s_paths(tmp: string)
  local profile, why = Sandbox.profile("system")
  if profile == nil then Test.skip("no profile \"system\" here: " .. why) end
  local root, scratch, copies = tmp .. "/root", tmp .. "/scratch", tmp .. "/copies"
  for _, dir in ipairs({ root, scratch .. "/real" }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.symlink("real", scratch .. "/tmp"))
  local bare_inputs: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {},
    network = {}, tool = false, store = false, system = true }
  local bare = assert(test_sandbox.plan(root, scratch, bare_inputs, {}, nil, nil, copies).sandbox.unveil)
  local beside = 0
  for _, grant in ipairs(assert(profile).grants or {}) do
    if not holds(bare.reads, grant.path) then beside = beside + 1 end
  end
  assert(beside >= 2, "the profile \"system\" gives " .. tostring(beside) .. " paths of its own")
  -- One short of the most grants without the system's paths, and past them
  -- with, spread across two directories.
  local count = (confine.unveil_max - 1) - (#bare.reads + #(bare.writes or {})) - 1
  local inputs: test_inputs.Effective = { files = spread(root, count), reads = {}, host = {},
    env = {}, network = {}, tool = false, store = false, system = true }
  local plan = test_sandbox.plan(root, scratch, inputs, {}, nil, nil, copies)
  assert(plan.trouble == "" and plan.over == 0, plan.trouble .. " over " .. tostring(plan.over))
  assert(#(plan.copied or {}) > 0, "no copy was made")
  local unveil = assert(plan.sandbox.unveil)
  local grants = #unveil.reads + #(unveil.writes or {}) + beside
  assert(grants <= confine.unveil_max - 1, tostring(grants) .. " grants")
end
