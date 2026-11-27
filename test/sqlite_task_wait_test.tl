--- In a task of Poll.run, a call that meets another connection's lock
--- parks the task, so the other tasks run. Each test holds the lock on a
--- second connection in this process and lets it go from another task:
--- a wait that held the thread would never see that task run.
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Poll = require("cosmic.poll")
local Sqlite = require("cosmic.sqlite")

--- A database at `path` with a table `t`, and a second handle on it
--- that holds `lock` ("BEGIN IMMEDIATE" or "BEGIN EXCLUSIVE").
local function held(path: string, lock: string): Sqlite.Handle, Sqlite.Handle
  local holder = assert(Sqlite.open(path, { writable = true }))
  assert(holder:exec("CREATE TABLE IF NOT EXISTS t (x INTEGER)"))
  local waiter = assert(Sqlite.open(path, { writable = true, wait = Clock.seconds(5) }))
  assert(holder:exec(lock))
  return holder, waiter
end

--- Runs `wait` as a task beside one that ends `holder`'s transaction
--- after `hold_ns`: what `wait` returned, and whether the other task
--- let go before `wait` returned.
local function race(holder: Sqlite.Handle, hold_ns: integer, wait: function(): boolean): boolean, boolean
  local answered, released_first = false, false
  local released = false
  Poll.run(function()
    local waiting = Poll.spawn(function()
      answered = wait()
      released_first = released
    end)
    assert(Clock.sleep(hold_ns))
    assert(holder:exec("COMMIT"))
    released = true
    assert(waiting:join())
  end)
  return answered, released_first
end

local function test_a_run_parks_at_a_write_lock(tmp: string)
  local holder, waiter = held(tmp .. "/run.db", "BEGIN IMMEDIATE")
  local ok, first = race(holder, Clock.ms(30), function(): boolean
    local done, _ = waiter:run("INSERT INTO t VALUES (?1)", { 1 })
    return done == true
  end)
  assert(ok and first)
  assert(assert(waiter:one("SELECT count(*) FROM t")):integer(1) == 1)
  assert(holder:close())
  assert(waiter:close())
end

local function test_a_transact_parks_at_its_begin(tmp: string)
  local holder, waiter = held(tmp .. "/transact.db", "BEGIN IMMEDIATE")
  local ok, first = race(holder, Clock.ms(30), function(): boolean
    local done, _ = waiter:transact(function(): (true) | (nil, Failure)
      return waiter:run("INSERT INTO t VALUES (2)")
    end)
    return done == true
  end)
  assert(ok and first)
  assert(not waiter:in_transaction())
  assert(holder:close())
  assert(waiter:close())
end

local function test_a_query_parks_at_a_read_lock(tmp: string)
  local holder, waiter = held(tmp .. "/read.db", "BEGIN IMMEDIATE")
  assert(holder:exec("INSERT INTO t VALUES (3)"))
  -- Prepared before the lock, so the wait is the step's, not the schema's.
  local reading = assert(waiter:prepare("SELECT x FROM t"))
  assert(holder:exec("COMMIT; BEGIN EXCLUSIVE"))
  local ok, first = race(holder, Clock.ms(30), function(): boolean
    local rows, _ = reading:rows()
    return rows ~= nil and #rows == 1
  end)
  assert(ok and first)
  reading:close()
  assert(holder:close())
  assert(waiter:close())
end

local function test_a_prepare_parks_at_a_schema_read(tmp: string)
  local path = tmp .. "/schema.db"
  local holder, waiter = held(path, "BEGIN EXCLUSIVE")
  -- A handle reads the schema at its first prepare, under the lock.
  local fresh = assert(Sqlite.open(path, { wait = Clock.seconds(5) }))
  local ok, first = race(holder, Clock.ms(30), function(): boolean
    local statement, _ = fresh:prepare("SELECT x FROM t")
    if statement == nil then return false end
    statement:close()
    return true
  end)
  assert(ok and first)
  assert(fresh:close())
  assert(holder:close())
  assert(waiter:close())
end

