local Fs = require("cosmic.fs")
local Project = require("cosmic.project")
local sys = require("cosmic.sys")

--- `tmp`'s project, made, and the base of build directories beside it,
--- each by its resolved path.
local function project(tmp: string, name?: string): string, string
  local root = tmp .. "/" .. (name or "project")
  assert(Fs.mkdirs(root))
  return assert(sys.realpath(root)), assert(sys.realpath(tmp)) .. "/home"
end

--- The directory is named, not made: neither it nor its base is there
--- after, and it is a directory of the base's own for the root.
local function test_a_directory_is_named_without_being_made(tmp: string)
  local root, home = project(tmp)
  local directory, trouble = Project.directory(root, { COSMIC_BUILD_HOME = home })
  assert(directory ~= nil, trouble)
  assert(Fs.dirname(directory) == home, directory)
  assert(Fs.exists(home) == false, "naming the directory made its base")
end

--- With no COSMIC_BUILD_HOME the base is the user's cache, XDG_CACHE_HOME's
--- else HOME's `.cache`, and the root's directory is its own there too.
local function test_the_default_base_is_the_user_cache(tmp: string)
  local root = project(tmp)
  local real = assert(sys.realpath(tmp))
  local xdg = assert(Project.directory(root, { XDG_CACHE_HOME = real .. "/xdg", HOME = real .. "/h" }))
  assert(Fs.dirname(xdg) == real .. "/xdg/cosmic/trees", xdg)
  local home = assert(Project.directory(root, { HOME = real .. "/h", COSMIC_BUILD_HOME = "" }))
  assert(Fs.dirname(home) == real .. "/h/.cache/cosmic/trees", home)
  local none, why = Project.directory(root, { HOME = "relative" })
  assert(none == nil and why:find("set COSMIC_BUILD_HOME", 1, true) ~= nil, why)
end

--- A link to a root names the root's own directory, a link to the base
--- the base's, and two roots under one base name two.
local function test_a_link_names_its_root_and_roots_keep_apart(tmp: string)
  local root, home = project(tmp)
  local other = project(tmp, "other")
  assert(sys.symlink(root, tmp .. "/alias"))
  local env = { COSMIC_BUILD_HOME = home }
  local own = assert(Project.directory(root, env))
  assert(Project.directory(tmp .. "/alias", env) == own)
  assert(Project.directory(tmp .. "/alias/.", env) == own)
  assert(Project.directory(other, env) ~= own)
  assert(Fs.mkdirs(home))
  assert(sys.symlink(home, tmp .. "/home-link"))
  assert(Project.directory(root, { COSMIC_BUILD_HOME = tmp .. "/home-link" }) == own)
end

--- A base that is no absolute path, a directory that would be inside the
--- root, a root that is none, and a base others may write are refused,
--- each naming what is wrong.
local function test_an_unusable_location_is_refused(tmp: string)
  local root, home = project(tmp)
  local function refused(at: string, env: {string:string}, says: string)
    local directory, why = Project.directory(at, env)
    assert(directory == nil and why:find(says, 1, true) ~= nil, why)
  end
  refused(root, { COSMIC_BUILD_HOME = "relative/home" },
    "COSMIC_BUILD_HOME=relative/home is not an absolute path")
  refused(root, { COSMIC_BUILD_HOME = root .. "/builds" }, "is inside the project root " .. root)
  refused(tmp .. "/missing", { COSMIC_BUILD_HOME = home }, tmp .. "/missing")
  refused("", { COSMIC_BUILD_HOME = home }, "project root is empty")
  assert(Fs.write(tmp .. "/file", ""))
  refused(tmp .. "/file", { COSMIC_BUILD_HOME = home }, "the project root is not a directory")
  assert(sys.mkdir(home, 0x1ff))
  assert(sys.chmod(home, 0x1ff))
  refused(root, { COSMIC_BUILD_HOME = home }, "writable by its group or others")
end
