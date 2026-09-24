--- `build/zig.tl`'s parts that need no network: pin parsing, the host
--- triple, argument rewriting, root detection, `PATH` lookup, the exit
--- statuses a failed exec means, the cache hit, the sweep of a dead
--- install's scratch directory, and the snapshots that catch a source
--- edited while a build runs.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
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

--- A small tree shaped like the repository's, with a file in each
--- place a build reads and in each place it does not.
local function sources(tmp: string): string
  local root = tmp .. "/repo"
  for _, dir in ipairs({ "core", "vendor/lua", "test/portable", "doc/guides", "o", "ci",
      "bin", ".git" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  for _, file in ipairs({ "build.zig", "bin/zig.pin", "core/a.c", "vendor/lua/lua.c",
      "test/portable/probe.c", "test/unit_test.tl", "doc/guides/start.md", "doc/design.md",
      "o/build.db", "ci/run.tl", "bin/zig", ".git/HEAD", "test/notes.txt" }) do
    assert(Fs.write(root .. "/" .. file, "text"))
  end
  return root
end

local function test_snapshot_holds_what_a_build_reads_and_nothing_else(tmp: string)
  local seen = assert(Zig.snapshot(sources(tmp)))
  local paths: {string} = {}
  for path in pairs(seen) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  assert(table.concat(paths, " ") == "bin/zig.pin build.zig core/a.c doc/guides/start.md " ..
    "test/portable/probe.c test/unit_test.tl vendor/lua/lua.c", table.concat(paths, " "))
end

local function test_a_file_whose_size_changed_is_named(tmp: string)
  local root = sources(tmp)
  local before = assert(Zig.snapshot(root))
  assert(Fs.write(root .. "/core/a.c", "text, and a comment"))
  local moved = Zig.changed(before, (assert(Zig.snapshot(root))))
  assert(#moved == 1 and moved[1] == "core/a.c", table.concat(moved, " "))
end

local function test_a_file_whose_mtime_alone_changed_is_named(tmp: string)
  local root = sources(tmp)
  assert(Fs.set_mtime(root .. "/vendor/lua/lua.c", 1000000000, 1000000000))
  local before = assert(Zig.snapshot(root))
  assert(Fs.set_mtime(root .. "/vendor/lua/lua.c", 1000000000, 1000000001))
  local moved = Zig.changed(before, (assert(Zig.snapshot(root))))
  assert(#moved == 1 and moved[1] == "vendor/lua/lua.c", table.concat(moved, " "))
end

local function test_added_and_removed_files_are_named_and_unread_ones_are_not(tmp: string)
  local root = sources(tmp)
  local before = assert(Zig.snapshot(root))
  assert(Fs.write(root .. "/core/b.h", "new"))
  assert(Fs.remove(root .. "/test/portable/probe.c"))
  assert(Fs.write(root .. "/o/build.db", "the build's own output, rewritten"))
  assert(Fs.write(root .. "/doc/design.md", "prose, rewritten"))
  local moved = Zig.changed(before, (assert(Zig.snapshot(root))))
  assert(table.concat(moved, " ") == "core/b.h test/portable/probe.c", table.concat(moved, " "))
end

local function test_an_unchanged_tree_moves_nothing(tmp: string)
  local root = sources(tmp)
  local before = assert(Zig.snapshot(root))
  assert(#Zig.changed(before, (assert(Zig.snapshot(root)))) == 0)
end

local function test_race_report_names_five_paths_then_counts_the_rest()
  assert(Zig.race_report({ "core/a.c" }) ==
    "sources changed during the build: core/a.c; run it again")
  local many: {string} = {}
  for i = 1, 8 do
    many[i] = "core/" .. tostring(i) .. ".c"
  end
  assert(Zig.race_report(many) == "sources changed during the build: " ..
    "core/1.c, core/2.c, core/3.c, core/4.c, core/5.c and 3 more; run it again",
    Zig.race_report(many))
end

local function test_child_status_is_the_shells()
  assert(Zig.child_status({ code = 0, ok = true, timed_out = false, captured = {},
    truncated = false }) == 0)
  assert(Zig.child_status({ code = 3, ok = false, timed_out = false, captured = {},
    truncated = false }) == 3)
  assert(Zig.child_status({ signal = sys.SIGKILL, ok = false, timed_out = false,
    captured = {}, truncated = false }) == 128 + sys.SIGKILL)
end

local function test_run_answers_as_the_child_did()
  assert(Zig.run({ "/bin/sh", "-c", "exit 0" }) == 0)
  assert(Zig.run({ "/bin/sh", "-c", "exit 3" }) == 3)
  assert(Zig.run({ "/bin/sh", "-c", "kill -KILL $$" }) == 128 + sys.SIGKILL)
end

local function test_run_passes_on_a_signal_sent_to_it_alone()
  -- The child has this process interrupted, as a `kill -INT` aimed at
  -- bin/zig alone would; the child hears of it only if it is passed on.
  local started = assert(Time.monotonic_ns())
  local status = Zig.run({ "/bin/sh", "-c",
    "trap 'exit 42' INT; kill -INT $PPID; sleep 10 & wait" })
  assert(status == 42, tostring(status))
  assert(assert(Time.monotonic_ns()) - started < 5 * 1000 * 1000 * 1000)
end
