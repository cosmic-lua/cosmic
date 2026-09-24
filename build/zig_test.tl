--- `build/zig.tl`'s parts that need no network: pin parsing, the host
--- triple, argument rewriting, root detection, `PATH` lookup, the exit
--- statuses a failed exec means, the cache hit, and the sweep of a dead
--- install's scratch directory.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Zig = require("build.zig")

local function test_read_pin_parses_version_and_hosts()
  local pin = assert(Zig.read_pin(
    "version 0.16.0\n" ..
    "x86_64-linux 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00\n" ..
    "aarch64-macos b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489\n"))
  assert(pin.version == "0.16.0")
  assert(pin.shas["x86_64-linux"] ==
    "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00")
  assert(pin.shas["aarch64-macos"] ==
    "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489")
  assert(pin.shas["aarch64-linux"] == nil)
end

local function test_read_pin_ignores_trailing_blanks_and_keeps_the_first_line()
  local pin = assert(Zig.read_pin(
    "version 0.16.0  \r\nx86_64-linux abc \r\nx86_64-linux def\nversion 9\n"))
  assert(pin.version == "0.16.0")
  assert(pin.shas["x86_64-linux"] == "abc")
end

local function test_read_pin_requires_a_version_line()
  local pin, trouble = Zig.read_pin("x86_64-linux abc\n")
  assert(pin == nil)
  assert(trouble:find("version", 1, true) ~= nil)
end

local function test_host_normalizes_uname()
  assert(Zig.host("Linux", "x86_64") == "x86_64-linux")
  assert(Zig.host("Linux", "aarch64") == "aarch64-linux")
  assert(Zig.host("Linux", "amd64") == "x86_64-linux")
  assert(Zig.host("Darwin", "arm64") == "aarch64-macos")
end

local function test_host_refuses_what_zig_is_not_pinned_for()
  local triple, trouble = Zig.host("Windows_NT", "x86_64")
  assert(triple == nil and trouble:find("Windows_NT", 1, true) ~= nil)
  triple, trouble = Zig.host("Linux", "riscv64")
  assert(triple == nil and trouble:find("riscv64", 1, true) ~= nil)
end

local function test_host_agrees_with_the_running_host()
  local names = assert(sys.uname())
  local triple = assert(Zig.host(names.sysname, names.machine))
  assert(triple:match("^[%w_]+%-[%w_]+$") ~= nil)
end

local function test_build_args_adds_cache_flags_only_for_build()
  local got = Zig.build_args("/repo", "/cache/zig-global", { "build", "-Doptimize=ReleaseFast" })
  assert(#got == 8)
  assert(got[1] == "build")
  assert(got[2] == "--cache-dir" and got[3] == "/repo/o/zig-cache")
  assert(got[4] == "--global-cache-dir" and got[5] == "/cache/zig-global")
  assert(got[6] == "--prefix" and got[7] == "/repo/o")
  assert(got[8] == "-Doptimize=ReleaseFast")
end

local function test_build_args_passes_other_subcommands_through()
  local got = Zig.build_args("/repo", "/cache/zig-global", { "version" })
  assert(#got == 1 and got[1] == "version")
end

-- The global cache is shared: named outright, else in this user's cache
-- directory, and in the checkout only when there is no cache directory.
local function test_global_cache_is_named_then_shared_then_local(tmp: string)
  assert(Zig.global_cache("/repo", { COSMIC_ZIG_GLOBAL_CACHE = "/ci/zig-global",
    XDG_CACHE_HOME = tmp }) == "/ci/zig-global")
  assert(Zig.global_cache("/repo", { XDG_CACHE_HOME = tmp }) == tmp .. "/cosmic/zig-global")
  assert(Zig.global_cache("/repo", {}) == "/repo/o/zig-global")
end

local function test_repo_root_from_the_scripts_own_path(tmp: string)
  assert(Fs.mkdirs(tmp .. "/repo/build"))
  assert(Fs.write(tmp .. "/repo/build/zig.tl", "-- stand-in"))
  local root = assert(Zig.repo_root(tmp .. "/repo/build/zig.tl"))
  assert(root == assert(Fs.absolute(tmp .. "/repo")))
end

local function test_resolve_searches_path_for_a_bare_name(tmp: string)
  assert(Fs.mkdirs(tmp .. "/a"))
  assert(Fs.mkdirs(tmp .. "/b"))
  assert(Fs.write(tmp .. "/a/tool", "not executable", 0x1a4))
  assert(Fs.write(tmp .. "/b/tool", "#!/bin/sh\n", 0x1ed))
  local path = tmp .. "/missing:" .. tmp .. "/a:" .. tmp .. "/b"
  local found, status = Zig.resolve("tool", path)
  assert(found == tmp .. "/b/tool" and status == 0)
  -- A name with a slash is used as it is, never searched for.
  assert(Zig.resolve("./tool", path) == "./tool")
end

local function test_resolve_answers_127_for_nothing_and_126_for_no_permission(tmp: string)
  local none, missing = Zig.resolve("no-such-tool", tmp)
  assert(none == nil and missing == 127)
  assert(Fs.write(tmp .. "/plain", "not executable", 0x1a4))
  local plain, denied = Zig.resolve("plain", tmp)
  assert(plain == nil and denied == 126)
end

local function test_exec_status_is_the_shells()
  assert(Zig.exec_status(sys.ENOENT) == 127)
  assert(Zig.exec_status(sys.EACCES) == 126)
end

local function test_ensure_installed_is_a_cache_hit_when_zig_is_already_there(tmp: string)
  local install = tmp .. "/cache/0.16.0-x86_64-linux"
  assert(Fs.mkdirs(install))
  assert(Fs.write(install .. "/zig", "#!/bin/sh\necho stand-in\n", 0x1ed))
  -- No sha for the host: reaching the network path would fail loudly.
  local pin: Zig.Pin = { version = "0.16.0", shas = {} }
  local zig = assert(Zig.ensure_installed(tmp .. "/cache", install, pin, "x86_64-linux"))
  assert(zig == install .. "/zig")
end

local function test_a_failed_install_leaves_no_scratch_directory(tmp: string)
  local cache = tmp .. "/cache"
  local pin: Zig.Pin = { version = "0.16.0", shas = {} }
  local zig, trouble = Zig.ensure_installed(cache, cache .. "/0.16.0-x86_64-linux", pin,
    "x86_64-linux")
  assert(zig == nil and trouble:find("sha256", 1, true) ~= nil)
  assert(#assert(Fs.list(cache)) == 0, "a .work directory was left behind")
end

local function test_sweep_removes_a_dead_installs_scratch_but_not_a_live_one(tmp: string)
  local cache = tmp .. "/cache"
  -- Beyond any real pid limit, so no process can hold it.
  local dead = cache .. "/.work.2147483646"
  assert(Fs.mkdirs(dead .. "/zig-x"))
  assert(Fs.write(dead .. "/zig-x/zig", "partial"))
  local live = cache .. "/.work." .. tostring(sys.getpid())
  assert(Fs.mkdirs(live))
  assert(Fs.mkdirs(cache .. "/0.16.0-x86_64-linux"))
  Zig.sweep(cache)
  assert(Fs.exists(dead) == false)
  assert(Fs.exists(live) == true)
  assert(Fs.exists(cache .. "/0.16.0-x86_64-linux") == true)
end
