--- The SQLite file the shared caches keep (build/shared_sqlite.tl):
--- opened in write-ahead mode, with a bounded wait on other writers.

local Array = require("cosmic.array")
local Signal = require("cosmic.signal")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local shared_sqlite = require("build.shared_sqlite")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

--- A `prepare` that makes one table, as each cache makes its own.
local function prepare(db: Sqlite.Handle): boolean, string
  local done, done_why = db:exec("CREATE TABLE IF NOT EXISTS kept (key TEXT PRIMARY KEY)")
  if not done then return false, tostring(done_why) end
  return true, ""
end

--- A cache opened is in write-ahead mode and prepared; a `prepare`
--- that fails is reported with the path, and the file is closed.
local function test_an_open_cache_is_in_wal_mode_and_prepared(tmp: string)
  local path = tmp .. "/cache.db"
  local db = assert(shared_sqlite.open(path, prepare))
  local mode = assert(db:rows("PRAGMA journal_mode"))
  local mode_row = Array.at(mode, 1)
  assert(mode_row:text(1) == "wal", mode_row:text(1))
  local timeout = assert(db:rows("PRAGMA busy_timeout"))
  local timeout_row = Array.at(timeout, 1)
  assert(timeout_row:integer(1) == 10000, "busy timeout " .. tostring(timeout_row:integer(1)))
  assert(db:rows("SELECT key FROM kept"))
  local _, _ = db:close()
  local waiting = assert(shared_sqlite.open(path, prepare, Clock.ms(50)))
  timeout = assert(waiting:rows("PRAGMA busy_timeout"))
  timeout_row = Array.at(timeout, 1)
  assert(timeout_row:integer(1) == 50, "busy timeout " .. tostring(timeout_row:integer(1)))
  local _, _ = waiting:close()
  -- The last connection closed, SQLite removes the log; one left open
  -- by a failed open would keep it.
  assert(not assert(Fs.status(path .. "-wal")).exists, "the log outlived its connections")
  local refused, trouble = shared_sqlite.open(path, function(_: Sqlite.Handle): boolean, string
    return false, "no shape of mine"
  end)
  assert(refused == nil and trouble == path .. ": no shape of mine", trouble)
  assert(not assert(Fs.status(path .. "-wal")).exists, "a failed open left its connection open")
end

--- Opening a broken file reports its path and leaves its bytes in place.
local function test_a_broken_cache_is_left_in_place(tmp: string)
  local path = tmp .. "/cache.db"
  local bytes = string.rep("\xff", 8192)
  assert(Fs.write(path, bytes))
  local before = assert(Fs.stat(path))
  local db, trouble = shared_sqlite.open(path, prepare)
  assert(db == nil and String.starts_with(trouble, path .. ": "), trouble)
  local after = assert(Fs.stat(path))
  assert(after.ino == before.ino and after.dev == before.dev)
  assert(assert(Fs.read(path)) == bytes)
end

--- How long an open of the rollback-mode cache at `path` took, in
--- nanoseconds, and why it failed, while another connection holds it by
--- `statements`, with a wait of `wait_ns`. The cache opens once the
--- holder lets go.
local function held_open(path: string, statements: {string},
                         wait_ns: integer): integer, string
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("CREATE TABLE held (x)"))
  for _, statement in ipairs(statements) do assert(holder:exec(statement)) end
  local started = Clock.monotonic_ns()
  local db, trouble = shared_sqlite.open(path, prepare, wait_ns)
  local waited = Clock.monotonic_ns() - started
  assert(db == nil, "opened a cache another holds")
  assert(holder:exec("COMMIT"))
  local _, _ = holder:close()
  local opened = assert(shared_sqlite.open(path, prepare, wait_ns))
  local _, _ = opened:close()
  return waited, trouble
end

--- Far past what an open given a wait of a tenth of a second takes, and
--- short of the ten seconds it waits when given none or a try sits out
--- the connection's minute-long busy timeout: an open that took this
--- long did not keep to the wait it was given.
local gave_up_late_ns <const> = Clock.seconds(5)

--- A cache another connection is writing, before it is in write-ahead
--- mode, is reported locked at once by SQLite, which calls no busy
--- handler: the switch is tried again until the wait has passed, then
--- reported busy.
local function test_a_cache_being_written_is_tried_again_then_answered_busy(tmp: string)
  local wait_ns = Clock.ms(100)
  local waited, trouble = held_open(tmp .. "/cache.db",
    { "BEGIN IMMEDIATE", "INSERT INTO held (x) VALUES (1)" }, wait_ns)
  assert(trouble:find("locked", 1, true) ~= nil, trouble)
  assert(waited >= wait_ns, "answered busy after " .. tostring(waited) .. " ns")
  assert(waited < gave_up_late_ns, "answered busy after " .. tostring(waited) .. " ns")
end

--- A cache another connection holds whole, before it is in write-ahead
--- mode, is waited on no longer than the wait in all: no try sits out a
--- busy timeout of its own, so the wait never grows with the tries.
local function test_a_cache_held_whole_is_waited_on_no_longer_than_the_wait(tmp: string)
  local wait_ns = Clock.ms(100)
  local waited, trouble = held_open(tmp .. "/cache.db", { "BEGIN EXCLUSIVE" }, wait_ns)
  assert(trouble:find("locked", 1, true) ~= nil, trouble)
  assert(waited >= wait_ns, "answered busy after " .. tostring(waited) .. " ns")
  assert(waited < gave_up_late_ns, "answered busy after " .. tostring(waited) .. " ns")
end

--- A cache already in write-ahead mode opens while another connection
--- writes: the switch reads the header and has nothing to write.
local function test_a_wal_cache_opens_while_another_writes(tmp: string)
  local path = tmp .. "/cache.db"
  local first = assert(shared_sqlite.open(path, prepare))
  assert(first:exec("BEGIN IMMEDIATE"))
  assert(first:exec("INSERT INTO kept (key) VALUES ('k')"))
  local second = assert(shared_sqlite.open(path, prepare, Clock.ms(50)))
  assert(first:exec("COMMIT"))
  local rows = assert(second:rows("SELECT key FROM kept"))
  assert(#rows == 1 and rows[1]:text(1) == "k")
  local _, _ = second:close()
  local _, _ = first:close()
end

--- The zero-wait handler still captures an unread guard signal when
--- SQLite invokes it; a captured cancellation must not restart the wait.
local function test_a_captured_cancellation_stops_the_wal_retry(tmp: string)
  local path = tmp .. "/cache.db"
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("CREATE TABLE held (x); BEGIN EXCLUSIVE"))
  local guard <close> = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local started = Clock.monotonic_ns()
  local db, trouble = shared_sqlite.open(path, prepare, Clock.seconds(2))
  local waited = Clock.monotonic_ns() - started
  local signal = guard:take()
  local _, _ = guard:release()
  assert(holder:exec("COMMIT"))
  assert(holder:close())
  assert(db == nil and trouble ~= "", trouble)
  assert(signal == sys.SIGTERM, "the cache consumed the guard's signal")
  assert(waited < Clock.seconds(1), "cancelled after " .. tostring(waited) .. " ns")
  local opened = assert(shared_sqlite.open(path, prepare))
  assert(opened:close())
end
