--- `handle:time_limit(ns)`: SQLite's progress handler stops a call that runs past its time, or one a guard's signal
--- interrupts, and the handle goes on.
local Clock = require("cosmic.clock")
local Signal = require("cosmic.signal")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")

--- A query that never ends by itself: it counts the rows of an endless recursion.
local ENDLESS <const> = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"

local function test_a_call_past_its_time_limit_is_stopped_and_the_handle_goes_on()
  local db = assert(Sqlite.open(":memory:"))
  db:time_limit(Clock.ms(100))
  local started = Clock.monotonic_ns()
  local statement = assert(db.connection:prepare(ENDLESS))
  local step, why = statement:step()
  assert(step == nil and tostring(why):find("ran past its time limit", 1, true) ~= nil, tostring(why))
  statement:finalize()
  assert(Clock.monotonic_ns() - started < Clock.seconds(10), "stopped near its limit")
  -- Each call has a budget of its own.
  local rows = assert(db:rows("SELECT 1 AS one"))
  assert(assert(rows[1]):integer(1) == 1)
  local ran, failure = db:run(ENDLESS)
  assert(not ran and failure.kind == "timeout" and failure.code == Sqlite.INTERRUPT, tostring(failure))
  local done, done_why = db:exec(ENDLESS)
  assert(not done and done_why.kind == "timeout" and done_why.message:find("ran past its time limit", 1, true) ~= nil,
    tostring(done_why))
  local result = db:exec_result(ENDLESS)
  assert(result.timed_out == true and result.code == Sqlite.INTERRUPT and result.cancelled == false, result.reason)
  db:time_limit(nil)
  assert(db:rows("SELECT count(*) FROM generate_series(1, 100000)"))
  assert(db:close())
end

local function test_a_guards_signal_stops_a_call_under_a_time_limit()
  local db = assert(Sqlite.open(":memory:"))
  db:time_limit(Clock.seconds(60))
  local guard <close> = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  local ran, failure = db:run(ENDLESS)
  local signal = guard:take()
  local _, _ = guard:release()
  assert(not ran and failure.kind == "cancelled" and failure.code == Sqlite.INTERRUPT and signal == sys.SIGTERM,
    tostring(failure))
  assert(failure.message:find("signal", 1, true) ~= nil, failure.message)
  assert(db:rows("SELECT 1"))
  -- The stop is the call's own: a later call past its time is a timeout, not a cancel.
  db:time_limit(Clock.ms(100))
  local later, later_why = db:run(ENDLESS)
  assert(not later and later_why.kind == "timeout", tostring(later_why))
  assert(db:close())
end

local function test_a_time_limit_refuses_a_negative_duration()
  local db = assert(Sqlite.open(":memory:"))
  local ok, err = pcall(function() db:time_limit(-1) end)
  assert(not ok and tostring(err):find("nonnegative", 1, true) ~= nil, tostring(err))
  assert(db:close())
end
