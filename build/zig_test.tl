--- [`build/zig.tl`]'s parts that need no network: pin parsing, the host
--- triple, argument rewriting, root detection, `PATH` lookup, the exit
--- statuses a failed exec means, the cache hit, and the snapshots that
--- catch a source edited while a build runs, the rebuild lock a boot
--- holds, and what [`Zig.run`] answers of a stand-in zig
--- ([`build.stand_in`]). The tests
--- that start bin/zig are build/zig_tool_test.tl's.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
local rebuild_lock = require("build.rebuild_lock")
local stand_in = require("build.stand_in")
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
  local got = Zig.build_args("/repo", "/cache/zig-project", "/cache/zig-global", { "build", "-Doptimize=ReleaseFast" }, 4)
  assert(#got == 9)
  assert(got[1] == "build")
  assert(got[2] == "--cache-dir" and got[3] == "/cache/zig-project")
  assert(got[4] == "--global-cache-dir" and got[5] == "/cache/zig-global")
  assert(got[6] == "--prefix" and got[7] == "/repo/o")
  assert(got[8] == "-j8")
  assert(got[9] == "-Doptimize=ReleaseFast")
end

-- Twice the processors, at least 8: under zig's default the three targets'
-- vendored compiles run one after another.
local function test_build_args_run_steps_past_the_processor_count()
  assert(Zig.build_jobs(1) == 8)
  assert(Zig.build_jobs(4) == 8)
  assert(Zig.build_jobs(16) == 32)
  local got = Zig.build_args("/repo", "/cache/zig-project", "/cache/zig-global", { "build", "boot" }, 16)
  assert(got[8] == "-j32" and got[9] == "boot")
end

local function test_build_args_keep_the_callers_jobs()
  local got = Zig.build_args("/repo", "/cache/zig-project", "/cache/zig-global", { "build", "-j2", "boot" }, 16)
  assert(#got == 9)
  assert(got[8] == "-j2" and got[9] == "boot")
end

local function test_build_args_passes_other_subcommands_through()
  local got = Zig.build_args("/repo", "/cache/zig-project", "/cache/zig-global", { "version" }, 4)
  assert(#got == 1 and got[1] == "version")
end

--- A zig command other than `build` runs with zig's caches where `build`
--- puts them, unless the caller names its own.
local function test_other_subcommands_use_the_build_s_caches()
  local got = Zig.passthrough_environment("/repo", { COSMIC_ZIG_GLOBAL_CACHE = "/g",
    COSMIC_ZIG_CACHE = "/p", PATH = "/bin" })
  assert(got.ZIG_GLOBAL_CACHE_DIR == "/g" and got.ZIG_LOCAL_CACHE_DIR == "/p" and
    got.PATH == "/bin")
  local kept = Zig.passthrough_environment("/repo", { COSMIC_ZIG_GLOBAL_CACHE = "/g",
    COSMIC_ZIG_CACHE = "/p", ZIG_GLOBAL_CACHE_DIR = "/mine" })
  assert(kept.ZIG_GLOBAL_CACHE_DIR == "/mine" and kept.ZIG_LOCAL_CACHE_DIR == "/p")
end

-- The global cache is shared: named outright, else in this user's cache
-- directory, and in the checkout only when there is no cache directory.
local function test_global_cache_is_named_then_shared_then_local(tmp: string)
  assert(Zig.global_cache("/repo", { COSMIC_ZIG_GLOBAL_CACHE = "/ci/zig-global",
    XDG_CACHE_HOME = tmp }) == "/ci/zig-global")
  assert(Zig.global_cache("/repo", { XDG_CACHE_HOME = tmp }) == tmp .. "/cosmic/zig-global")
  assert(Zig.global_cache("/repo", {}) == "/repo/o/zig-global")
end

-- The project cache is shared as the global one is: a fresh worktree then
-- compiles nothing under vendor/ that another checkout already has.
local function test_project_cache_is_named_then_shared_then_local(tmp: string)
  assert(Zig.project_cache("/repo", { COSMIC_ZIG_CACHE = "/ci/zig-cache",
    XDG_CACHE_HOME = tmp }) == "/ci/zig-cache")
  assert(Zig.project_cache("/repo", { XDG_CACHE_HOME = tmp }) == tmp .. "/cosmic/zig-project")
  assert(Zig.project_cache("/repo", {}) == "/repo/o/zig-cache")
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
  local found = Zig.resolve("tool", path)
  assert(found.kind == "resolved" and found.path == tmp .. "/b/tool" and found.reason == "")
  -- A name with a slash is used as it is, never searched for.
  assert(Zig.resolve("./tool", path).path == "./tool")
end

local function test_resolve_tells_a_missing_name_from_an_unrunnable_one(tmp: string)
  local missing = Zig.resolve("no-such-tool", tmp)
  assert(missing.kind == "not_found" and missing.reason == "no-such-tool: not found", missing.reason)
  assert(Fs.write(tmp .. "/plain", "not executable", 0x1a4))
  local denied = Zig.resolve("plain", tmp)
  assert(denied.kind == "not_executable" and denied.reason == tmp .. "/plain: not executable", denied.reason)
end

local function test_exec_status_is_the_shells()
  assert(Zig.exec_status(sys.ENOENT) == 127)
  assert(Zig.exec_status(sys.EACCES) == 126)
end

local SHA_A <const> = "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
local SHA_B <const> = "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17"

local function test_install_name_holds_the_version_host_and_a_sha_prefix()
  local pin: Zig.Pin = { version = "0.16.0", shas = { ["x86_64-linux"] = SHA_A } }
  assert(Zig.install_name(pin, "x86_64-linux") == "0.16.0-x86_64-linux-70e49664a74374b4")
  local none, trouble = Zig.install_name(pin, "aarch64-linux")
  assert(none == nil and trouble == "names no sha256 for aarch64-linux", trouble)
  for _, malformed in ipairs({ "../../etc", SHA_A:sub(2), SHA_A .. "0" }) do
    pin.shas["aarch64-linux"] = malformed
    local bad, why = Zig.install_name(pin, "aarch64-linux")
    assert(bad == nil and why:find("64 hex digits", 1, true) ~= nil, malformed .. ": " .. why)
  end
  -- A sha written in capitals names the same install.
  pin.shas["aarch64-linux"] = SHA_A:upper()
  assert(Zig.install_name(pin, "aarch64-linux") == "0.16.0-aarch64-linux-70e49664a74374b4")
end

--- A root holding only a [`bin/zig.pin`] naming `sha256` for this host.
local function pinned_root(dir: string, version: string, sha256: string): string
  local names = assert(sys.uname())
  local host = assert(Zig.host(names.sysname, names.machine))
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.write(dir .. "/bin/zig.pin", "version " .. version .. "\n" .. host .. " " .. sha256 .. "\n"))
  return dir
end

local function test_a_pin_whose_sha256_alone_changed_names_another_install(tmp: string)
  local old = assert(Zig.pinned_install(pinned_root(tmp .. "/old", "0.16.0", SHA_A), "/cache"))
  local new = assert(Zig.pinned_install(pinned_root(tmp .. "/new", "0.16.0", SHA_B), "/cache"))
  assert(old.path ~= new.path, old.path)
  local again = assert(Zig.pinned_install(pinned_root(tmp .. "/again", "0.16.0", SHA_A), "/cache"))
  assert(again.path == old.path, again.path)
end

local function test_ensure_installed_is_a_cache_hit_when_zig_is_already_there(tmp: string)
  local install = tmp .. "/cache/0.16.0-x86_64-linux"
  assert(Fs.mkdirs(install))
  assert(Fs.write(install .. "/zig", "#!/bin/sh\necho stand-in\n", 0x1ed))
  -- No sha for the host and no root to fetch from: a miss would fail loudly.
  local pin: Zig.Pin = { version = "0.16.0", shas = {} }
  local zig = assert(Zig.ensure_installed(tmp .. "/root", tmp .. "/cache", install, pin, "x86_64-linux"))
  assert(zig == install .. "/zig")
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

local function test_snapshot_follows_a_link_as_staging_does(tmp: string)
  local root = sources(tmp)
  assert(Fs.mkdirs(tmp .. "/shared"))
  assert(Fs.write(tmp .. "/shared/b.c", "text"))
  assert(Fs.symlink("../../shared", root .. "/core/shared"))
  local seen = assert(Zig.snapshot(root))
  assert(seen["core/shared/b.c"] ~= nil, "a file reached through a link was not watched")
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
  assert(Fs.set_mtime(root .. "/vendor/lua/lua.c", 1000000000))
  local before = assert(Zig.snapshot(root))
  assert(Fs.set_mtime(root .. "/vendor/lua/lua.c", 1000000001))
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

local function test_run_answers_as_the_child_did(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(Zig.run({ probe, "exit 0" }) == 0)
  assert(Zig.run({ probe, "exit 3" }) == 3)
  assert(Zig.run({ probe, "signal KILL" }) == 128 + sys.SIGKILL)
end

local function test_run_passes_on_a_signal_sent_to_it_alone(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- The child has this process interrupted, as a `kill -INT` aimed at
  -- bin/zig alone would; the child hears of it only if it is passed on.
  local started = Time.monotonic_ns()
  local status = Zig.run({ probe,
    "trap 42; signal INT " .. tostring(sys.getpid()) .. "; sleep 10000" })
  assert(status == 42, tostring(status))
  assert(Time.monotonic_ns() - started < 5 * 1000 * 1000 * 1000)
end

--- A build of the boot step holds the checkout's rebuild lock, as a
--- `cosmic test` run and a rebuild of the tool do (build.rebuild_lock),
--- to its end; a build of any other step takes none.
local function test_boot_steps_need_the_rebuild_lock()
  assert(Zig.boots({ "build", "boot" }))
  assert(Zig.boots({ "build", "cores", "boot" }))
  assert(Zig.boots({ "build", "sanitized" }))
  assert(not Zig.boots({ "build", "cores" }))
  assert(not Zig.boots({ "boot" }))
end

--- build/zig.tl, which keeps its own copy of build/rebuild_lock.tl's
--- roles and of how it reads the holder file, names a holder of the lock
--- as that module does: each role, one it does not know, none, and a pid
--- no process answers to or this one's own.
local function test_a_boot_names_a_holder_as_the_tool_does(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  local contents: {string} = { "1\nnone\n", "1\n", "", "x\ntest\n",
    tostring(sys.getpid()) .. "\ntest\n" }
  for _, role in ipairs({ "test", "rebuild", "write" }) do
    contents[#contents + 1] = "1\n" .. role .. "\n"
  end
  for _, text in ipairs(contents) do
    assert(Fs.write(root .. "/o/rebuild.lock.pid", text))
    assert(Zig.holder(root) == rebuild_lock.holder(root), text .. ": " ..
      Zig.holder(root) .. " against " .. rebuild_lock.holder(root))
  end
end

--- A lock file this process cannot write would lock nothing (SQLite
--- opens it read-only), so a boot refuses it, saying why, rather than
--- build unheld. Run as root, which writes it anyway, there is nothing
--- to see.
local function test_a_boot_refuses_a_lock_file_it_cannot_write(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  assert(Fs.write(root .. "/o/rebuild.lock", "", 0x124))
  local fd, _ = sys.open(root .. "/o/rebuild.lock", sys.O_RDWR, 0)
  if fd ~= nil then
    assert(sys.close(fd))
    return
  end
  local status = Zig.with_lock(root, {}, function(): integer
    error("a boot ran without a writable lock")
  end)
  assert(status == 1)
end

local function test_lookup_exit_status_uses_kind_without_another_lookup(tmp: string)
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/zig.tl", "-- stand-in"))
  local real_find, real_get = Proc.find_result, Env.get
  local calls = 0
  local reply: Proc.FindResult = { kind = "not_executable", path = "tool", reason = "tool: not found" }
  Proc.find_result = function(_name: string, _path?: string): Proc.FindResult
    calls = calls + 1
    return reply
  end
  Env.get = function(name: string): string | nil
    if name == "COSMIC_ZIG" then return "tool" end
    return nil
  end
  local denied = Zig.main({ [0] = tmp .. "/build/zig.tl", "version" })
  reply = { kind = "not_found", reason = "tool: not executable" }
  local missing = Zig.main({ [0] = tmp .. "/build/zig.tl", "version" })
  Proc.find_result, Env.get = real_find, real_get
  assert(denied == 126 and missing == 127 and calls == 2)
end

local function test_boot_lock_classifies_the_begin_result_not_its_reason(tmp: string)
  local real_open, real_kind = Sqlite.open, sys.flock_kind
  sys.flock_kind = function(_fd: integer): string | nil, string, integer
    return "apart", "", 0
  end
  local outcomes: {Sqlite.ExecResult} = {
    { code = Sqlite.BUSY, extended_code = Sqlite.BUSY, reason = "another connection owns it" },
    { code = 6, extended_code = 6, reason = "database table is locked" },
    { code = 1, extended_code = 1, reason = "busy appears in this unrelated failure" },
    { code = Sqlite.BUSY, extended_code = Sqlite.BUSY, reason = "interrupted", cancelled = true },
  }
  local statuses, attempts, closures: {integer}, {integer}, {integer} = {}, {}, {}
  for i, outcome in ipairs(outcomes) do
    local calls, closes = 0, 0
    Sqlite.open = function(_path: string, _opts?: Sqlite.OpenOptions): Sqlite.Handle | nil, string
      local fake = {
        busy_timeout = function(_self: any, ns: integer) assert(ns >= 0) end,
        exec_result = function(_self: any, sql: string): Sqlite.ExecResult
          assert(sql == "BEGIN IMMEDIATE")
          calls = calls + 1
          if calls == 1 then return outcome end
          return { code = Sqlite.OK, extended_code = Sqlite.OK, reason = "" }
        end,
        close = function(_self: any): boolean, string
          closes = closes + 1
          return true, ""
        end,
      }
      return fake as Sqlite.Handle, ""
    end
    statuses[i] = Zig.with_lock(tmp .. "/" .. i, {}, function(_env: {string:string}): integer
      return 7
    end)
    attempts[i], closures[i] = calls, closes
  end
  Sqlite.open, sys.flock_kind = real_open, real_kind
  assert(statuses[1] == 7 and attempts[1] == 2)
  assert(statuses[2] == 1 and attempts[2] == 1)
  assert(statuses[3] == 1 and attempts[3] == 1)
  assert(statuses[4] == 1 and attempts[4] == 1 and closures[4] == 1)
  assert(closures[1] == 1 and closures[2] == 1 and closures[3] == 1)
end