--- Two tasks on one handle: while one waits at a lock in a run, the
--- other's transaction waits its turn, so neither runs inside the other.
local function test_a_task_waits_its_turn_behind_one_parked_on_its_handle(tmp: string)
  local holder, waiter = held(tmp .. "/turn.db", "BEGIN IMMEDIATE")
  local order: mut {string} = {}
  Poll.run(function()
    local writing = Poll.spawn(function()
      assert(waiter:run("INSERT INTO t VALUES (1)"))
      order[#order + 1] = "run"
    end)
    local undoing = Poll.spawn(function()
      local done, _ = waiter:transact(function(): (true) | (nil, Failure)
        assert(waiter:run("INSERT INTO t VALUES (2)"))
        return nil, Failure.new("rolled back")
      end)
      assert(not done)
      order[#order + 1] = "transact"
    end)
    assert(Clock.sleep(Clock.ms(30)))
    assert(holder:exec("COMMIT"))
    assert(writing:join())
    assert(undoing:join())
  end)
  assert(order[1] == "run" and order[2] == "transact")
  -- The run's row stood, and the rolled back transaction took none with it.
  local rows = assert(waiter:rows("SELECT x FROM t"))
  assert(#rows == 1 and rows[1]:integer(1) == 1)
  assert(holder:close())
  assert(waiter:close())
end

--- A PRAGMA does not park: a checkpoint yields its row as busy where
--- the wait is declined, so the core waits for it, holding the thread.
local function test_a_pragma_waits_in_the_core(tmp: string)
  local holder = assert(Sqlite.open(tmp .. "/pragma.db", { writable = true }))
  assert(holder:exec("CREATE TABLE t (x INTEGER)"))
  local waiter = assert(Sqlite.open(tmp .. "/pragma.db", { writable = true, wait = Clock.ms(40) }))
  assert(holder:exec("BEGIN IMMEDIATE"))
  local ticks, ticked_in_wait = 0, -1
  Poll.run(function()
    local ticking = Poll.spawn(function()
      for _ = 1, 4 do
        ticks = ticks + 1
        assert(Clock.sleep(Clock.ms(5)))
      end
    end)
    local done, _ = waiter:run("PRAGMA user_version = 3")
    assert(not done)
    ticked_in_wait = ticks
    assert(ticking:join())
  end)
  assert(ticked_in_wait == 0 and ticks == 4)
  assert(holder:exec("COMMIT"))
  assert(holder:close())
  assert(waiter:close())
end

local function test_a_parked_wait_ends_at_the_handles_wait(tmp: string)
  local holder = assert(Sqlite.open(tmp .. "/spent.db", { writable = true }))
  assert(holder:exec("CREATE TABLE t (x INTEGER)"))
  local waiter = assert(Sqlite.open(tmp .. "/spent.db", { writable = true, wait = Clock.ms(40) }))
  assert(holder:exec("BEGIN IMMEDIATE"))
  local ticks, ticked_in_wait = 0, 0
  local why: Failure? = nil
  Poll.run(function()
    local ticking = Poll.spawn(function()
      for _ = 1, 20 do
        ticks = ticks + 1
        assert(Clock.sleep(Clock.ms(5)))
      end
    end)
    local started = Clock.monotonic_ns()
    local done, trouble = waiter:run("INSERT INTO t VALUES (1)")
    assert(not done and Clock.monotonic_ns() - started >= Clock.ms(40))
    ticked_in_wait = ticks
    why = trouble
    assert(ticking:join())
  end)
  local failure = assert(why)
  assert(failure.code == Sqlite.BUSY)
  -- The other task ticked while this one waited, not only after.
  assert(ticked_in_wait >= 2 and ticks == 20)
  assert(holder:exec("COMMIT"))
  assert(holder:close())
  assert(waiter:close())
end

local function test_a_task_cancelled_at_a_lock_fails_cancelled(tmp: string)
  local holder, waiter = held(tmp .. "/cancel.db", "BEGIN IMMEDIATE")
  local why: Failure? = nil
  Poll.run(function()
    local waiting = Poll.spawn(function()
      local _, trouble = waiter:run("INSERT INTO t VALUES (1)")
      why = trouble
    end)
    assert(Clock.sleep(Clock.ms(20)))
    waiting:cancel()
    assert(waiting:join())
  end)
  local failure = assert(why)
  assert(failure.kind == "cancelled" and failure.code == Sqlite.BUSY)
  assert(holder:exec("COMMIT"))
  -- The statement the cancelled run stepped is whole: the next run works.
  assert(waiter:run("INSERT INTO t VALUES (1)"))
  assert(holder:close())
  assert(waiter:close())
end

--- Outside any task the core waits, as before: the call holds the thread
--- and fails BUSY once the wait has passed.
local function test_outside_a_task_the_wait_holds_the_thread(tmp: string)
  local holder = assert(Sqlite.open(tmp .. "/plain.db", { writable = true }))
  assert(holder:exec("CREATE TABLE t (x INTEGER)"))
  local waiter = assert(Sqlite.open(tmp .. "/plain.db", { writable = true, wait = Clock.ms(20) }))
  assert(holder:exec("BEGIN IMMEDIATE"))
  local co = coroutine.create(function(): boolean
    local done, why = waiter:run("INSERT INTO t VALUES (1)")
    return not done and why.code == Sqlite.BUSY
  end)
  local resumed, busy = coroutine.resume(co)
  assert(resumed and busy == true and coroutine.status(co) == "dead")
  assert(holder:exec("COMMIT"))
  assert(holder:close())
  assert(waiter:close())
end
