--- A worker whose module declares `nests` (the promise "nest") and neither `store` nor
--- `tool` runs on a sealed database of its closure like any other (build/test.tl's
--- `sealed_for`), its policy carrying `nest` beside the `database`: a module
--- beyond the closure is not in the program it reads, and a process it
--- confines in a root of its own starts on that same database and reads no
--- more. A worker the runner marks as held (build.confine's
--- `held_variable`) and that runs on no database fails the test; an
--- unmarked worker on none is skipped.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local confine = require("build.confine")

-- The profile "cosmic" (`lua`) for what `cosmic -e` loads, which the child runs.
-- A worker that nests is held by a root of its own, which only Linux builds
-- and a host may refuse: the module is not applicable off Linux and skipped
-- where the host gives no nest.
Test.policy{ profiles = { "cosmic" }, promises = { "nest" }, requires = { "nest" } }

--- Whether this worker runs on a sealed database ([`sealed`] of
--- build/sealed_worker_test.tl, for a worker that nests).
local function sealed(): Proc.Relaunch | nil
  local relaunch = Proc.relaunch()
  local on_database = relaunch ~= nil and relaunch.argv[2] == "--database"
  if Env.get(confine.held_variable) ~= nil then
    assert(on_database, "a sandboxed worker that nests was not given a sealed database")
  end
  if not on_database then Test.skip("this worker does not run on a sealed database") end
  return relaunch
end

local function test_a_worker_that_nests_runs_on_a_sealed_database()
  if sealed() == nil then return end
  assert(Store.source("cosmic.zip") == nil, "a module outside the closure is in the program")
  assert(Store.bytecode("build.writer") == nil)
  assert(Store.bytecode("cosmic.store") ~= nil, "a module of the closure is not")
end

local function test_a_worker_that_nests_confines_a_child_on_the_same_database()
  local relaunch = sealed()
  if relaunch == nil then return end
  local argv: {string} = {}
  for i, word in ipairs(relaunch.argv) do argv[i] = word end
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = [[
local Store = require("cosmic.store")
assert(Store.source("cosmic.zip") == nil, "a child reads a module outside the closure")
assert(Store.bytecode("cosmic.store") ~= nil)
print("confined")
]]
  -- The child runs the core on the worker's own database, which it reads.
  local reads = confine.itself()
  reads[#reads + 1] = relaunch.argv[3]
  confine.must_confine({ reads = reads })
  local result, trouble = Child.run(argv, { env = relaunch.env, fds = relaunch.fds,
    stdout = "capture", stderr = "capture" })
  confine.confine(nil)
  assert(result ~= nil, tostring(trouble))
  assert(result.code == 0, tostring(result.stderr) .. tostring(result.stdout))
  assert(tostring(result.stdout):find("confined", 1, true), tostring(result.stdout))
end
