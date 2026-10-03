--- The SQLite file the shared caches keep (build/shared_sqlite.tl):
--- opened in write-ahead mode, with a bounded wait on other writers.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local shared_sqlite = require("build.shared_sqlite")
local String = require("cosmic.string")

--- A `prepare` that makes one table, as each cache makes its own.
local function prepare(db: Sqlite.Handle): boolean, string
  return db:exec("CREATE TABLE IF NOT EXISTS kept (key TEXT PRIMARY KEY)")
end

--- A cache opened is in write-ahead mode and prepared; a `prepare`
--- that fails is answered with the path, and the file is closed.
local function test_an_open_cache_is_in_wal_mode_and_prepared(tmp: string)
  local path = tmp .. "/cache.db"
  local db = assert(shared_sqlite.open(path, prepare))
  local mode = assert(Sqlite.text_rows(db, "PRAGMA journal_mode"))
  assert(mode[1][1] == "wal", mode[1][1])
  local timeout = assert(Sqlite.text_rows(db, "PRAGMA busy_timeout"))
  assert(timeout[1][1] == "10000", "busy timeout " .. timeout[1][1])
  assert(Sqlite.text_rows(db, "SELECT key FROM kept"))
  db:close()
  local waiting = assert(shared_sqlite.open(path, prepare, Time.ms(50)))
  timeout = assert(Sqlite.text_rows(waiting, "PRAGMA busy_timeout"))
  assert(timeout[1][1] == "50", "busy timeout " .. timeout[1][1])
  waiting:close()
  -- The last connection closed, SQLite removes the log; one left open
  -- by a failed open would keep it.
  assert(Fs.stat(path .. "-wal") == nil, "the log outlived its connections")
  local refused, trouble = shared_sqlite.open(path, function(_: Sqlite.Handle): boolean, string
    return false, "no shape of mine"
  end)
  assert(refused == nil and trouble == path .. ": no shape of mine", trouble)
  assert(Fs.stat(path .. "-wal") == nil, "a failed open left its connection open")
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
  assert(Fs.read(path) == bytes)
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
  local started = Time.monotonic_ns()
  local db, trouble = shared_sqlite.open(path, prepare, wait_ns)
  local waited = Time.monotonic_ns() - started
  assert(db == nil, "opened a cache another holds")
  assert(holder:exec("COMMIT"))
  holder:close()
  local opened = assert(shared_sqlite.open(path, prepare, wait_ns))
  opened:close()
  return waited, trouble
end

--- Far past what an open given a wait of a tenth of a second takes, and
--- short of the ten seconds it waits when given none or a try sits out
--- the connection's minute-long busy timeout: an open that took this
--- long did not keep to the wait it was given.
local gave_up_late_ns <const> = Time.seconds(5)

--- A cache another connection is writing, before it is in write-ahead
--- mode, is answered locked at once by SQLite, which calls no busy
--- handler: the switch is tried again until the wait has passed, then
--- answered busy.
local function test_a_cache_being_written_is_tried_again_then_answered_busy(tmp: string)
  local wait_ns = Time.ms(100)
  local waited, trouble = held_open(tmp .. "/cache.db",
    { "BEGIN IMMEDIATE", "INSERT INTO held (x) VALUES (1)" }, wait_ns)
  assert(trouble:find("locked", 1, true) ~= nil, trouble)
  assert(waited >= wait_ns, "answered busy after " .. waited .. " ns")
  assert(waited < gave_up_late_ns, "answered busy after " .. waited .. " ns")
end

--- A cache another connection holds whole, before it is in write-ahead
--- mode, is waited on no longer than the wait in all: no try sits out a
--- busy timeout of its own, so the wait never grows with the tries.
local function test_a_cache_held_whole_is_waited_on_no_longer_than_the_wait(tmp: string)
  local wait_ns = Time.ms(100)
  local waited, trouble = held_open(tmp .. "/cache.db", { "BEGIN EXCLUSIVE" }, wait_ns)
  assert(trouble:find("locked", 1, true) ~= nil, trouble)
  assert(waited >= wait_ns, "answered busy after " .. waited .. " ns")
  assert(waited < gave_up_late_ns, "answered busy after " .. waited .. " ns")
end

--- A cache already in write-ahead mode opens while another connection
--- writes: the switch reads the header and has nothing to write.
local function test_a_wal_cache_opens_while_another_writes(tmp: string)
  local path = tmp .. "/cache.db"
  local first = assert(shared_sqlite.open(path, prepare))
  assert(first:exec("BEGIN IMMEDIATE"))
  assert(first:exec("INSERT INTO kept (key) VALUES ('k')"))
  local second = assert(shared_sqlite.open(path, prepare, Time.ms(50)))
  assert(first:exec("COMMIT"))
  local rows = assert(Sqlite.text_rows(second, "SELECT key FROM kept"))
  assert(#rows == 1 and rows[1][1] == "k")
  second:close()
  first:close()
end
