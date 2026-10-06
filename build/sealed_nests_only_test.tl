--- A module that declares `nests` alone (the promise "nest", no profile
--- "cosmic") runs on a sealed database of its closure too: a worker that
--- the runner marks as held (build.confine's `held_variable`) and that runs
--- on none fails the test; an unmarked worker on none is skipped.
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local confine = require("build.confine")

Test.policy{ promises = { "nest" } }

local function test_a_worker_that_only_nests_runs_on_a_sealed_database()
  local relaunch = Proc.relaunch()
  local on_database = relaunch ~= nil and relaunch.argv[2] == "--database"
  if Env.get(confine.held_variable) ~= nil then
    assert(on_database, "a sandboxed worker that only nests was not given a sealed database")
  end
  if not on_database then Test.skip("this worker does not run on a sealed database") end
  assert(Store.source("cosmic.zip") == nil, "a module outside the closure is in the program")
  assert(Store.bytecode("cosmic.store") ~= nil, "a module of the closure is not")
end
