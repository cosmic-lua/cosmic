--- [`Sqlite.disown`]: a copy of a process is refused the connections the
--- process opened, closes none of them, and opens its own.

local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local process = require("cosmic.internal.process")
local sys = require("cosmic.sys")

--- Whether `call` raised saying the connection was disowned.
local function refused(call: function()): boolean
  local ok, why = pcall(call)
  return not ok and tostring(why):find("disowned its connections", 1, true) ~= nil
end

--- A process that disowns its connections is refused each one it had,
--- handle and statement, and one it opens after is its own.
local function test_a_handle_opened_before_is_refused_and_one_opened_after_is_not(tmp: string)
  local path = tmp .. "/a.db"
  local before = assert(Sqlite.open(path, { writable = true }))
  assert(before:exec("CREATE TABLE t (n INTEGER)"))
  assert(before:exec("INSERT INTO t VALUES (7)"))
  local statement = assert(before:prepare("SELECT n FROM t"))
  -- In a copy, so the worker's own connections stay its own.
  local pid, trouble = process.fork(false)
  if pid == nil then Test.skip("this host forks no copy of the process: " .. trouble) end
  if pid == 0 then
    Sqlite.disown()
    local held = refused(function() local _, _ = before:exec("SELECT 1") end) and
      refused(function() local _, _ = before:prepare("SELECT 1") end) and
      refused(function() local _, _ = statement:step() end)
    -- Its close answers and closes nothing, once and again.
    local closed = before:close() and before:close()
    local after, _ = Sqlite.open(path)
    local read = false
    if after ~= nil then
      local rows, _ = Sqlite.text_rows(after, "SELECT n FROM t")
      local first = if rows ~= nil then rows[1] else nil end
      read = first ~= nil and first:text(1) == "7"
    end
    sys.exit(if held and closed and read then 0 else 1 end)
  end
  local status = assert(process.waitpid(assert(pid), false))
  assert(status.code == 0, "the copy was not held to its own connections")
  -- The process's own are as they were: the copy closed none of them.
  assert(statement:step())
  assert(before:exec("INSERT INTO t VALUES (8)"))
  local rows = assert(Sqlite.text_rows(before, "SELECT count(*) FROM t"))
  assert(assert(rows[1]):text(1) == "2")
  statement:finalize()
  assert(before:close())
end

--- In the process that disowns them too: what it opened before is refused,
--- its close closes nothing, and what it opens after is its own.
local function test_a_process_that_disowns_is_refused_what_it_opened_before(tmp: string)
  local path = tmp .. "/b.db"
  local before = assert(Sqlite.open(path, { writable = true }))
  assert(before:exec("CREATE TABLE t (n INTEGER)"))
  local statement = assert(before:prepare("SELECT n FROM t"))
  Sqlite.disown()
  assert(refused(function() local _, _ = before:exec("SELECT 1") end))
  assert(refused(function() local _, _ = statement:step() end))
  statement:finalize()
  assert(before:close() and before:close())
  local after = assert(Sqlite.open(path, { writable = true }))
  assert(after:exec("INSERT INTO t VALUES (1)"))
  -- Disowned again, the one opened between the two is refused as the first is.
  Sqlite.disown()
  assert(refused(function() local _, _ = after:exec("SELECT 1") end))
  local last = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(last, "SELECT n FROM t"))
  assert(assert(rows[1]):text(1) == "1")
  assert(last:close())
end

--- A database with a transaction open that has written more than its connection's cache holds, so that pages
--- of it are in the file already and the journal holds what they were: the handle, in `held`, and how many rows
--- the transaction adds.
local function mid_write(path: string, held: mut {string:Sqlite.Handle}): integer
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("PRAGMA journal_mode = DELETE"))
  assert(db:exec("PRAGMA cache_size = 5"))
  assert(db:exec("CREATE TABLE t (n INTEGER, pad TEXT)"))
  assert(db:exec("BEGIN"))
  local rows <const> = 2000
  for n = 1, rows do
    assert(Sqlite.run(db, "INSERT INTO t VALUES (?1, ?2)", { { integer = n }, { text = string.rep("p", 1000) } }))
  end
  held["db"] = db
  return rows
end

--- A copy that closes a connection it disowned, or drops it for the collector, closes nothing: a close of the
--- connection itself would roll the process's open transaction back through the file the two share, taking the
--- pages it had written out of the database under it.
local function test_a_copy_that_closes_or_drops_a_disowned_connection_leaves_its_transaction(tmp: string)
  for case, way in ipairs({ "close", "drop" }) do
    local held: mut {string:Sqlite.Handle} = {}
    local rows = mid_write(tmp .. "/" .. way .. ".db", held)
    local pid, trouble = process.fork(false)
    if pid == nil then Test.skip("this host forks no copy of the process: " .. trouble) end
    if pid == 0 then
      Sqlite.disown()
      if way == "close" then
        local closed = assert(held["db"]):close()
        if not closed then sys.exit(1) end
      end
      held["db"] = nil
      collectgarbage()
      collectgarbage()
      sys.exit(0)
    end
    local status = assert(process.waitpid(assert(pid), false))
    assert(status.code == 0, "the copy of case " .. tostring(case) .. " ended badly")
    local db = assert(held["db"])
    assert(db:exec("COMMIT"))
    local counted = assert(Sqlite.text_rows(db, "SELECT count(*) FROM t"))
    assert(assert(counted[1]):text(1) == tostring(rows), way .. ": rows are missing: " .. assert(counted[1]):text(1))
    local whole = assert(Sqlite.text_rows(db, "PRAGMA integrity_check"))
    assert(assert(whole[1]):text(1) == "ok", way .. ": " .. assert(whole[1]):text(1))
    assert(db:close())
  end
end
