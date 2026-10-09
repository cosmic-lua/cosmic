--- The bootstrap's lock against a SQLite-only older process. fcntl
--- locks belong to a process, so another handle here cannot prove that
--- the lock excludes an older tool or survives a handoff.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")
local Zig = require("build.zig")
local build_paths = require("build.paths")
local this_program = require("build.this_program")
local type _ = require("build.standalone")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "build/paths.tl", letters = "r" } } }

--- An older tool takes only SQLite's transaction. A negative wait keeps
--- its hold until stdin closes; zero is a nonblocking probe.
local sql_tool = [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local db = assert(Sqlite.open(%q .. "/o/rebuild.lock", { writable = true }))
assert(db:exec("PRAGMA busy_timeout = 0"))
if not db:exec("BEGIN IMMEDIATE") then print("busy"); return end
print("held")
local wait = %d
if wait < 0 then Fs.take(Fs.stdin, 1) else Clock.sleep_ns(wait) end
]]

local flock_tool = [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local fd = assert(sys.open(%q .. "/o/rebuild.lock", sys.O_RDWR | sys.O_CREAT, 0x1a4))
if not sys.flock(fd, "exclusive", 0) then print("busy"); return end
print("held")
local wait = %d
if wait < 0 then Fs.take(Fs.stdin, 1) else Clock.sleep_ns(wait) end
]]

local function start(root: string, wait_ns: integer, flock?: boolean): Child.Handle, string
  local started = this_program.program({ "-e", (flock and flock_tool or sql_tool):format(root, wait_ns) },
    { stdin = "stream", stdout = "stream", stderr = "capture" })
  local child = assert(Child.start(started.argv, started.options))
  local line = assert(Stream.lines(assert(child.stdout_stream)):read())
  return child, line
end

local function finish(child: Child.Handle)
  assert(assert(child.stdin_stream):close())
  local result = assert(child:wait(Clock.seconds(20)))
  assert(result.ok, result.stderr)
end

local function probe(root: string): string
  local child, said = start(root, 0)
  finish(child)
  return said
end

local function tree(tmp: string): string
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  return root
end

local function test_a_boot_excludes_a_sqlite_only_tool_and_releases_on_return(tmp: string)
  local root = tree(tmp)
  local env = { KEPT = "value", COSMIC_REBUILD_LOCK_HANDED = "/stale" }
  local status = Zig.with_lock(build_paths.required(root), env, function(handed: {string:string}): integer
    assert(probe(root) == "busy", "a SQL-only tool entered the boot's lock")
    assert(handed.KEPT == "value")
    assert(handed.COSMIC_REBUILD_LOCK_HANDED == root .. "/o/rebuild.lock")
    assert(Fs.read(root .. "/o/rebuild.lock.pid") == tostring(sys.getpid()) .. "\nrebuild\n")
    return 7
  end)
  assert(status == 7)
  assert(env.COSMIC_REBUILD_LOCK_HANDED == "/stale", "handoff changed its caller's environment")
  assert(probe(root) == "held", "the lock outlived the build")
end

local function test_a_boot_waits_for_a_sqlite_only_tool_even_with_a_wrong_handoff(tmp: string)
  local root = tree(tmp)
  assert(Fs.write(tmp .. "/other-lock", ""))
  local old, said = start(root, -1)
  assert(said == "held", said)
  local script = [[
local Fs = require("cosmic.fs")
require("build.zig").with_lock(%q, { COSMIC_REBUILD_LOCK_HANDED = %q }, function()
  print("held")
  Fs.take(Fs.stdin, 1)
  return 0
end)
]]
  local started = this_program.program({ "-e", script:format(build_paths.required(root), tmp .. "/other-lock") },
    { stdin = "stream", stdout = "stream", stderr = "stream" })
  local boot = assert(Child.start(started.argv, started.options))
  local waiting = Stream.lines(assert(boot.stderr_stream)):read()
  finish(old)
  local entered = Stream.lines(assert(boot.stdout_stream)):read()
  local held = probe(root)
  finish(boot)
  assert(waiting ~= nil and waiting:find("waiting for it", 1, true), tostring(waiting))
  assert(entered == "held", tostring(entered))
  assert(held == "busy", "a waiting boot did not take the released lock")
  assert(probe(root) == "held")
end

local function test_a_handoff_uses_file_identity_and_keeps_the_parents_hold(tmp: string)
  local root = tree(tmp)
  local old, said = start(root, -1)
  assert(said == "held", said)
  local ok, trouble: boolean, any = pcall(function()
    assert(Zig.with_lock(build_paths.required(root), { COSMIC_REBUILD_LOCK_HANDED = root .. "/./o/rebuild.lock" },
      function(env: {string:string}): integer
        assert(env.COSMIC_REBUILD_LOCK_HANDED == root .. "/o/rebuild.lock")
        assert(probe(root) == "busy", "handoff released its parent's hold")
        return 0
      end) == 0)
    assert(probe(root) == "busy", "closing a handed build released its parent's hold")
  end)
  finish(old)
  assert(ok, trouble)
  assert(probe(root) == "held")
end

