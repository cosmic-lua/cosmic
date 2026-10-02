--- Source-tree database waits stop at a guard signal and release their locks.
local Child = require("cosmic.child")
local type _ = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")
local work = require("build.work")

Test.needs{ lua = true }

local function child(script: string): Child.Handle
  local command = this_program.program({ "-e", script },
    { stdin = "stream", stdout = "stream", stderr = "capture" })
  return (assert(Child.start(command.argv, command.options)))
end

local function hold(path: string): Child.Handle
  local holder = child(([[
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local db = assert(Sqlite.open(%q, { writable = true }))
assert(db:exec("BEGIN IMMEDIATE"))
print("held")
Fs.take(Fs.stdin, 1)
assert(db:close())
]]):format(path))
  assert(Stream.lines(assert(holder.stdout_stream)):read() == "held")
  return holder
end

local function signal_after(ns: integer): Child.Handle
  return child(([[
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
Time.sleep_ns(%d)
assert(sys.kill(%d, sys.SIGTERM))
]]):format(ns, sys.getpid()))
end

local function done(started: Child.Handle)
  assert(assert(started:wait(Time.seconds(5))).ok)
end

local function test_work_begin_stops_the_long_wait_and_can_be_used_again(tmp: string)
  local handle = assert(work.open(tmp))
  assert(work.commit(handle))
  local holder <close> = hold(tmp .. "/o/build.db")
  local guard <close> = assert(Child.guard())
  local sender <close> = signal_after(Time.ms(100))
  local started = Time.monotonic_ns()
  local begun, reason = work.begin(handle)
  local elapsed = Time.monotonic_ns() - started
  local signal = guard:take()
  guard:release()
  assert(not begun and reason:find("interrupted", 1, true), reason)
  assert(not handle.inside and signal == sys.SIGTERM and elapsed < Time.seconds(2))
  done(sender)
  assert(assert(holder.stdin_stream):close())
  done(holder)
  assert(work.begin(handle))
  assert(work.close(handle))
end

local function test_work_open_does_not_retry_a_cancelled_first_or_second_begin(tmp: string)
  local initial = assert(work.open(tmp))
  assert(work.close(initial))
  local holder <close> = hold(tmp .. "/o/build.db")
  -- One signal meets the first brief BEGIN; the other meets its long
  -- retry after the one-second notice. Neither may become another retry.
  for _, after in ipairs({ Time.ms(100), Time.ms(1300) }) do
    local guard <close> = assert(Child.guard())
    local sender <close> = signal_after(after)
    local started = Time.monotonic_ns()
    local opened, reason = work.open(tmp)
    local elapsed = Time.monotonic_ns() - started
    local signal = guard:take()
    guard:release()
    assert(opened == nil and reason:find("interrupted", 1, true), reason)
    assert(signal == sys.SIGTERM and elapsed < after + Time.seconds(2))
    done(sender)
  end
  assert(assert(holder.stdin_stream):close())
  done(holder)
  assert(work.close((assert(work.open(tmp)))))
end

local function test_rebuild_sqlite_wait_releases_the_flock_after_cancellation(tmp: string)
  local initial = assert(work.open(tmp))
  assert(work.close(initial))
  local path = tmp .. "/o/rebuild.lock"
  local holder <close> = hold(path)
  -- A local flock is apart from SQLite's fcntl lock. Other filesystems
  -- use the flock itself to exclude the SQLite holder, so either wait
  -- must still end at the guard and leave neither half held.
  local guard <close> = assert(Child.guard())
  local sender <close> = signal_after(Time.ms(100))
  local started = Time.monotonic_ns()
  local taken, reason = rebuild_lock.take(tmp, Time.seconds(5))
  local elapsed = Time.monotonic_ns() - started
  local signal = guard:take()
  guard:release()
  assert(taken == nil and reason:find("interrupted", 1, true), reason)
  assert(signal == sys.SIGTERM and elapsed < Time.seconds(2))
  done(sender)
  assert(assert(holder.stdin_stream):close())
  done(holder)
  assert(rebuild_lock.take(tmp, 0) == "held")
  rebuild_lock.release()
  local db = assert(Sqlite.open(path, { writable = true }))
  db:busy_timeout(0)
  assert(db:exec("BEGIN IMMEDIATE"))
  assert(db:close())
end
