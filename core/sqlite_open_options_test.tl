--- How [`cosmic.sqlite`] waits at a lock and sets a file's journal as it
--- opens it: `wait`, `wal` and `synchronous`, and [`Sqlite.Handle.wal`].

local Clock = require("cosmic.clock")
local Signal = require("cosmic.signal")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")

--- The one text cell `sql` returns on `db`.
local function answer(db: Sqlite.Handle, sql: string): string
  return assert(assert(db:rows(sql))[1]):as_text(1) or ""
end

--- Whether calling `f` raises an error that holds `wanted`.
local function raises_saying(wanted: string, f: function())
  local ok, why = pcall(f)
  assert(not ok, "it did not raise")
  assert(tostring(why):find(wanted, 1, true) ~= nil, tostring(why))
end

local function test_a_file_opens_in_wal_mode_with_its_synchronous(tmp: string)
  local db = assert(Sqlite.open(tmp .. "/w.db", { writable = true, wal = true, synchronous = "normal" }))
  assert(answer(db, "PRAGMA journal_mode") == "wal")
  assert(answer(db, "PRAGMA synchronous") == "1")
  assert(db:close())
  -- Opened again with no options, the file is still in WAL mode.
  local again = assert(Sqlite.open(tmp .. "/w.db", { writable = true, synchronous = "full" }))
  assert(answer(again, "PRAGMA journal_mode") == "wal")
  assert(answer(again, "PRAGMA synchronous") == "2")
  assert(again:wal())
  assert(again:close())
end

local function test_a_memory_database_keeps_its_memory_journal()
  local db = assert(Sqlite.memory())
  assert(db:wal())
  assert(answer(db, "PRAGMA journal_mode") == "memory")
  assert(db:close())
  local opened = assert(Sqlite.open(":memory:", { writable = true, wal = true }))
  assert(opened:close())
end

local function test_options_that_cannot_hold_raise(tmp: string)
  local path = tmp .. "/never.db"
  raises_saying("only a writable database", function()
    local _, _ = Sqlite.open(path, { wal = true })
  end)
  raises_saying("nonnegative", function()
    local _, _ = Sqlite.open(path, { writable = true, wait = -1 })
  end)
  -- From Lua, which no enum holds to the four settings.
  local untyped = assert(load("local open, path = ...; return open(path, { writable = true, synchronous = 'sometimes' })"))
  raises_saying("synchronous is", function() local _ = untyped(Sqlite.open, path) end)
  local Fs = require("cosmic.fs")
  assert(not assert(Fs.status(path)).exists, "an open that raised made the file")
end

--- `wal` tries a busy switch again until the handle's wait has passed,
--- then returns why; once the lock is let go, the switch is made.
local function test_wal_waits_for_the_lock_then_answers_busy(tmp: string)
  local path = tmp .. "/busy.db"
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("CREATE TABLE t (x)"))
  assert(holder:exec("BEGIN EXCLUSIVE"))
  local waiter = assert(Sqlite.open(path, { writable = true, wait = Clock.ms(60) }))
  local started = Clock.monotonic_ns()
  local switched, why = waiter:wal()
  local waited = Clock.monotonic_ns() - started
  assert(not switched and why.code == Sqlite.BUSY, tostring(why))
  assert(waited >= Clock.ms(50), "gave up after " .. tostring(waited) .. " ns")
  assert(holder:exec("COMMIT"))
  assert(waiter:wal())
  assert(answer(waiter, "PRAGMA journal_mode") == "wal")
  assert(waiter:close())
  assert(holder:close())
end

