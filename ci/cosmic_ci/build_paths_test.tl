local BuildPaths = require("cosmic_ci.build_paths")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

-- Resolving a not-yet-booted project executes the running driver.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function source(path: string, body: string, environment?: boolean)
  assert(Fs.mkdirs(path .. "/build"))
  assert(Fs.write(path .. "/build/paths.tl", (if environment == true then 'local Env = require("cosmic.env")\n' else "" end) .. [[
local Fs = require("cosmic.fs")
local record Paths end
function Paths.main(_argv: {string}): integer
]] .. body .. [[
end
return Paths
]]))
end

local function test_resolution_uses_the_child_environment_and_source_checkout(tmp: string)
  local checkout, project = tmp .. "/source tree", tmp .. "/application"
  assert(Fs.mkdirs(project))
  source(checkout, [[
  assert(Fs.put(Fs.stdout, assert(Env.get("COSMIC_BUILD_HOME")) .. "/" .. Fs.basename(assert(_argv[1])) .. "\n"))
  return 0
]], true)
  local a, b = { COSMIC_BUILD_HOME = tmp .. "/a" }, { COSMIC_BUILD_HOME = tmp .. "/b" }
  assert(BuildPaths.directory(project, a, checkout) == tmp .. "/a/application")
  assert(BuildPaths.directory(project, b, checkout) == tmp .. "/b/application")
  assert(BuildPaths.directory(project, a, checkout) == tmp .. "/a/application")
  assert(Fs.exists(project .. "/o") == false, "resolver created legacy output")
end

local function test_a_failed_resolver_is_not_used_as_a_directory(tmp: string)
  source(tmp, [[
  assert(Fs.put(Fs.stderr, "invalid build home\n"))
  return 2
]])
  Test.raises(function() BuildPaths.directory(tmp, {}) end, "invalid build home")
end

local function test_extra_output_is_refused(tmp: string)
  source(tmp, [[
  assert(Fs.put(Fs.stdout, "/first\n/second\n"))
  return 0
]])
  Test.raises(function() BuildPaths.directory(tmp, {}) end, "did not print one path")
end

--- The running driver names where it builds a project: outside it.
local function test_the_driver_names_where_it_builds_a_project(tmp: string)
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  local built = BuildPaths.driven(project)
  assert(built:sub(1, 1) == "/", built)
  assert(not Fs.within(built, project), built)
end

--- A file run standalone by the driver's own path is not the helper's to start: the words refuse it.
local function test_the_driver_does_not_run_a_file_standalone()
  Test.raises(function() BuildPaths.driver({ "--standalone", "build/paths.tl" }, {}) end,
    "does not run a file standalone")
end