local function test_an_exception_releases_the_lock_before_it_is_rethrown(tmp: string)
  local root = tree(tmp)
  local marker = {}
  local ok, trouble: boolean, any = pcall(Zig.with_lock, build_paths.required(root), {}, function(): integer
    assert(probe(root) == "busy")
    error(marker)
  end)
  assert(not ok and trouble == marker, "the build's exception changed")
  assert(probe(root) == "held", "an exceptional build retained its lock")
end

--- Acquisition writes its holder metadata after taking the transaction.
--- A failure there is covered by the same scope as the build itself.
local function test_an_exception_during_acquisition_releases_the_lock(tmp: string)
  local root = tree(tmp)
  local write = Fs.write
  Fs.write = function(): boolean, string
    error("holder write failed", 0)
  end
  local ok, trouble: boolean, any = pcall(Zig.with_lock, build_paths.required(root), {}, function(): integer
    error("a build ran after acquisition raised")
  end)
  Fs.write = write
  assert(not ok and trouble == "holder write failed", tostring(trouble))
  assert(probe(root) == "held", "exceptional acquisition retained its lock")
end

--- Exercise main's watched-build boundary, before it starts any child.
local function test_a_snapshot_exception_releases_mains_lock(tmp: string)
  local root = tree(tmp)
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/zig.tl", ""))
  assert(Fs.write(root .. "/build/paths.tl", (assert(Fs.read("build/paths.tl")))))
  local fake = tmp .. "/zig"
  assert(Fs.write(fake, "", 0x1ed))
  local get, snapshot = Env.get, Zig.snapshot
  Env.get = function(name: string): string | nil
    return name == "COSMIC_ZIG" and fake or get(name)
  end
  Zig.snapshot = function(): {string:string} | nil, string
    error("snapshot failed", 0)
  end
  local ok, trouble: boolean, any = pcall(Zig.main,
    { [0] = root .. "/build/zig.tl", "build", "boot" } as {integer:string})
  Env.get, Zig.snapshot = get, snapshot
  assert(not ok and trouble == "snapshot failed", tostring(trouble))
  assert(probe(root) == "held", "main retained its lock after a snapshot exception")
end

local function test_a_boot_holds_flock_and_releases_it_on_return(tmp: string)
  local root = tree(tmp)
  assert(Zig.with_lock(build_paths.required(root), {}, function(): integer
    local child, said = start(root, 0, true)
    finish(child)
    assert(said == "busy", "a flock-only process entered the boot's lock")
    return 0
  end) == 0)
  local child, said = start(root, 0, true)
  finish(child)
  assert(said == "held", "the bootstrap retained its flock")
end

local function test_a_handoff_keeps_a_flock_only_parents_hold(tmp: string)
  local root = tree(tmp)
  local old, said = start(root, -1, true)
  assert(said == "held")
  assert(Zig.with_lock(build_paths.required(root), { COSMIC_REBUILD_LOCK_HANDED = root .. "/./o/rebuild.lock" },
    function(): integer
      local child, probe_said = start(root, 0, true)
      finish(child)
      assert(probe_said == "busy")
      return 0
    end) == 0)
  finish(old)
end

local function test_a_wait_for_a_sql_only_tool_can_be_cancelled_without_consuming_the_guard(tmp: string)
  local root = tree(tmp)
  local fd = assert(sys.open(root .. "/o/rebuild.lock", sys.O_RDWR | sys.O_CREAT, 0x1a4))
  local kind, trouble = sys.flock_kind(fd)
  assert(sys.close(fd))
  assert(kind, trouble)
  local old <close>, held = start(root, -1)
  assert(held == "held")
  local script = [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Zig = require("build.zig")
local guard <close> = assert(Child.guard())
local status = Zig.with_lock(%q, {}, function() error("entered a held lock") end)
local signal = guard:take()
guard:release()
assert(status == 1 and signal == sys.SIGTERM)
print("cancelled")
Fs.take(Fs.stdin, 1)
]]
  local command = this_program.program({ "-e", script:format(build_paths.required(root)) },
    { stdin = "stream", stdout = "stream", stderr = "stream" })
  local boot <close> = assert(Child.start(command.argv, command.options))
  local waiting = Stream.lines(assert(boot.stderr_stream)):read()
  assert(waiting ~= nil and waiting:find("waiting for it", 1, true), waiting)
  local began = Clock.monotonic_ns()
  assert(boot:stop(sys.SIGTERM))
  local cancelled = Stream.lines(assert(boot.stdout_stream)):read()
  assert(cancelled == "cancelled", cancelled)
  assert(Clock.monotonic_ns() - began < Clock.seconds(2), "lock wait ignored cancellation")
  assert(not assert(boot:try_wait()).finished, "cancelled waiter exited before cleanup was probed")
  assert(probe(root) == "busy", "cancellation released the older tool's SQL lock")
  local probe_child, said = start(root, 0, true)
  finish(probe_child)
  -- A shared lock space keeps flock excluded by the older SQL holder.
  -- Apart locks must already be free, without process exit hiding a leak.
  assert(said == (kind == "apart" and "held" or "busy"), "cancellation changed the wrong flock hold")
  finish(old)
  local released, after = start(root, 0, true)
  finish(released)
  assert(after == "held", "cancelled waiter retained its flock descriptor")
  assert(probe(root) == "held", "cancelled waiter retained its SQL lock")
  assert(not assert(boot:try_wait()).finished, "cleanup relied on the cancelled waiter's exit")
  finish(boot)
end
