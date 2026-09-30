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

--- A holder asking again holds it still, and a holder lets go of the
--- file's flock with the lock. Whether another run is kept out while
--- it holds the lock is asked from another process
--- (`rebuild_lock_tool_test.tl`): opening and closing the file here
--- would drop this process's fcntl locks on it.
local function test_a_holder_lets_go_of_the_flock_on_release(tmp: string)
  local root, path = tree(tmp)
  assert(rebuild_lock.take(root, 0) == "held")
  assert(rebuild_lock.take(root, 0) == "held", "a holder asking again is refused")
  rebuild_lock.release()
  local fd = assert(sys.open(path, sys.O_RDWR, 0))
  local ok, why = sys.flock(fd, "exclusive")
  assert(sys.close(fd))
  assert(ok, "the flock outlived the release: " .. tostring(why))
  assert(rebuild_lock.take(root, 0) == "held")
  rebuild_lock.release()
end

--- A wait `sys.flock` cannot take is refused by `take` itself: a
--- negative one, which it would take for no limit and SQLite for none,
--- and one past a C int.
local function test_a_wait_out_of_range_raises(tmp: string)
  local root = tree(tmp)
  for _, wait_ms in ipairs({ -1, 0x80000000 }) do
    local ok, err = pcall(rebuild_lock.take, root, wait_ms)
    assert(not ok and tostring(err):find("rebuild_lock.take: the wait is out of range", 1, true),
      tostring(err))
  end
end

--- A lock whose file cannot be opened is no busy lock: the caller is
--- told why instead of waiting.
local function test_a_lock_that_cannot_be_opened_says_why(tmp: string)
  local taken, trouble = rebuild_lock.take(tmp .. "/missing", 0)
  assert(taken == nil, tostring(taken))
  assert(trouble:find(tmp .. "/missing/o/rebuild.lock: ", 1, true), trouble)
end
