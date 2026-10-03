--- Busy waits use real locks and signals from independent processes.
local Child = require("cosmic.child")
local type _ = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

Test.needs{ lua = true }

local function start(script: string): Child.Handle
  local command = this_program.program({ "-e", script },
    { stdin = "stream", stdout = "stream", stderr = "capture" })
  return (assert(Child.start(command.argv, command.options)))
end

--- Waits for stdin to close, then releases after `hold_ns`.
local function holder(path: string, hold_ns?: integer): Child.Handle
  local child = start(([[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local db = assert(Sqlite.open(%q, { writable = true }))
assert(db:exec("CREATE TABLE IF NOT EXISTS t (x)"))
assert(db:exec("BEGIN IMMEDIATE"))
print("held")
Fs.take(Fs.stdin, 1)
Clock.sleep_ns(%d)
assert(db:close())
]]):format(path, hold_ns or 0))
  assert(Stream.lines(assert(child.stdout_stream)):read() == "held")
  return child
end

local function finish(child: Child.Handle)
  assert(assert(child:wait(Clock.seconds(5))).ok)
end

--- A process that sends this one SIGTERM 100 ms after a line on its
--- stdin ([`interrupt`]), answered once it has started and waits for
--- that line: its start, however slow, comes before the clock.
local function interrupter(): Child.Handle
  local child = start(([[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
print("ready")
Fs.take(Fs.stdin, 1)
Clock.sleep_ns(%d)
assert(sys.kill(%d, sys.SIGTERM))
]]):format(Clock.ms(100), sys.getpid()))
  assert(Stream.lines(assert(child.stdout_stream)):read() == "ready")
  return child
end

--- Tells an [`interrupter`] to send its signal.
local function interrupt(child: Child.Handle)
  assert(assert(child.stdin_stream):write("\n"))
end

local function test_busy_wait_keeps_the_signal_and_clears_only_the_operations_flag(tmp: string)
  local held <close> = holder(tmp .. "/db")
  local db = assert(Sqlite.open(tmp .. "/db", { writable = true }))
  -- Long past the signal, which the ready handshake leaves only its
  -- 100 ms and a wake-up from, and within CI's 10 s per-test deadline:
  -- a wait the signal did not end answers BUSY, not cancelled.
  db:busy_timeout(Clock.seconds(6))
  local guard <close> = assert(Child.guard())
  local sender <close> = interrupter()
  interrupt(sender)
  local cancelled = db:exec_result("BEGIN IMMEDIATE")
  local signal = guard:take()
  db:busy_timeout(Clock.ms(30))
  local ordinary = db:exec_result("BEGIN IMMEDIATE")
  local historical = guard:cancelled()
  guard:release()
  assert(cancelled.code == Sqlite.BUSY and cancelled.extended_code == Sqlite.BUSY and cancelled.cancelled,
    "guard cancellation waited out the long timeout")
  assert(cancelled.reason ~= "" and signal == sys.SIGTERM and historical == sys.SIGTERM)
  assert(ordinary.code == Sqlite.BUSY and ordinary.cancelled == false)
  assert(cancelled.cancelled, "a later operation changed the captured cancellation")
  finish(sender)
  assert(assert(held.stdin_stream):close())
  finish(held)
  local success = db:exec_result("BEGIN IMMEDIATE")
  assert(success.code == Sqlite.OK and success.cancelled == false)
  assert(db:close())
end

local function test_busy_wait_uses_the_innermost_unread_guard_notification(tmp: string)
  local held <close> = holder(tmp .. "/db")
  local db = assert(Sqlite.open(tmp .. "/db", { writable = true }))
  db:busy_timeout(Clock.ms(20))
  local outer <close> = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local inner <close> = assert(Child.guard())
  local hidden = db:exec_result("BEGIN IMMEDIATE")
  local inner_signal = inner:release()
  local restored = db:exec_result("BEGIN IMMEDIATE")
  local outer_signal = outer:take()
  local next_wait = db:exec_result("BEGIN IMMEDIATE")
  outer:release()
  assert(hidden.code == Sqlite.BUSY and hidden.cancelled == false and inner_signal == 0)
  assert(restored.code == Sqlite.BUSY and restored.cancelled and outer_signal == sys.SIGTERM)
  assert(next_wait.code == Sqlite.BUSY and next_wait.cancelled == false, "a prior call contaminated the next")
  assert(db:close())
  assert(assert(held.stdin_stream):close())
  finish(held)
end

