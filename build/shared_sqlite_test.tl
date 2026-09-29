--- The SQLite file the shared caches keep (build/shared_sqlite.tl):
--- opened in write-ahead mode, a busy answer told from a broken file,
--- and a broken file moved aside so the next open starts afresh.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local shared_sqlite = require("build.shared_sqlite")

--- A `prepare` that makes one table, as each cache makes its own.
local function prepare(db: Sqlite.Handle): boolean, string
  return db:exec("CREATE TABLE IF NOT EXISTS kept (key TEXT PRIMARY KEY)")
end

--- A broken file is corrupt, and a lock held or a table missing is
--- not: only a corrupt answer moves a cache aside.
local function test_only_a_broken_file_is_corrupt()
  assert(shared_sqlite.corrupt("database disk image is malformed"))
  assert(shared_sqlite.corrupt("file is not a database"))
  assert(not shared_sqlite.corrupt("database is locked"))
  assert(not shared_sqlite.corrupt("database table is busy"))
  assert(not shared_sqlite.corrupt("no such table: kept"))
end

--- A cache opened is in write-ahead mode and prepared; a `prepare`
--- that fails is answered with the path, and the file is closed.
local function test_an_open_cache_is_in_wal_mode_and_prepared(tmp: string)
  local path = tmp .. "/cache.db"
  local db = assert(shared_sqlite.open(path, prepare))
  local mode = assert(Sqlite.text_rows(db, "PRAGMA journal_mode"))
  assert(mode[1][1] == "wal", mode[1][1])
  assert(Sqlite.text_rows(db, "SELECT key FROM kept"))
  db:close()
  local refused, trouble = shared_sqlite.open(path, function(_: Sqlite.Handle): boolean, string
    return false, "no shape of mine"
  end)
  assert(refused == nil and trouble == path .. ": no shape of mine", trouble)
end

--- A broken file is answered as corrupt, and set aside with its log and
--- its index -- an earlier file set aside removed -- so the next open
--- starts a fresh cache.
local function test_a_corrupt_cache_is_set_aside_and_started_afresh(tmp: string)
  local path = tmp .. "/cache.db"
  assert(Fs.write(path, string.rep("\xff", 8192)))
  local db, trouble = shared_sqlite.open(path, prepare)
  assert(db == nil and shared_sqlite.corrupt(trouble), trouble)
  assert(trouble:sub(1, #path + 2) == path .. ": ", trouble)
  -- What another run left beside it, written after the refused open,
  -- whose close may remove a log and index it finds.
  assert(Fs.write(path .. "-wal", "log"))
  assert(Fs.write(path .. "-shm", "index"))
  assert(Fs.write(path .. ".corrupt-1", "older"))
  local aside = assert(shared_sqlite.set_aside(path, 2))
  assert(aside == path .. ".corrupt-2", aside)
  assert(Fs.read(aside) == string.rep("\xff", 8192))
  assert(Fs.read(aside .. "-wal") == "log" and Fs.read(aside .. "-shm") == "index")
  assert(Fs.stat(path .. ".corrupt-1") == nil, "an earlier file set aside was kept")
  for _, gone in ipairs({ path, path .. "-wal", path .. "-shm" }) do
    assert(Fs.stat(gone) == nil, gone .. " was left behind")
  end
  local fresh = assert(shared_sqlite.open(path, prepare))
  assert(Sqlite.text_rows(fresh, "SELECT key FROM kept"))
  fresh:close()
end

--- A file with nothing to set aside answers why.
local function test_setting_aside_no_file_says_why(tmp: string)
  local aside, trouble = shared_sqlite.set_aside(tmp .. "/none.db", 1)
  assert(aside == nil and trouble ~= "", trouble)
end

--- A cache another connection holds locked, before it is in write-ahead
--- mode, is tried again for as long as the wait allows, then answered
--- busy, not corrupt: no build sets aside a file another is writing.
local function test_a_locked_cache_waits_then_answers_busy(tmp: string)
  local path = tmp .. "/cache.db"
  local holder = assert(Sqlite.open(path, true))
  assert(holder:exec("CREATE TABLE held (x)"))
  assert(holder:exec("BEGIN EXCLUSIVE"))
  local started = Time.monotonic_ns()
  local db, trouble = shared_sqlite.open(path, prepare, 50)
  local waited = Time.monotonic_ns() - started
  assert(db == nil and trouble:find("locked", 1, true) ~= nil, trouble)
  assert(not shared_sqlite.corrupt(trouble), trouble)
  assert(waited >= 50 * 1000000, "answered busy after " .. waited .. " ns")
  assert(holder:exec("COMMIT"))
  holder:close()
  local opened = assert(shared_sqlite.open(path, prepare, 50))
  opened:close()
end

--- A cache already in write-ahead mode opens while another connection
--- writes: the switch reads the header and has nothing to write.
local function test_a_wal_cache_opens_while_another_writes(tmp: string)
  local path = tmp .. "/cache.db"
  local first = assert(shared_sqlite.open(path, prepare))
  assert(first:exec("BEGIN IMMEDIATE"))
  assert(first:exec("INSERT INTO kept (key) VALUES ('k')"))
  local second = assert(shared_sqlite.open(path, prepare, 50))
  assert(first:exec("COMMIT"))
  local rows = assert(Sqlite.text_rows(second, "SELECT key FROM kept"))
  assert(#rows == 1 and rows[1][1] == "k")
  second:close()
  first:close()
end
