--- A checkout's `rebuild.lock`, in its build directory, makes one run at a
--- time rebuild or boot the tool, run the tree's tests, or write its
--- projection, `cosmic.db`.
---
--- `cosmic test` holds it for its whole run ([`build.test`]), so a second
--- run in the checkout waits for the first: one run's closure stores,
--- its sweep of them ([`build.test`]'s `sweep_stores`) and its projection
--- are never another's to remove or write under it. A run that finds
--- the tool stale holds it from then until it re-enters the command on
--- the tool it wrote (build/reboot.tl's `serialize`), a `bin/zig build
--- boot` from before its build to its end (build/zig.tl), and a write
--- of the projection while it writes ([`build.writer`]'s `write_result`).
--- Without it, two runs in one checkout that both find the tool stale
--- (an editor, a watcher and a terminal, say) would rebuild it at once:
--- each writes cosmic.db and carried.db aside through the same
--- fixed `.building` name ([`writer.write_result`], [`writer.carried`]),
--- which the other removes and writes into under it.
---
--- It is a `flock` of `rebuild.lock` and, on Linux, an SQLite write
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
--- and taking SQLite's as well would find it always busy. So does a
--- checkout Linux reaches over NFS or SMB, which make a flock a
--- whole-file fcntl lock: [`sys.flock_kind`] says which the lock's file
--- is.
---
--- The system drops the lock with its descriptors, so a holder that dies
--- or execs (each is opened close-on-exec) never leaves it held. Closing
--- any descriptor of the file drops every fcntl lock the process holds
--- on it, so a holder opens and closes no other while it holds the lock.
--- A sandboxed test worker never takes it, since only the tree's own
--- tool ([`reboot.own_tool`]) rebuilds.
-- The SQLite half stays: any checkout can build a commit from before
-- the flock (a bisect, an older branch), and that tool takes only
-- SQLite's.
---
--- A child of a holder that must take the lock itself -- the `bin/zig
--- build boot` a stale tool starts, and the boot bridge that boot starts
--- -- is handed it instead (`handed_variable`), since a lock its parent
--- holds keeps it out.

local build_paths = require("build.paths")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local log = require("build.verdict").log
local plural = require("build.plural")

local record rebuild_lock

  --- What the run holding the lock is doing, as a waiting run names it.
  enum Role
    "test"
    "rebuild"
    "write"
  end

  --- What `take` found of the lock: this process holds it, or another
  --- run held it past the wait.
  enum Taken
    "held"
    "busy"
  end
end

local lock_name = "/rebuild.lock"

--- One millisecond, which [`sys.flock`] and SQLite count their waits in.
local MS <const> = Clock.ms(1)

--- Where the holder writes its process id and role, a line each, for
--- a waiting run to name it. build/zig.tl writes and reads it too.
local holder_name = "/rebuild.lock.pid"

--- What a role's holder is doing, as a waiting run says it. build/zig.tl
--- keeps a copy (build/zig_test.tl holds the two alike).
local doing: {string:string} = {
  test = "is running its tests",
  rebuild = "is rebuilding the tool",
  write = "is writing the project projection",
}

--- Set by a holder in the environment of a child that would take the
--- lock itself, to the lock's path: a boot (build/zig.tl), or a write of
--- the projection (`hold` as "write"), that finds the lock busy and this
--- naming it goes on under its parent's hold rather than wait for it.
--- One that finds the lock free takes it, so a variable left in an
--- environment it no longer describes holds nothing up; a `cosmic test`
--- run never goes on under it, and gives none to its workers
--- ([`build.test`]'s `worker_environment`).
local handed_variable <const> = "COSMIC_REBUILD_LOCK_HANDED"

--- How long a waiting run waits in one go before it says it still is.
local reminder_ns <const> = Clock.minutes(5)

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
local held_directory: string | nil = nil

--- Takes SQLite's half of the lock on `path` into `lock`, waiting up to
--- `wait_ns`. Answers "held", "busy", or nil and why.
local function take_sqlite(lock: Lock, path: string,
                           wait_ns: integer): rebuild_lock.Taken | nil, string
  local db, db_trouble = Sqlite.open(path, { writable = true })
  if db == nil then
    return nil, path .. ": " .. db_trouble
  end
  lock.db = db
  db:busy_timeout(wait_ns)
  local begun = db:exec_result("BEGIN IMMEDIATE")
  if begun.cancelled then return nil, "interrupted while waiting for " .. path end
  if begun.code == Sqlite.BUSY then return "busy", "" end
  if begun.code ~= Sqlite.OK then return nil, path .. ": " .. begun.reason end
  return "held", ""
end

--- Takes the rebuild lock of `root` as `role` ("rebuild" unless
--- given), waiting up to `wait_ns` (0 to [`Poll.MOST_NS`], which [`sys.flock`]'s
--- C int of milliseconds holds; another raises)
--- in all for a run that holds it. Answers "held" once this process
--- holds it -- at once when it already does -- "busy" when another run
--- held it past the wait, or nil and why when the lock could not be
--- asked for at all (its file cannot be opened for writing, a
--- [`Child.guard`] caught a signal during the wait, this process holds
--- another checkout's). A half taken is let go again whenever the
--- other is not.
function rebuild_lock.take(root: string, wait_ns: integer,
                           role?: rebuild_lock.Role): rebuild_lock.Taken | nil, string
  if wait_ns < 0 or wait_ns > Poll.MOST_NS then
    error("rebuild_lock.take: the wait is out of range", 2)
  end
  local directory, directory_trouble = build_paths.prepare(root)
  if directory == nil then return nil, directory_trouble end
  if held ~= nil then
    if held_directory == directory then
      return "held", ""
    end
    return nil, "this process holds " .. tostring(held_directory) .. lock_name ..
      " and cannot take another checkout's too"
  end
  local path = directory .. lock_name
  local started_ns = Clock.monotonic_ns()
  -- For writing, which an exclusive flock over NFS or SMB needs.
  local fd, open_trouble = sys.open(path, sys.O_RDWR | sys.O_CREAT, 0x1a4)
  if fd == nil then
    return nil, path .. ": " .. open_trouble
  end
  local opened: Lock = { fd = fd }
  local taking <close> = setmetatable(opened, lock_mt)
  local flocked, flock_trouble, errno = sys.flock(fd, "exclusive", Clock.ceil(wait_ns, MS))
  if not flocked then
    local name = sys.errno_name(errno)
    if name == "ETIMEDOUT" then
      return "busy", ""
    elseif name == "EINTR" then
      return nil, "interrupted while waiting for " .. path
    end
    return nil, path .. ": " .. flock_trouble
  end
  local kind, kind_trouble = sys.flock_kind(fd)
  if kind == nil then
    return nil, path .. ": " .. kind_trouble
  end
  if kind == "apart" then
    local left_ns = wait_ns - (Clock.monotonic_ns() - started_ns)
    local taken, trouble = take_sqlite(taking, path, math.max(left_ns, 0))
    if taken == nil then
      return nil, trouble
    elseif taken == "busy" then
      return "busy", ""
    end
  end
  local holding: Lock = { fd = taking.fd, db = taking.db }
  taking.fd, taking.db = nil, nil
  setmetatable(holding, lock_mt)
  held, held_directory = holding, directory
  -- Written aside and moved into place, so a waiting run reads a whole
  -- one or the one before.
  local aside = build_paths.required(root) .. holder_name .. "." .. tostring(sys.getpid())
  local written, _ = Fs.write(aside, tostring(sys.getpid()) .. "\n" .. (role or "rebuild") .. "\n")
  if written then
    local _, _ = Fs.rename(aside, build_paths.required(root) .. holder_name)
  end
  return "held", ""
end

--- Whether this process holds the rebuild lock of `root`.
function rebuild_lock.holds(root: string): boolean
  return held ~= nil and held_directory == build_paths.required(root)
end

--- Lets go of the rebuild lock this process holds, if it holds it.
function rebuild_lock.release()
  local lock = held
  held, held_directory = nil, nil
  if lock ~= nil then
    local _letting <close> = lock
  end
end

--- The run holding the lock under `root`, and what it is doing, as a
--- waiting run names them -- "another cosmic run (pid 12) in this
--- checkout is running its tests" -- read once this run has failed to
--- take it. The file may still name the run before, which a new holder
--- has not yet written over: a pid no process answers to, or this one's
--- own (a holder that re-entered this process), is left unnamed. One a
--- holder in another pid namespace wrote -- a container sharing the
--- checkout -- names what that namespace called it, not a process here.
--- A holder that names no role, as a tool from before roles did, is
--- taken to be rebuilding.
function rebuild_lock.holder(root: string): string
  local text, _ = Fs.read(build_paths.required(root) .. holder_name)
  local pid: integer | nil = nil
  local role = "rebuild"
  if text ~= nil then
    local number, named = text:match("^(%d+)\n(%l*)\n?$")
    pid = math.tointeger(tonumber(number))
    if named ~= nil and doing[named] ~= nil then
      role = named
    end
  end
  local who = "another cosmic run"
  if pid ~= nil and pid ~= sys.getpid() then
    local alive, _ = sys.kill(pid, 0)
    if alive then
      who = "another cosmic run (pid " .. tostring(pid) .. ")"
    end
  end
  return who .. " in this checkout " .. doing[role]
end

--- What a waiting run's line ends with: the lock it waits for.
function rebuild_lock.suffix(root: string): string
  return " (one run at a time holds " .. build_paths.required(root) .. lock_name .. ")"
end

--- `environment` with the lock of `root`, which this process holds,
--- handed on to a child that would take it (`handed_variable`).
function rebuild_lock.hand(environment: {string:string}, root: string): {string:string}
  local out: {string:string} = {}
  for name, value in pairs(environment) do out[name] = value end
  out[handed_variable] = build_paths.required(root, environment) .. lock_name
  return out
end

--- `environment` with no lock handed on in it (`handed_variable`), for
--- what a `cosmic test` run starts: none of it holds this run's lock.
function rebuild_lock.unhanded(environment: {string:string}): {string:string}
  local out: {string:string} = {}
  for name, value in pairs(environment) do out[name] = value end
  out[handed_variable] = nil
  return out
end

--- Whether a parent holding the rebuild lock of `root` handed it to this
--- process (`handed_variable`): the variable names the lock's file, by
--- a path that may be spelled otherwise than this process spells it (a
--- boot's bridge is given its root as `<root>/.`), so it is told by the
--- file it names.
local function handed(root: string): boolean
  local named = Env.get(handed_variable)
  if named == nil or named == "" then
    return false
  end
  local given, _ = sys.stat(named)
  local own, _ = sys.stat(build_paths.required(root) .. lock_name)
  return given ~= nil and own ~= nil and given.dev == own.dev and given.ino == own.ino
end

--- Waits for the rebuild lock of `root`, which another run holds, to
--- take it as `role`, having said `line`; says it still waits every few
--- minutes, for as long as it takes. Answers nil and why when it
--- cannot.
function rebuild_lock.wait(root: string, role: rebuild_lock.Role,
                           line: string): boolean, string
  log:complain(line)
  local waited_ns = 0
  while true do
    local taken, trouble = rebuild_lock.take(root, reminder_ns, role)
    if taken == nil then
      return false, trouble
    end
    if taken == "held" then
      return true, ""
    end
    waited_ns = waited_ns + reminder_ns
    log:complain("still waiting, " .. plural.count(waited_ns // Clock.minutes(1), "minute") ..
        " on: " .. rebuild_lock.holder(root) .. rebuild_lock.suffix(root))
  end
end

--- Holds the rebuild lock of `root` as `role` before this run goes on,
--- for `what` (a verb, which names itself in what it says). Answers
--- true when this call took it -- the caller releases it
--- ([`rebuild_lock.release`]) when done, or leaves it to its exit -- and
--- false when this process held it already, or, for a write, a parent
--- that holds it handed it on (`handed_variable`). A run that finds
--- another holding it says so, naming that run and what it is doing,
--- and waits for it (`wait`): the other may be a whole `cosmic test`
--- run. Answers nil and why when it cannot take the lock.
---
--- It must be called holding nothing that run may wait for: the working
--- database's transaction above all ([`build.work`]).
function rebuild_lock.hold(root: string, role: rebuild_lock.Role,
                           what: string): boolean | nil, string
  if rebuild_lock.holds(root) then
    return false, ""
  end
  local directory, made_trouble = build_paths.prepare(root)
  if directory == nil then return nil, made_trouble end
  local taken, trouble = rebuild_lock.take(root, 0, role)
  if taken == nil then
    return nil, trouble
  end
  if taken == "held" then
    return true, ""
  end
  if role == "write" and handed(root) then
    return false, ""
  end
  local waited, wait_trouble = rebuild_lock.wait(root, role, what .. ": " ..
      rebuild_lock.holder(root) .. "; waiting for it" .. rebuild_lock.suffix(root))
  if not waited then
    return nil, wait_trouble
  end
  return true, ""
end

return rebuild_lock