--- A handle told no wait waits at a lock as a guard says: a signal the
--- guard caught stops it at once, where SQLite's own wait would sleep a
--- minute.
local function test_the_default_wait_stops_at_a_guards_signal(tmp: string)
  local path = tmp .. "/guarded.db"
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("CREATE TABLE t (x)"))
  assert(holder:exec("BEGIN IMMEDIATE"))
  local waiter = assert(Sqlite.open(path, { writable = true }))
  local guard <close> = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local started = Clock.monotonic_ns()
  local begun, why = waiter:exec("BEGIN IMMEDIATE")
  local waited = Clock.monotonic_ns() - started
  local caught = guard:take()
  local _, _ = guard:release()
  assert(not begun and why.kind == "cancelled" and why.code == Sqlite.BUSY, tostring(why))
  assert(caught == sys.SIGTERM)
  assert(waited < Clock.seconds(5), "waited " .. tostring(waited) .. " ns")
  assert(holder:exec("COMMIT"))
  assert(waiter:exec("BEGIN IMMEDIATE"))
  assert(waiter:exec("COMMIT"))
  assert(waiter:close())
  assert(holder:close())
end

--- `wait` gives up at its time with SQLite's busy code.
local function test_wait_gives_up_at_its_time(tmp: string)
  local path = tmp .. "/wait.db"
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("CREATE TABLE t (x)"))
  assert(holder:exec("BEGIN IMMEDIATE"))
  local waiter = assert(Sqlite.open(path, { writable = true, wait = 0 }))
  local begun, why = waiter:exec("BEGIN IMMEDIATE")
  assert(not begun and why.code == Sqlite.BUSY and why.kind ~= "cancelled", tostring(why))
  assert(holder:exec("COMMIT"))
  assert(waiter:close())
  assert(holder:close())
end

--- A temporary database keeps its journal, a read-only file that is not in WAL mode cannot be switched, and a
--- signal a guard caught stops the switch.
local function test_wal_on_handles_that_cannot_switch(tmp: string)
  local temporary = assert(Sqlite.open("", { writable = true, wal = true }))
  assert(temporary:wal())
  assert(temporary:close())
  local path = tmp .. "/plain.db"
  local maker = assert(Sqlite.open(path, { writable = true }))
  assert(maker:exec("CREATE TABLE t (x)"))
  assert(maker:close())
  local reader = assert(Sqlite.open(path))
  local switched, why = reader:wal()
  assert(not switched and why.code == 8, tostring(why))
  assert(reader:close())
  local frozen = assert(Sqlite.open(path, { immutable = true }))
  local frozen_switched, frozen_why = frozen:wal()
  assert(not frozen_switched and tostring(frozen_why):find("stayed delete", 1, true) ~= nil, tostring(frozen_why))
  assert(frozen:close())
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("BEGIN EXCLUSIVE"))
  local waiter = assert(Sqlite.open(path, { writable = true }))
  local guard <close> = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local started = Clock.monotonic_ns()
  local stopped, stopped_why = waiter:wal()
  local waited = Clock.monotonic_ns() - started
  local caught = guard:take()
  local _, _ = guard:release()
  assert(not stopped and stopped_why.kind == "cancelled", tostring(stopped_why))
  assert(caught == sys.SIGTERM and waited < Clock.seconds(5), tostring(waited))
  assert(holder:exec("COMMIT"))
  assert(waiter:close())
  assert(holder:close())
end

--- `wait` is set before the switch to WAL, so the switch waits as long as it says; inside a transaction the
--- switch fails and the transaction stays open.
local function test_wait_holds_for_the_switch_and_a_transaction_refuses_it(tmp: string)
  local path = tmp .. "/order.db"
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("CREATE TABLE t (x)"))
  assert(holder:exec("BEGIN EXCLUSIVE"))
  local started = Clock.monotonic_ns()
  local opened, why = Sqlite.open(path, { writable = true, wait = Clock.ms(60), wal = true })
  local waited = Clock.monotonic_ns() - started
  assert(opened == nil and why.code == Sqlite.BUSY, tostring(why))
  assert(waited >= Clock.ms(50) and waited < Clock.seconds(5), tostring(waited))
  assert(holder:exec("COMMIT"))
  assert(holder:exec("BEGIN; INSERT INTO t VALUES (1)"))
  local inside, inside_why = holder:wal()
  assert(not inside, tostring(inside_why))
  assert(holder:in_transaction())
  assert(holder:exec("COMMIT"))
  assert(holder:close())
end
