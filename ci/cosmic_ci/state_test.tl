local Fs = require("cosmic.fs")
local State = require("cosmic_ci.state")

local function test_external_path_with_top_level_parent(tmp: string)
  local candidate = tmp .. "/candidate"
  local project = tmp .. "/driver"
  assert(Fs.mkdirs(candidate))
  assert(Fs.mkdirs(project))
  assert(State.external_path("/tmp", candidate, project .. "/driver.tl") ==
    assert(Fs.absolute("/tmp")))
end

local function test_external_path_rejects_the_namespaced_driver_project(tmp: string)
  local candidate = tmp .. "/candidate"
  local project = tmp .. "/driver"
  assert(Fs.mkdirs(candidate))
  assert(Fs.mkdirs(project .. "/cosmic_ci"))
  local called = pcall(State.external_path, project .. "/state.db", candidate,
    project .. "/cosmic_ci/driver.tl")
  assert(not called, "namespaced driver project accepted its own state")
end
