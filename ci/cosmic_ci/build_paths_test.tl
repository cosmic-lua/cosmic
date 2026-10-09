local BuildPaths = require("cosmic_ci.build_paths")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

-- Resolving a not-yet-booted project executes the running driver.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function source(path: string, body: string, environment?: boolean)
  assert(Fs.mkdirs(path .. "/build"))
  assert(Fs.write(path .. "/build/paths.tl", (environment and 'local Env = require("cosmic.env")\n' or "") .. [[
local Fs = require("cosmic.fs")
local record Paths end
function Paths.main(_argv: {integer:string}): integer
]] .. body .. [[
end
return Paths
]]))
end

local function test_resolution_uses_the_child_environment_and_source_checkout(tmp: string)
  local checkout, project = tmp .. "/source tree", tmp .. "/application"
  assert(Fs.mkdirs(project))
  source(checkout, [[
  assert(Fs.put(Fs.stdout, assert(Env.get("COSMIC_BUILD_HOME")) .. "/" .. Fs.basename(_argv[1]) .. "\n"))
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
  local ok, why = pcall(BuildPaths.directory, tmp, {})
  assert(not ok and tostring(why):find("invalid build home", 1, true), tostring(why))
end

local function test_extra_output_is_refused(tmp: string)
  source(tmp, [[
  assert(Fs.put(Fs.stdout, "/first\n/second\n"))
  return 0
]])
  local ok, why = pcall(BuildPaths.directory, tmp, {})
  assert(not ok and tostring(why):find("did not print one path", 1, true), tostring(why))
end

--- The running driver names where it builds a project: outside it, by a
--- driver that carries build/paths.tl, and in its o/ by one that does not.
local function test_the_driver_names_where_it_builds_a_project(tmp: string)
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  local built = BuildPaths.driven(project)
  assert(built:sub(1, 1) == "/", built)
  assert(built == project .. "/o" or not Fs.within(built, project), built)
end
