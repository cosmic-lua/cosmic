local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Zig = require("build.zig")
local paths = require("build.paths")
local reboot = require("build.reboot")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")
local work = require("build.work")
local type _ = require("build.standalone")

Test.policy{ profiles = { "cosmic" }, grants = {
  { path = "build/paths.tl", letters = "r" },
  { path = "build.zig", letters = "r" },
} }

local function test_resolution_makes_nothing(tmp: string)
  local root = tmp .. "/project"
  local directory, trouble = paths.directory(root, {})
  assert(directory == root .. "/o", trouble)
  assert(paths.required(root, {}) == directory)
  local present = assert(Fs.list(tmp))
  assert(#present == 0, "resolving output created a directory")
end

local function test_bootstrap_and_runtime_resolve_the_same_directory(tmp: string)
  local script = tmp .. "/paths.tl"
  assert(Fs.write(script, (assert(Fs.read("build/paths.tl")))))
  local root = tmp .. "/project"
  local started = this_program.program({ "--standalone", script, root }, {
    cwd = tmp, env = {}, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, tostring(result.stderr))
  assert(result.stdout == paths.required(root, {}) .. "\n", tostring(result.stdout))
  assert(Fs.exists(root) == false, "bootstrap resolution created the project")
end

local function test_bootstrap_refuses_missing_and_extra_roots(tmp: string)
  local script = tmp .. "/paths.tl"
  assert(Fs.write(script, (assert(Fs.read("build/paths.tl")))))
  for _, words in ipairs({ {}, { tmp, tmp } } as {{string}}) do
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
local function test_the_layout_names_each_path_under_the_directory()
  local root = "/project"
  local layout = paths.resolve(root, {})
  assert(layout.directory == paths.required(root, {}))
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
end
