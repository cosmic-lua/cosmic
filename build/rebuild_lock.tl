--- The lock a run holds from the moment it finds it must rebuild or
--- boot the tool until it re-enters the command on the tool it wrote,
--- or exits (build/reboot.tl's `serialize`). Without it, two runs in one
--- checkout that both find the tool stale (an editor, a watcher and a
--- terminal, say) would rebuild it at once: each writes o/cosmic.db and
--- o/carried.db aside through the same fixed `.building` name
--- (`writer.write_result`, `writer.carried`), which the other removes
--- and writes into under it.
---
--- It is a `flock` of `o/rebuild.lock` and, on Linux, an SQLite write
--- lock on the same file as an empty database, a transaction nothing
--- writes. A tool from before the flock takes only SQLite's, which is an
--- fcntl lock. Linux keeps the two kinds of lock apart, so a run holding
--- only one would not exclude a run holding only the other: there this
--- tool takes both, the flock first and SQLite's second. No run then
--- holds SQLite's while it waits for the flock, so two runs taking both
--- cannot wait on each other, and one that holds the flock waits only on
--- a run holding SQLite's alone, which waits on nothing. macOS and the
--- BSDs keep the two in one list, where a whole-file flock conflicts
--- with any fcntl lock of another owner, this process's own SQLite
--- handle included: there the flock alone excludes both kinds of tool,
--- and taking SQLite's as well would find it always busy.
---
--- The system drops the lock with its descriptors, so a holder that dies
--- or execs (each is opened close-on-exec) never leaves it held. Closing
--- any descriptor of the file drops every fcntl lock the process holds
--- on it, so a holder opens and closes no other while it holds the lock.
--- A sandboxed test worker never takes it, since only the tree's own
--- tool (`reboot.own_tool`) rebuilds.
-- The SQLite half stays: any checkout can build a commit from before
-- the flock (a bisect, an older branch), and that tool takes only
-- SQLite's.
-- TODO: have a boot run by hand (`bin/zig build boot`, build/zig.tl)
-- take this lock too, so a run rebuilding the tool and a boot in the
-- same checkout wait for one another; a boot build/reboot.tl starts
-- (`reboot.boot_into`) would be handed the lock its parent holds, as
-- an environment variable naming it, rather than wait for it.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")

local record rebuild_lock
  --- What `take` found of the lock: this process holds it, or another
  --- run held it past the wait.
  enum Taken
    "held"
    "busy"
  end
end

local lock_name = "/o/rebuild.lock"

--- Where the holder writes its process id, for a waiting run to name it.
local holder_name = "/o/rebuild.lock.pid"

--- The lock's descriptor and SQLite handle, each nil once let go or
--- never taken.
local record Lock
  fd: integer | nil
  db: Sqlite.Handle | nil
  metamethod __close: function(Lock)
end

local lock_mt: metatable<Lock> = {
  __close = function(self: Lock)
    local db, fd = self.db, self.fd
    self.db, self.fd = nil, nil
    if db ~= nil then
      local _, _ = db:close()
    end
    if fd ~= nil then
      local _, _ = sys.close(fd)
    end
  end,
}

--- The lock this process holds, kept here so it lives as long as the
--- process does, or until the exec that replaces it.
local held: Lock | nil = nil

--- Whether this host keeps flock and fcntl locks apart, so the lock
--- takes SQLite's half too; nil and why when the host cannot be named.
-- TODO: answer false for a checkout on NFS, where Linux emulates flock
-- with a whole-file fcntl lock, which conflicts with this process's own
-- SQLite half as on macOS, so `take` always answers "busy" there; tell
-- the filesystem once cosmic.sys carries statfs.
local function kept_apart(): boolean | nil, string
  local names, trouble = sys.uname()
  if names == nil then
    return nil, "uname: " .. trouble
  end
  return names.sysname == "Linux", ""
end

--- Takes SQLite's half of the lock on `path` into `lock`, waiting up to
--- `wait_ms`. Answers "held", "busy", or nil and why.
local function take_sqlite(lock: Lock, path: string,
                           wait_ms: integer): rebuild_lock.Taken | nil, string
  local db, db_trouble = Sqlite.open(path, true)
  if db == nil then
    return nil, path .. ": " .. db_trouble
  end
  lock.db = db
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " ..
    tostring(wait_ms))
  if not timed then
    return nil, path .. ": " .. time_trouble
  end
  -- TODO: end this wait at a signal a Child.guard catches, as the
  -- flock's does, once cosmic.sqlite's busy wait checks for one.
  local begun, _ = db:exec("BEGIN IMMEDIATE")
  if not begun then
    return "busy", ""
  end
  return "held", ""