local function test_pragma_replaces_the_custom_handler_and_the_method_reinstalls_it(tmp: string)
  local held <close> = holder(tmp .. "/db")
  local db = assert(Sqlite.open(tmp .. "/db", { writable = true }))
  db:busy_timeout(Clock.seconds(5))
  assert(assert(Sqlite.text_rows(db, "PRAGMA busy_timeout"))[1][1] == "0")
  assert(db:exec("PRAGMA busy_timeout = 20"))
  local guard <close> = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local replaced = db:exec_result("BEGIN IMMEDIATE")
  db:busy_timeout(Clock.seconds(5))
  local reinstalled = db:exec_result("BEGIN IMMEDIATE")
  local signal = guard:take()
  guard:release()
  assert(replaced.code == Sqlite.BUSY and replaced.cancelled == false)
  assert(reinstalled.code == Sqlite.BUSY and reinstalled.cancelled and signal == sys.SIGTERM)
  assert(db:close())
  assert(assert(held.stdin_stream):close())
  finish(held)
end

local function test_zero_short_and_prepared_waits_have_separate_budgets(tmp: string)
  local held <close> = holder(tmp .. "/db", Clock.ms(50))
  local db = assert(Sqlite.open(tmp .. "/db", { writable = true }))
  for _, ns in ipairs({ 0, 1, Clock.ms(30) }) do
    db:busy_timeout(ns)
    local begun = Clock.monotonic_ns()
    local busy = db:exec_result("BEGIN IMMEDIATE")
    local elapsed = Clock.monotonic_ns() - begun
    assert(busy.code == Sqlite.BUSY and busy.cancelled == false)
    assert(elapsed < Clock.seconds(2))
    if ns >= Clock.ms(30) then assert(elapsed >= Clock.ms(10)) end
  end
  local statement = assert(db:prepare("INSERT INTO t VALUES (1)"))
  local guard <close> = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local state, reason = statement:step()
  local signal = guard:take()
  guard:release()
  assert(state == nil and reason ~= "" and signal == sys.SIGTERM)
  -- reset reports the previous step's BUSY; it still rewinds the statement.
  local reset, reset_reason = statement:reset()
  assert(not reset and reset_reason ~= "")
  db:busy_timeout(Clock.seconds(2))
  assert(assert(held.stdin_stream):close())
  assert(statement:step() == "done")
  statement:finalize()
  finish(held)
  assert(db:close())
end

--- One exec's two inserts wait on two holders under one budget. The
--- holders let go 1.5 s and 3.5 s after their stdin closes, and the
--- budget is 2.5 s: shared, it runs out at 2.5 s with the second lock
--- still held; restarted at the first insert, it would run to 4 s and
--- take the second lock at 3.5 s. A pass holds while the exec starts
--- less than 1 s after the stdin closes and the first holder lets go
--- less than 1 s late. A restarted budget is caught only while the
--- second holder lets go less than 0.5 s later than the first does.
local function test_one_exec_shares_a_budget_across_separate_database_locks(tmp: string)
  local first <close> = holder(tmp .. "/first", Clock.ms(1500))
  local second <close> = holder(tmp .. "/second", Clock.ms(3500))
  local db = assert(Sqlite.open(tmp .. "/first", { writable = true }))
  assert(db:exec("ATTACH DATABASE '" .. tmp .. "/second' AS other"))
  db:busy_timeout(Clock.ms(2500))
  assert(assert(first.stdin_stream):close())
  assert(assert(second.stdin_stream):close())
  local result = db:exec_result("INSERT INTO main.t VALUES (1); INSERT INTO other.t VALUES (2)")
  assert(result.code == Sqlite.BUSY and result.cancelled == false,
    "the second locking event restarted the timeout and acquired a late lock")
  finish(first)
  finish(second)
  assert(assert(Sqlite.text_rows(db, "SELECT count(*) FROM main.t"))[1][1] == "1")
  assert(assert(Sqlite.text_rows(db, "SELECT count(*) FROM other.t"))[1][1] == "0")
  assert(db:close())
end

local function test_typed_step_captures_cancellation_before_finalize(tmp: string)
  local held <close> = holder(tmp .. "/db")
  local db = assert(Sqlite.open(tmp .. "/db", { writable = true }))
  db:busy_timeout(Clock.seconds(5))
  local guard <close> = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local cancelled = Sqlite.run_result(db, "INSERT INTO t VALUES (1)")
  local signal = guard:take()
  guard:release()
  assert(cancelled.code == Sqlite.BUSY and cancelled.cancelled and signal == sys.SIGTERM)
  db:busy_timeout(0)
  local busy = Sqlite.run_result(db, "INSERT INTO t VALUES (2)")
  assert(busy.code == Sqlite.BUSY and not busy.cancelled)
  assert(cancelled.cancelled and cancelled.reason ~= "")
  assert(db:close())
  assert(assert(held.stdin_stream):close())
  finish(held)
end
