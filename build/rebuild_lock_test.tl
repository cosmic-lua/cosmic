local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local rebuild_lock = require("build.rebuild_lock")

--- A tree with an o/ for the lock's files, and the path of its lock file.
local function tree(tmp: string): string, string
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  return root, root .. "/o/rebuild.lock"
end

--- Whether another open of `path` is refused the flock: the one a run
--- taking the rebuild lock asks for first.
local function flock_refused(path: string): boolean
  local fd = assert(sys.open(path, sys.O_RDWR, 0))
  local ok, why, errno = sys.flock(fd, "exclusive")
  assert(sys.close(fd))
  assert(ok or sys.errno_name(errno) == "ETIMEDOUT", why)
  return not ok
end

--- A run holding the flock alone, as another run holding the lock does
--- while it takes the SQLite half, keeps a run out whether it asks once
--- or waits, and lets it in once let go. The file is left as it was
--- found, the empty database a tool from before the flock made.
local function test_a_held_flock_keeps_another_run_out(tmp: string)
  local root, path = tree(tmp)
  local made = assert(Sqlite.open(path, true))
  assert(made:close())
  local other = assert(sys.open(path, sys.O_RDWR, 0))
  assert(sys.flock(other, "exclusive"))
  local taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  taken, trouble = rebuild_lock.take(root, 50)
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  assert(sys.close(other))
  taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "held", tostring(taken) .. " " .. trouble)
  assert(Fs.read(root .. "/o/rebuild.lock.pid") == tostring(sys.getpid()) .. "\n")
  rebuild_lock.release()
  assert(assert(sys.stat(path)).size == 0, "the lock's file was written")
end

--- A run holding the lock holds its flock until it lets go, so another
--- run asking for it, which asks for the flock first, is kept out.
local function test_a_holder_keeps_the_flock_until_released(tmp: string)
  local root, path = tree(tmp)
  assert(rebuild_lock.take(root, 0) == "held")
  assert(rebuild_lock.take(root, 0) == "held", "a holder asking again is refused")
  assert(flock_refused(path), "the holder does not hold the flock")
  rebuild_lock.release()
  assert(not flock_refused(path), "the flock outlived the release")
  assert(rebuild_lock.take(root, 0) == "held")
  rebuild_lock.release()
end

--- A lock whose file cannot be opened is no busy lock: the caller is
--- told why instead of waiting.
local function test_a_lock_that_cannot_be_opened_says_why(tmp: string)
  local taken, trouble = rebuild_lock.take(tmp .. "/missing", 0)
  assert(taken == nil, tostring(taken))
  assert(trouble:find(tmp .. "/missing/o/rebuild.lock: ", 1, true), trouble)
end
