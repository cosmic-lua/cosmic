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

local function test_prepare_runs_even_after_the_directory_was_named(tmp: string)
  source(tmp, [[
  local root = _argv[1] == "--prepare" and _argv[2] or _argv[1]
  if _argv[1] == "--prepare" then assert(Fs.write(root .. "/prepared", "created")) end
  assert(Fs.put(Fs.stdout, root .. "/output\n"))
  return 0
]])
  assert(BuildPaths.directory(tmp, {}) == tmp .. "/output")
  assert(Fs.exists(tmp .. "/prepared") == false)
  assert(BuildPaths.prepare(tmp, {}) == tmp .. "/output")
  assert(Fs.read(tmp .. "/prepared") == "created")
end
