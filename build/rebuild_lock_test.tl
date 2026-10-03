local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Poll = require("cosmic.poll")
local Time = require("cosmic.time")
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
  local made = assert(Sqlite.open(path, { writable = true }))
  assert(made:close())
  local other = assert(sys.open(path, sys.O_RDWR, 0))
  assert(sys.flock(other, "exclusive"))
  local taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  taken, trouble = rebuild_lock.take(root, Time.ms(50))
  assert(taken == "busy", tostring(taken) .. " " .. trouble)
  assert(sys.close(other))
  taken, trouble = rebuild_lock.take(root, 0)
  assert(taken == "held", tostring(taken) .. " " .. trouble)
  assert(Fs.read(root .. "/o/rebuild.lock.pid") == tostring(sys.getpid()) .. "\nrebuild\n")
  rebuild_lock.release()
  assert(assert(sys.stat(path)).size == 0, "the lock's file was written")
end

--- A holder asking again holds it still, and a holder lets go of the
--- file's flock with the lock. Whether another run is kept out while
--- it holds the lock is asked from another process
--- (`rebuild_lock_lua_test.tl`): opening and closing the file here
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

--- A wait [`sys.flock`] cannot take is refused by `take` itself: a
--- negative one, which it would take for no limit and SQLite for none,
--- and one past a C int.
local function test_a_wait_out_of_range_raises(tmp: string)
  local root = tree(tmp)
  for _, wait_ns in ipairs({ -1, Poll.MOST_NS + 1 }) do
    local ok, err = pcall(rebuild_lock.take, root, wait_ns)
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

--- A process that holds a checkout's lock takes it again at once, as a
--- `cosmic test` run's guard does when it finds the tool stale and
--- rebuilds it (build.reboot's `serialize`): the run does not wait on
--- itself. What it holds, it holds until it lets go, and it names
--- itself the holder, by its role.
local function test_a_holder_takes_its_own_lock_again(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  local took = assert(rebuild_lock.hold(root, "test", "test"))
  assert(took == true)
  assert(rebuild_lock.holds(root))
  assert(rebuild_lock.take(root, 0, "rebuild") == "held")
  assert(rebuild_lock.hold(root, "write", "o/cosmic.db") == false,
    "a holder took its own lock as though it were new")
  assert(Fs.read(root .. "/o/rebuild.lock.pid") ==
      tostring(sys.getpid()) .. "\ntest\n")
  rebuild_lock.release()
  assert(not rebuild_lock.holds(root))
  assert(rebuild_lock.take(root, 0, "rebuild") == "held")
  rebuild_lock.release()
end

--- A process holds one checkout's lock at once: another's is refused,
--- by name, rather than taken as the one it holds.
local function test_a_holder_is_refused_another_checkouts_lock(tmp: string)
  assert(Fs.mkdirs(tmp .. "/one/o") and Fs.mkdirs(tmp .. "/two/o"))
  assert(rebuild_lock.take(tmp .. "/one", 0, "test") == "held")
  local taken, trouble = rebuild_lock.take(tmp .. "/two", 0, "test")
  rebuild_lock.release()
  assert(taken == nil, "took a second checkout's lock")
  assert(trouble:find(tmp .. "/one/o/rebuild.lock", 1, true), trouble)
end

--- A waiting run names the holder by what it is doing: its role, as the
--- holder wrote it, and its pid only where a process answers to it.
--- One that wrote no role, as a tool from before roles did, is taken to
--- be rebuilding.
local function test_the_holder_is_named_by_its_role(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  assert(Fs.write(root .. "/o/rebuild.lock.pid", "1\ntest\n"))
  local named = rebuild_lock.holder(root)
  assert(named:find("in this checkout is running its tests", 1, true), named)
  assert(Fs.write(root .. "/o/rebuild.lock.pid", "1\n"))
  named = rebuild_lock.holder(root)
  assert(named:find("in this checkout is rebuilding the tool", 1, true), named)
  assert(Fs.write(root .. "/o/rebuild.lock.pid", tostring(sys.getpid()) .. "\nwrite\n"))
  assert(rebuild_lock.holder(root) ==
      "another cosmic run in this checkout is writing o/cosmic.db")
end

--- A handed lock names the file its holder holds, whatever the
--- holder called its root.
local function test_a_lock_is_handed_by_the_file_it_names(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o"))
  assert(rebuild_lock.take(root, 0, "test") == "held")
  local handed = rebuild_lock.hand({ KEPT = "1" }, root .. "/.")
  rebuild_lock.release()
  assert(handed.KEPT == "1")
  assert(handed.COSMIC_REBUILD_LOCK_HANDED == root .. "/./o/rebuild.lock")
end

--- A lock file this process cannot write would lock nothing, so it is
--- refused, saying why, rather than taken or waited for. Run as root,
--- which writes it anyway, there is nothing to see.
local function test_a_lock_file_that_cannot_be_written_is_refused(tmp: string)
  local root, path = tree(tmp)
  assert(Fs.write(path, "", 0x124))
  local fd, _ = sys.open(path, sys.O_RDWR, 0)
  if fd ~= nil then
    assert(sys.close(fd))
    return
  end
  local taken, trouble = rebuild_lock.take(root, 0, "test")
  assert(taken == nil, tostring(taken))
  assert(trouble:find(path .. ": ", 1, true), trouble)
  local held, hold_trouble = rebuild_lock.hold(root, "test", "test")
  assert(held == nil and hold_trouble:find(path .. ": ", 1, true), hold_trouble)
end
