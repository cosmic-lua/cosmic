--- `build/zig.tl`'s parts that need no network: pin parsing, the host
--- triple, argument rewriting, root detection, `PATH` lookup, the exit
--- statuses a failed exec means, the cache hit, the sweep of a dead
--- install's scratch directory, and the snapshots that catch a source
--- edited while a build runs.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Proc = require("cosmic.proc")
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
  local got = Zig.build_args("/repo", "/cache/zig-project", "/cache/zig-global", { "build", "-Doptimize=ReleaseFast" }, 4)
  assert(#got == 9)
  assert(got[1] == "build")
  assert(got[2] == "--cache-dir" and got[3] == "/cache/zig-project")
  assert(got[4] == "--global-cache-dir" and got[5] == "/cache/zig-global")
  assert(got[6] == "--prefix" and got[7] == "/repo/o")
  assert(got[8] == "-j8")
  assert(got[9] == "-Doptimize=ReleaseFast")
end

-- zig's default kept the three targets' vendored compiles one after another.
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
  local found, why = Zig.resolve("tool", path)
  assert(found == tmp .. "/b/tool" and why == "")
  -- A name with a slash is used as it is, never searched for.
  assert(Zig.resolve("./tool", path) == "./tool")
end

local function test_resolve_tells_a_missing_name_from_an_unrunnable_one(tmp: string)
  local none, missing = Zig.resolve("no-such-tool", tmp)
  assert(none == nil and missing == "no-such-tool: not found", missing)
  assert(Fs.write(tmp .. "/plain", "not executable", 0x1a4))
  local plain, denied = Zig.resolve("plain", tmp)
  assert(plain == nil and denied == tmp .. "/plain: not executable", denied)
end

--- `bin/zig` exits as a shell would when the zig it is given cannot
--- run: 127 when there is none on PATH, 126 when there is one that is
--- not executable.
local function test_main_exits_127_for_no_zig_and_126_for_an_unrunnable_one(tmp: string)
  local script = assert(Fs.absolute("build/zig.tl"))
  local function run(): Child.Result
    return (assert(Child.run({ assert(Proc.executable()), "--standalone", script, "version" }, {
      env = { COSMIC_ZIG = "zig-for-test", PATH = tmp .. ":/usr/bin:/bin",
        XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ms = 30000,
    })))
  end
  local missing = run()
  assert(missing.code == 127, tostring(missing.stderr))
  local missing_err = missing.stderr or ""
  assert(missing_err:find("zig-for-test: not found", 1, true), missing_err)
  assert(Fs.write(tmp .. "/zig-for-test", "not executable", 0x1a4))
  local denied = run()
  assert(denied.code == 126, tostring(denied.stderr))
  local denied_err = denied.stderr or ""
  assert(denied_err:find("zig-for-test: permission denied", 1, true), denied_err)
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

local function test_sources_try_a_few_shuffled_mirrors_then_ziglang_org()
  local mirrors = { "https://a", "https://b", "https://c", "https://d", "https://e", "https://f" }
  -- Swapping each place from the last down with the first rotates the
  -- list left by one: b c d e f a.
  local urls = Zig.sources("0.16.0", "zig.tar.xz", mirrors, function(_: integer): integer
    return 1
  end)
  local want = {
    "https://b/zig.tar.xz?source=cosmic",
    "https://c/zig.tar.xz?source=cosmic",
    "https://d/zig.tar.xz?source=cosmic",
    "https://e/zig.tar.xz?source=cosmic",
    "https://ziglang.org/download/0.16.0/zig.tar.xz",
  }
  assert(table.concat(urls, " ") == table.concat(want, " "), table.concat(urls, " "))
  -- Picking each place itself leaves the list as it was.
  local kept = Zig.sources("0.16.0", "zig.tar.xz", mirrors, function(n: integer): integer
    return n
  end)
  assert(kept[1] == "https://a/zig.tar.xz?source=cosmic", kept[1])
  local few = Zig.sources("0.16.0", "zig.tar.xz", { "https://m" })
  assert(#few == 2 and few[1] == "https://m/zig.tar.xz?source=cosmic")
end

--- A stand-in for Http.download that answers `replies[url]` in turn --
--- "ok" writes the file -- and records each call, the options it was
--- given (in `seen`, when passed) and each pause. Its clock moves only
--- by the pauses and by `per_call_ms` a download.
local function scripted(replies: {string:{string}}, calls: {string},
    sleeps: {integer}, per_call_ms?: integer, seen?: {Http.Options}): Zig.Fetcher
  local served: {string:integer} = {}
  local clock = 0
  return {
    download = function(url: string, path: string, opts: Http.Options): boolean, string
      assert(opts.sha256 == "abc")
      assert(opts.connect_timeout_ms > 0 and opts.low_speed_bytes >= 1024 and
        opts.low_speed_seconds > 0, "an attempt has no stall guard")
      assert(Fs.exists(path) == false, "an attempt started over an earlier file")
      calls[#calls + 1] = url
      if seen ~= nil then
        seen[#seen + 1] = opts
      end
      clock = clock + (per_call_ms or 0)
      served[url] = (served[url] or 0) + 1
      local reply = replies[url][served[url]] or replies[url][#replies[url]]
      if reply == "ok" then
        assert(Fs.write(path, "tarball"))
        return true, ""
      end
      return false, reply
    end,
    sleep = function(ms: integer)
      sleeps[#sleeps + 1] = ms
      clock = clock + ms
    end,
    now = function(): integer
      return clock
    end,
  }
end

local function test_fetch_falls_through_a_failing_source_to_the_next(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local path = tmp .. "/zig.tar.xz"
  assert(Fs.write(path, "left over"))
  local ok, trouble = Zig.fetch({ "http://one", "http://two" }, path, "abc", scripted({
    ["http://one"] = { "couldn't connect" },
    ["http://two"] = { "ok" },
  }, calls, sleeps))
  assert(ok, trouble)
  assert(#calls == 2 and calls[1] == "http://one" and calls[2] == "http://two")
  assert(#sleeps == 0)
  assert(Fs.read(path) == "tarball")
end

local function test_fetch_moves_past_a_sha_mismatch_and_never_asks_that_source_again(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local ok, trouble = Zig.fetch({ "http://bad", "http://slow" }, tmp .. "/z", "abc", scripted({
    ["http://bad"] = { "z: sha256 mismatch: want abc, got def" },
    ["http://slow"] = { "timed out", "ok" },
  }, calls, sleeps))
  assert(ok, trouble)
  assert(table.concat(calls, " ") == "http://bad http://slow http://slow", table.concat(calls, " "))
  assert(#sleeps == 1 and sleeps[1] > 0, "no pause before the second round")
end

local function test_fetch_names_every_source_when_all_fail(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local ok, trouble = Zig.fetch({ "http://one", "http://two", "http://three" }, tmp .. "/z", "abc",
    scripted({
      ["http://one"] = { "couldn't connect" },
      ["http://two"] = { "z: sha256 mismatch: want abc, got def" },
      ["http://three"] = { "http://three: HTTP 404" },
    }, calls, sleeps))
  assert(not ok)
  assert(trouble:find("http://one: couldn't connect", 1, true) ~= nil, trouble)
  assert(trouble:find("http://two: z: sha256 mismatch", 1, true) ~= nil, trouble)
  assert(trouble:find("http://three: HTTP 404", 1, true) ~= nil, trouble)
  assert(trouble:find("http://three: http://three", 1, true) == nil, trouble)
  -- Bounded: two sources a round for three rounds, and the bad one once.
  assert(#calls == 7, tostring(#calls))
  assert(#sleeps == 2 and sleeps[2] > sleeps[1], "the pause does not grow")
  assert(Fs.exists(tmp .. "/z") == false)
end

local function test_fetch_asks_the_fallback_again_after_a_mismatch(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local ok, trouble = Zig.fetch({ "http://mirror", "http://fallback" }, tmp .. "/z", "abc",
    scripted({
      ["http://mirror"] = { "z: sha256 mismatch: want abc, got def" },
      ["http://fallback"] = { "z: sha256 mismatch: want abc, got 123", "ok" },
    }, calls, sleeps))
  assert(ok, trouble)
  assert(table.concat(calls, " ") == "http://mirror http://fallback http://fallback",
    table.concat(calls, " "))
end

--- Mirrors are held to a ceiling cut to what is left of the budget;
--- the fallback has none, and once the budget is spent it is tried one
--- last time on its own.
local function test_fetch_bounds_mirrors_by_the_budget_and_never_the_fallback(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local seen: {Http.Options} = {}
  -- Each attempt takes five minutes, and the budget is twelve.
  local ok, trouble = Zig.fetch({ "http://mirror", "http://fallback" }, tmp .. "/z", "abc",
    scripted({
      ["http://mirror"] = { "timed out" },
      ["http://fallback"] = { "stalled" },
    }, calls, sleeps, 5 * 60 * 1000, seen))
  assert(not ok)
  assert(table.concat(calls, " ") ==
    "http://mirror http://fallback http://mirror http://fallback http://fallback",
    table.concat(calls, " "))
  -- The first mirror attempt gets the whole 3 minutes; the second, 10
  -- minutes and a 2 s pause in, the 118 s left.
  assert(seen[1].timeout_ms == 3 * 60 * 1000, tostring(seen[1].timeout_ms))
  assert(seen[3].timeout_ms == 118 * 1000, tostring(seen[3].timeout_ms))
  assert(seen[1].low_speed_bytes == 64 * 1024)
  for _, i in ipairs({ 2, 4, 5 }) do
    assert(seen[i].timeout_ms == nil, "the fallback has a ceiling")
    assert(seen[i].low_speed_bytes == 1024 and seen[i].low_speed_seconds == 60)
  end
  assert(trouble:find("mirrors out of time; every source failed after 5 attempts", 1, true) ~= nil,
    trouble)
  assert(trouble:find("http://mirror: timed out (after 300 s)", 1, true) ~= nil, trouble)
end

--- The real Http.download, answered by a scripted server with the wrong
--- body: its message is what Zig.fetch reads a mismatch from, so a
--- change in that text fails here rather than retrying a bad mirror.
local function test_fetch_sees_a_real_mismatch(tmp: string)
  local calls: {string} = {}
  local fetcher: Zig.Fetcher = {
    download = function(url: string, path: string, opts: Http.Options): boolean, string
      calls[#calls + 1] = url
      opts.script = { "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nwrong" }
      return Http.download(url, path, opts)
    end,
    sleep = function(_: integer) end,
    now = function(): integer return 0 end,
  }
  local ok, trouble = Zig.fetch({ "http://127.0.0.1/a", "http://127.0.0.1/b" }, tmp .. "/z",
    string.rep("0", 64), fetcher)
  assert(not ok)
  assert(trouble:find("sha256 mismatch", 1, true) ~= nil, trouble)
  -- The mirror once; the fallback, never barred, each round.
  assert(table.concat(calls, " ") ==
    "http://127.0.0.1/a http://127.0.0.1/b http://127.0.0.1/b http://127.0.0.1/b",
    table.concat(calls, " "))
  assert(Fs.exists(tmp .. "/z") == false)
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

local function test_run_answers_as_the_child_did()
  assert(Zig.run({ "/bin/sh", "-c", "exit 0" }) == 0)
  assert(Zig.run({ "/bin/sh", "-c", "exit 3" }) == 3)
  assert(Zig.run({ "/bin/sh", "-c", "kill -KILL $$" }) == 128 + sys.SIGKILL)
end

local function test_run_passes_on_a_signal_sent_to_it_alone()
  -- The child has this process interrupted, as a `kill -INT` aimed at
  -- bin/zig alone would; the child hears of it only if it is passed on.
  local started = Time.monotonic_ns()
  local status = Zig.run({ "/bin/sh", "-c",
    "trap 'exit 42' INT; kill -INT $PPID; sleep 10 & wait" })
  assert(status == 42, tostring(status))
  assert(Time.monotonic_ns() - started < 5 * 1000 * 1000 * 1000)
end