end

--- Takes the rebuild lock of `root`, waiting up to `wait_ms` (0 or
--- more) in all for a run that holds it. Answers "held" once this
--- process holds it, "busy" when another run held it past the wait, or
--- nil and why when the lock could not be asked for at all (its file
--- cannot be opened, a `Child.guard` caught a signal during the wait).
--- A half taken is let go again whenever the other is not.
function rebuild_lock.take(root: string, wait_ms: integer): rebuild_lock.Taken | nil, string
  if wait_ms < 0 then
    error("rebuild_lock.take: the wait is negative", 2)
  end
  if held ~= nil then
    return "held", ""
  end
  local both, platform_trouble = kept_apart()
  if both == nil then
    return nil, platform_trouble
  end
  local path = root .. lock_name
  local started_ns = Time.monotonic_ns()
  -- For writing, which an exclusive flock over SMB, or over NFS on
  -- macOS, needs.
  local fd, open_trouble = sys.open(path, sys.O_RDWR | sys.O_CREAT, 0x1a4)
  if fd == nil then
    return nil, path .. ": " .. open_trouble
  end
  local opened: Lock = { fd = fd }
  local taking <close> = setmetatable(opened, lock_mt)
  local flocked, flock_trouble, errno = sys.flock(fd, "exclusive", wait_ms)
  if not flocked then
    local name = sys.errno_name(errno)
    if name == "ETIMEDOUT" then
      return "busy", ""
    elseif name == "EINTR" then
      return nil, "interrupted while waiting for " .. path
    end
    return nil, path .. ": " .. flock_trouble
  end
  if both then
    local left_ms = wait_ms - (Time.monotonic_ns() - started_ns) // 1000000
    local taken, trouble = take_sqlite(taking, path, math.max(left_ms, 0))
    if taken == nil then
      return nil, trouble
    elseif taken == "busy" then
      return "busy", ""
    end
  end
  local holding: Lock = { fd = taking.fd, db = taking.db }
  taking.fd, taking.db = nil, nil
  setmetatable(holding, lock_mt)
  held = holding
  local _, _ = Fs.write(root .. holder_name, tostring(sys.getpid()) .. "\n")
  return "held", ""
end

--- Lets go of the rebuild lock this process holds, if it holds it.
function rebuild_lock.release()
  local lock = held
  held = nil
  if lock ~= nil then
    local _letting <close> = lock
  end
end

--- The run holding the lock under `root`, as a waiting run names it,
--- read once this run has failed to take it. The file may still name
--- the run before, which a new holder has not yet written over: a pid
--- no process answers to, or this one's own (a holder that re-entered
--- this process), is left unnamed. One a holder in another pid
--- namespace wrote -- a container sharing the checkout -- names what
--- that namespace called it, not a process here.
function rebuild_lock.holder(root: string): string
  local text, _ = Fs.read(root .. holder_name)
  local pid: integer | nil = nil
  if text ~= nil then
    pid = math.tointeger(tonumber(text:match("^(%d+)\n$")))
  end
  if pid ~= nil and pid ~= sys.getpid() then
    local alive, _ = sys.kill(pid, 0)
    if alive then
      return "another cosmic run (pid " .. tostring(pid) .. ")"
    end
  end
  return "another cosmic run"
end

return rebuild_lock
