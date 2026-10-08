local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local paths = require("build.paths")
local this_program = require("build.this_program")
local type _ = require("build.standalone")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "build/paths.tl", letters = "r" } } }

local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  return (assert(Fs.absolute(root)))
end

local function test_resolution_makes_nothing(tmp: string)
  local root = project(tmp)
  local canonical = assert(Fs.absolute(tmp))
  local environment = { XDG_CACHE_HOME = tmp .. "/cache" }
  local directory, trouble = paths.directory(root, environment)
  local expected = canonical .. "/cache/cosmic/trees/" .. Hash.hex_sha256(root)
  assert(directory == expected, tostring(directory) .. " ~= " .. expected .. ": " .. trouble)
  assert(paths.required(root, environment) == directory)
  local present = assert(Fs.list(tmp))
  assert(#present == 1 and present[1] == "project", "resolving output created a directory")
  assert(Fs.exists(root .. "/o") == false)
end

local function test_home_fallback_and_explicit_base(tmp: string)
  local root = project(tmp)
  local canonical = assert(Fs.absolute(tmp))
  local key = Hash.hex_sha256(root)
  local function check(environment: {string:string}, suffix: string)
    local directory = paths.required(root, environment)
    local expected = canonical .. suffix .. key
    assert(directory == expected, directory .. " ~= " .. expected)
  end
  check({ HOME = tmp, XDG_CACHE_HOME = "relative" }, "/.cache/cosmic/trees/")
  check({ HOME = tmp, COSMIC_BUILD_HOME = tmp .. "/builds" }, "/builds/")
  check({ HOME = tmp, COSMIC_BUILD_HOME = "" }, "/.cache/cosmic/trees/")
  local directory, trouble = paths.directory(root, {})
  assert(directory == nil and trouble:find("no cache directory", 1, true) ~= nil, trouble)
  directory, trouble = paths.optional(root, {})
  assert(directory == nil and trouble == "", trouble)
  directory, trouble = paths.optional(root, { COSMIC_BUILD_HOME = "relative" })
  assert(directory == nil and trouble ~= "", "explicit invalid build home was ignored")
end

local function test_aliases_share_output_and_projects_do_not(tmp: string)
  local root = project(tmp)
  assert(Fs.symlink("project", tmp .. "/alias"))
  assert(Fs.mkdirs(tmp .. "/other"))
  local environment = { COSMIC_BUILD_HOME = tmp .. "/builds" }
  local directory = paths.required(root, environment)
  assert(paths.required(tmp .. "/alias", environment) == directory)
  assert(paths.required(root .. "/.", environment) == directory)
  assert(paths.required(tmp .. "/other", environment) ~= directory)
  assert(paths.in_home("/tree", "/tmp/build/") == "/tmp/build/" .. Hash.hex_sha256("/tree"))
end

local function test_prepare_creates_private_output_without_writing_sources(tmp: string)
  local root = project(tmp)
  assert(sys.chmod(root, 0x16d))
  local environment = { XDG_CACHE_HOME = tmp .. "/cache" }
  local directory, trouble = paths.prepare(root, environment)
  assert(directory ~= nil, trouble)
  for _, path in ipairs({ tmp .. "/cache/cosmic", tmp .. "/cache/cosmic/trees", directory }) do
    local st = assert(Fs.stat(path))
    assert(st.uid == sys.getuid() and st.mode & 0x1ff == 0x1c0, path)
  end
  assert(paths.prepare(root, environment) == directory)
  assert(#assert(Fs.list(root)) == 0, "preparing output wrote into the read-only project")
  assert(sys.chmod(root, 0x1c0))
end

local function test_prepare_creates_explicit_home_privately(tmp: string)
  local root = project(tmp)
  local environment = { COSMIC_BUILD_HOME = tmp .. "/missing/builds" }
  local directory = assert(paths.prepare(root, environment))
  for _, path in ipairs({ environment.COSMIC_BUILD_HOME, directory }) do
    assert(assert(Fs.stat(path)).mode & 0x1ff == 0x1c0, path)
  end
end

local function test_existing_unsafe_home_and_output_are_refused(tmp: string)
  local root = project(tmp)
  local home = tmp .. "/builds"
  assert(Fs.mkdirs(home))
  assert(sys.chmod(home, 0x1ff))
  local environment = { COSMIC_BUILD_HOME = home }
  local directory, trouble = paths.directory(root, environment)
  assert(directory == nil and trouble:find("writable by its group or others", 1, true) ~= nil, trouble)
  assert(paths.prepare(root, environment) == nil)
  assert(assert(Fs.stat(home)).mode & 0x1ff == 0x1ff, "unsafe permissions were silently repaired")
  assert(sys.chmod(home, 0x1c0))
  directory = assert(paths.prepare(root, environment))
  assert(sys.chmod(directory, 0x1ff))
  local selected, selected_trouble = paths.directory(root, environment)
  assert(selected == nil and selected_trouble:find(directory, 1, true) ~= nil, selected_trouble)
  assert(paths.prepare(root, environment) == nil)
end

local function test_existing_unsafe_default_cache_is_refused(tmp: string)
  local root = project(tmp)
  assert(Fs.mkdirs(tmp .. "/cache/cosmic"))
  assert(sys.chmod(tmp .. "/cache/cosmic", 0x1ff))
  local directory, trouble = paths.directory(root, { XDG_CACHE_HOME = tmp .. "/cache" })
  assert(directory == nil and trouble:find("writable by its group or others", 1, true) ~= nil, trouble)
end

local function test_invalid_roots_and_configuration_fail_clearly(tmp: string)
  local root = project(tmp)
  assert(Fs.write(tmp .. "/file", "file"))
  for _, home in ipairs({ "relative", "/bad\0name" }) do
    local directory, trouble = paths.directory(root, { COSMIC_BUILD_HOME = home })
    assert(directory == nil and trouble == "COSMIC_BUILD_HOME must name an absolute directory", trouble)
  end
  local directory, trouble = paths.directory(root, { XDG_CACHE_HOME = "/bad\0name" })
  assert(directory == nil and trouble == "build directory contains a NUL byte", trouble)
  directory, trouble = paths.directory(tmp .. "/missing", { HOME = tmp })
  assert(directory == nil and trouble:find("project root:", 1, true) ~= nil, trouble)
  directory, trouble = paths.directory(tmp .. "/file", { HOME = tmp })
  assert(directory == nil and trouble:find("not a directory", 1, true) ~= nil, trouble)
  directory, trouble = paths.directory(root, { COSMIC_BUILD_HOME = tmp .. "/file" })
  assert(directory == nil and trouble:find("not a directory", 1, true) ~= nil, trouble)
end

--- A generated directory must never become an input of its own build.
local function test_build_output_inside_the_project_is_refused(tmp: string)
  local root = project(tmp)
  for _, environment in ipairs({
      { COSMIC_BUILD_HOME = root .. "/generated" },
      { XDG_CACHE_HOME = root .. "/cache" },
      { HOME = root },
  } as {{string:string}}) do
    local directory, trouble = paths.directory(root, environment)
    assert(directory == nil and trouble:find("must be outside the project root", 1, true) ~= nil, trouble)
    directory, trouble = paths.prepare(root, environment)
    assert(directory == nil and trouble:find("must be outside the project root", 1, true) ~= nil, trouble)
  end
  assert(#assert(Fs.list(root)) == 0, "refused output was created inside the project")
end

local function test_optional_default_inside_root_is_unavailable(tmp: string)
  local root = project(tmp)
  local directory, trouble = paths.optional(root, { HOME = root })
  assert(directory == nil and trouble == "", trouble)
  directory, trouble = paths.optional(root, { COSMIC_BUILD_HOME = root .. "/builds" })
  assert(directory == nil and trouble:find("must be outside the project root", 1, true) ~= nil, trouble)
  assert(Fs.mkdirs(root .. "/.cache/cosmic"))
  assert(sys.chmod(root .. "/.cache/cosmic", 0x1ff))
  directory, trouble = paths.optional(root, { HOME = root })
  assert(directory == nil and trouble:find("writable by its group or others", 1, true) ~= nil, trouble)
end

local function test_output_aliases_cannot_hide_an_in_tree_build(tmp: string)
  local root = project(tmp)
  assert(Fs.symlink("project", tmp .. "/home-alias"))
  local directory, trouble = paths.directory(root, { COSMIC_BUILD_HOME = tmp .. "/home-alias" })
  assert(directory == nil and trouble:find("must be outside the project root", 1, true) ~= nil, trouble)
  local home = tmp .. "/builds"
  assert(Fs.mkdirs(home))
  assert(Fs.mkdirs(root .. "/generated"))
  assert(Fs.symlink(root .. "/generated", home .. "/" .. Hash.hex_sha256(root)))
  directory, trouble = paths.directory(root, { COSMIC_BUILD_HOME = home })
  assert(directory == nil and trouble:find("must be outside the project root", 1, true) ~= nil, trouble)
end

local function test_bootstrap_and_runtime_resolve_the_same_directory(tmp: string)
  local script = tmp .. "/paths.tl"
  assert(Fs.write(script, (assert(Fs.read("build/paths.tl")))))
  local root = project(tmp)
  local environment = { COSMIC_BUILD_HOME = tmp .. "/builds" }
  local started = this_program.program({ "--standalone", script, root }, {
    cwd = tmp, env = environment, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, tostring(result.stderr))
  assert(result.stdout == paths.required(root, environment) .. "\n", tostring(result.stdout))
  assert(Fs.exists(environment.COSMIC_BUILD_HOME) == false, "bootstrap resolution created output")
  started = this_program.program({ "--standalone", script, "--prepare", root }, {
    cwd = tmp, env = environment, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30),
  })
  result = assert(Child.run(started.argv, started.options))
  assert(result.ok, tostring(result.stderr))
  assert(result.stdout == paths.required(root, environment) .. "\n", tostring(result.stdout))
  assert(Fs.exists(environment.COSMIC_BUILD_HOME) == true)
end

local function test_bootstrap_refuses_missing_and_extra_roots(tmp: string)
  local script = tmp .. "/paths.tl"
  assert(Fs.write(script, (assert(Fs.read("build/paths.tl")))))
  for _, words in ipairs({ {}, { tmp, tmp }, { "--prepare" }, { "--prepare", tmp, tmp } } as {{string}}) do
    local argv = { "--standalone", script }
    for _, word in ipairs(words) do argv[#argv + 1] = word end
    local started = this_program.program(argv, {
      env = {}, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30),
    })
    local result = assert(Child.run(started.argv, started.options))
    assert(result.code == 2, tostring(result.stderr))
    assert(result.stdout == "", tostring(result.stdout))
    assert(tostring(result.stderr):find("usage:", 1, true) ~= nil, tostring(result.stderr))
  end
end

local function test_an_empty_project_root_is_refused()
  local directory, trouble = paths.directory("", {})
  assert(directory == nil and trouble == "project root is empty", trouble)
  local ok, raised = pcall(paths.required, "", {})
  assert(not ok and raised == trouble, tostring(raised))
end
