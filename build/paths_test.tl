local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Test = require("cosmic.test")
local Zig = require("build.zig")
local paths = require("build.paths")
local reboot = require("build.reboot")
local rebuild_lock = require("build.rebuild_lock")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local work = require("build.work")
local type _ = require("build.standalone")

Test.policy{ profiles = { "cosmic" }, grants = {
  { path = "build/paths.tl", letters = "r" },
  { path = "build.zig", letters = "r" },
} }

--- `tmp`'s project, made, and the base of build directories beside it,
--- each by its resolved path.
local function project(tmp: string, name?: string): string, string
  local root = tmp .. "/" .. (name or "project")
  assert(Fs.mkdirs(root))
  local real = assert(sys.realpath(tmp))
  return assert(sys.realpath(root)), real .. "/home"
end

local function test_resolution_makes_nothing(tmp: string)
  local root, home = project(tmp)
  local directory, trouble = paths.directory(root, { COSMIC_BUILD_HOME = home })
  assert(directory == home .. "/" .. Hash.hex_sha256(root), trouble)
  assert(paths.required(root, { COSMIC_BUILD_HOME = home }) == directory)
  assert(Fs.exists(home) == false, "resolving output created a directory")
end

--- With no COSMIC_BUILD_HOME the base is the user's cache:
--- XDG_CACHE_HOME's, else HOME's `.cache`, as the tree's other caches.
local function test_the_default_base_is_the_user_cache(tmp: string)
  local root = project(tmp)
  local key = Hash.hex_sha256(root)
  local real = assert(sys.realpath(tmp))
  assert(paths.directory(root, { XDG_CACHE_HOME = real .. "/xdg", HOME = real .. "/h" }) ==
      real .. "/xdg/cosmic/trees/" .. key)
  assert(paths.directory(root, { HOME = real .. "/h", COSMIC_BUILD_HOME = "" }) ==
      real .. "/h/.cache/cosmic/trees/" .. key)
end

--- A root by a link to it names the root's own directory; two roots
--- under one base -- worktrees of one repository -- name two.
local function test_a_link_names_its_root_and_worktrees_keep_apart(tmp: string)
  local root, home = project(tmp)
  local other = project(tmp, "worktree")
  assert(sys.symlink(root, tmp .. "/alias"))
  local env = { COSMIC_BUILD_HOME = home }
  local own = paths.required(root, env)
  assert(paths.required(tmp .. "/alias", env) == own)
  assert(paths.required(tmp .. "/alias/.", env) == own)
  assert(paths.required(other, env) ~= own)
  local real_home = home .. "-real"
  assert(Fs.mkdirs(real_home))
  assert(sys.symlink(real_home, tmp .. "/home-link"))
  assert(paths.required(root, { COSMIC_BUILD_HOME = tmp .. "/home-link" }) ==
      real_home .. "/" .. Hash.hex_sha256(root))
end

--- A COSMIC_BUILD_HOME that is no absolute path, one that would put the
--- build directory inside the project, a root that is no directory and
--- a base no one but this user may write are refused, each naming what
--- is wrong; nothing falls back to the project's `o/`.
local function test_an_unusable_location_is_refused(tmp: string)
  local root, home = project(tmp)
  local directory, trouble = paths.directory(root, { COSMIC_BUILD_HOME = "relative/home" })
  assert(directory == nil and trouble == "COSMIC_BUILD_HOME=relative/home is not an absolute path",
    trouble)
  directory, trouble = paths.directory(root, { COSMIC_BUILD_HOME = root .. "/builds" })
  assert(directory == nil and trouble:find("is inside the project root " .. root, 1, true) ~= nil,
    trouble)
  directory, trouble = paths.directory(tmp .. "/missing", { COSMIC_BUILD_HOME = home })
  assert(directory == nil and trouble:find(tmp .. "/missing", 1, true) ~= nil, trouble)
  assert(Fs.write(tmp .. "/file", ""))
  directory, trouble = paths.directory(tmp .. "/file", { COSMIC_BUILD_HOME = home })
  assert(directory == nil and trouble:find("not a directory", 1, true) ~= nil, trouble)
  directory, trouble = paths.directory(root, { HOME = "", XDG_CACHE_HOME = "" })
  assert(directory == nil and trouble:find("set COSMIC_BUILD_HOME", 1, true) ~= nil, trouble)
  assert(sys.mkdir(home, 0x1ff))
  assert(sys.chmod(home, 0x1ff))
  directory, trouble = paths.directory(root, { COSMIC_BUILD_HOME = home })
  assert(directory == nil and trouble == "COSMIC_BUILD_HOME " .. home ..
      ": writable by its group or others", trouble)
  local made, made_trouble = paths.prepare(root, { COSMIC_BUILD_HOME = home })
  assert(made == nil and made_trouble == trouble, made_trouble)
  assert(Fs.exists(root .. "/o") == false)
end

--- `prepare` makes the base and the directory, each this user's alone.
local function test_prepare_makes_a_private_directory(tmp: string)
  local root, home = project(tmp)
  local env = { COSMIC_BUILD_HOME = home .. "/nested" }
  local made = assert(paths.prepare(root, env))
  assert(made == paths.required(root, env))
  for _, path in ipairs({ home .. "/nested", made }) do
    local st = assert(sys.stat(path))
    assert(st.kind == "dir" and st.mode & 0x1ff == 0x1c0, path)
  end
  assert(paths.prepare(root, env) == made)
  assert(Fs.exists(root .. "/o") == false)
