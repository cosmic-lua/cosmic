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
  local ok, why = pcall(BuildPaths.directory, tmp, {})
  assert(not ok and tostring(why):find("invalid build home", 1, true) ~= nil, tostring(why))
end

local function test_extra_output_is_refused(tmp: string)
  source(tmp, [[
  assert(Fs.put(Fs.stdout, "/first\n/second\n"))
  return 0
]])
  local ok, why = pcall(BuildPaths.directory, tmp, {})
  assert(not ok and tostring(why):find("did not print one path", 1, true) ~= nil, tostring(why))
end

--- The running driver names where it builds a project: outside it.
local function test_the_driver_names_where_it_builds_a_project(tmp: string)
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  local built = BuildPaths.driven(project)
  assert(built:sub(1, 1) == "/", built)
  assert(not Fs.within(built, project), built)
end

--- The driver is the pinned release and what it runs is the tree's Teal, in the new grammar: a caller's values that do not
--- name the grammar (a fixture's environment) still start it with COSMIC_GRAMMAR=new.
local function test_the_driver_is_started_in_the_new_grammar()
  local driver = BuildPaths.driver({ "fix", "--check" }, { HOME = "/nowhere" })
  assert(driver.env["COSMIC_GRAMMAR"] == "new", "the driver was started without the new grammar")
  assert(driver.env["HOME"] == "/nowhere", "the caller's values were lost")
end

--- A file run standalone by the driver's own path is not the helper's to start: the words refuse it.
local function test_the_driver_does_not_run_a_file_standalone()
  Test.raises(function() BuildPaths.driver({ "--standalone", "build/paths.tl" }, {}) end, "does not run a file standalone")
end