end

--- A lookup above the base -- an ancestor of COSMIC_BUILD_HOME, whose
--- build directory would be inside it -- or with no cache directory to
--- put one in finds no build directory and no trouble, as for a project
--- never built.
local function test_optional_finds_none_above_the_base(tmp: string)
  local root, home = project(tmp)
  local real = assert(sys.realpath(tmp))
  local env = { COSMIC_BUILD_HOME = home }
  local directory, trouble = paths.optional(real, env)
  assert(directory == nil and trouble == "", trouble)
  directory, trouble = paths.optional(root, { HOME = "", XDG_CACHE_HOME = "" })
  assert(directory == nil and trouble == "", trouble)
  assert(paths.optional(root, env) == paths.required(root, env))
  directory, trouble = paths.optional(root, { COSMIC_BUILD_HOME = "relative" })
  assert(directory == nil and trouble ~= "", "a bad base is no build never made")
end

local function test_bootstrap_and_runtime_resolve_the_same_directory(tmp: string)
  local script = tmp .. "/paths.tl"
  assert(Fs.write(script, (assert(Fs.read("build/paths.tl")))))
  local root, home = project(tmp)
  for _, words in ipairs({ { root }, { "--prepare", root } } as {{string}}) do
    local argv = { "--standalone", script }
    for _, word in ipairs(words) do argv[#argv + 1] = word end
    local started = this_program.program(argv, {
      cwd = tmp, env = { COSMIC_BUILD_HOME = home }, stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(30),
    })
    local result = assert(Child.run(started.argv, started.options))
    assert(result.ok, tostring(result.stderr))
    assert(result.stdout == paths.required(root, { COSMIC_BUILD_HOME = home }) .. "\n",
      tostring(result.stdout))
    assert(Fs.exists(home) == (words[1] == "--prepare"), "only --prepare makes the directory")
  end
  local started = this_program.program({ "--standalone", script, root }, {
    cwd = tmp, env = { COSMIC_BUILD_HOME = "relative" }, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 1 and result.stdout == "", tostring(result.stdout))
  assert(result.stderr == "build/paths.tl: COSMIC_BUILD_HOME=relative is not an absolute path\n",
    tostring(result.stderr))
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

--- Every path a build keeps is named under the one directory the
--- resolver names, each apart from the others.
local function test_the_layout_names_each_path_under_the_directory(tmp: string)
  local root, home = project(tmp)
  local layout = paths.resolve(root, { COSMIC_BUILD_HOME = home })
  assert(layout.directory == paths.required(root, { COSMIC_BUILD_HOME = home }))
  local seen: {string: string} = {}
  for field, path in pairs(layout as {string: string}) do
    if field ~= "directory" then
      assert(path:sub(1, #layout.directory + 1) == layout.directory .. "/",
        field .. " is outside the build directory: " .. path)
      assert(seen[path] == nil, field .. " and " .. tostring(seen[path]) .. " name " .. path)
      seen[path] = field
    end
  end
  assert(layout.projection == layout.directory .. "/cosmic.db")
  assert(layout.working == layout.directory .. "/build.db")
  assert(layout.tool == layout.bin .. "/cosmic")
  assert(layout.lock == layout.directory .. "/rebuild.lock")
  assert(paths.core(layout, "x86_64-linux") == layout.cores .. "/x86_64-linux/cosmic-core")
  local ok, raised = pcall(paths.resolve, "", {})
  assert(not ok and tostring(raised) == "project root is empty", tostring(raised))
end

--- build.zig installs into the directory bin/zig hands it as its prefix,
--- by names it spells itself: the raw cores the boot reads, and the
--- sanitized build directory beneath it.
local function test_build_zig_installs_where_the_layout_names()
  local text = assert(Fs.read("build.zig"))
  local layout = paths.under("")
  local core = paths.core(layout, "{s}"):sub(2)
  assert(text:find('"' .. core .. '"', 1, true) ~= nil,
    "build.zig installs no core at " .. core)
  local sanitized = layout.sanitized:sub(2)
  assert(text:find('.sub_path = "' .. sanitized .. '"', 1, true) ~= nil,
    "build.zig boots the checked core outside " .. sanitized)
end

--- A boot (bin/zig's lock and prefix), the verbs (the working database a
--- build opens, the tool they re-enter) and the rebuild lock name one
--- directory for a tree, and one lock in it.
local function test_boot_verbs_and_lock_resolve_alike(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local layout = paths.resolve(root)
  local handle = assert(work.open(root))
  local opened = handle.dir
  assert(work.close(handle))
  assert(opened == layout.directory, opened .. " against " .. layout.directory)
  assert(Fs.exists(layout.working))
  assert(rebuild_lock.hand({}, root).COSMIC_REBUILD_LOCK_HANDED == layout.lock)
  assert(Fs.mkdirs(layout.bin))
  assert(Fs.write(layout.tool, ""))
  assert(reboot.own_tool(root, layout.tool) == true)
  local status = Zig.with_lock(layout.directory, {}, function(env: {string:string}): integer
    assert(env.COSMIC_REBUILD_LOCK_HANDED == layout.lock, env.COSMIC_REBUILD_LOCK_HANDED)
    local holder = rebuild_lock.holder(root)
    assert(holder:find("is rebuilding the tool", 1, true) ~= nil, holder)
    return 7
  end)
  assert(status == 7)
  assert(Fs.exists(root .. "/o") == false, "a build wrote o/ in the project")
end
