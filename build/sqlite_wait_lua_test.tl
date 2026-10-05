--- Source-tree database waits stop at a guard signal and release their locks.
local Child = require("cosmic.child")
local type _ = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")
local sys = require("cosmic.sys")
local type Log = require("cosmic.log")
local rebuild_lock = require("build.rebuild_lock")
local this_program = require("build.this_program")
local verdict = require("build.verdict")
local work = require("build.work")

-- TODO: declare this with [`Test.policy`] once a policy field says `lua` (the TODO
-- above [`Test.needs_of`] in cosmic/test.tl).
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

--- A process that sends this one SIGTERM 100 ms after a line on its
--- stdin ([`signal`]), answered once it has started and waits for that
--- line: its start, however slow, comes before the wait it is to end.
local function signaller(): Child.Handle
  local sender = child(([[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
print("ready")
Fs.take(Fs.stdin, 1)
Clock.sleep_ns(%d)
assert(sys.kill(%d, sys.SIGTERM))
]]):format(Clock.ms(100), sys.getpid()))
  assert(Stream.lines(assert(sender.stdout_stream)):read() == "ready")
  return sender
end

--- Tells a [`signaller`] to send its signal.
local function signal(sender: Child.Handle)
  assert(assert(sender.stdin_stream):write("\n"))
end

local function done(started: Child.Handle)
  assert(assert(started:wait(Clock.seconds(5))).ok)
end

local function test_work_begin_stops_the_long_wait_and_can_be_used_again(tmp: string)
  local handle = assert(work.open(tmp))
  assert(work.commit(handle))
  local holder <close> = hold(tmp .. "/o/build.db")
  local guard <close> = assert(Child.guard())
  local sender <close> = signaller()
  signal(sender)
  local begun, reason = work.begin(handle)
  local caught = guard:take()
  guard:release()
  assert(not begun and reason:find("interrupted", 1, true), reason)
  assert(not handle.inside and caught == sys.SIGTERM)
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
  -- The first is caught before the open, which its first BEGIN then
  -- finds; the second is sent once the notice is given, so neither
  -- meets the other phase however slow the host.
  local log = verdict.log
  local complain = log.complain
  for _, retried in ipairs({ false, true }) do
    local notices = 0
    local guard <close> = assert(Child.guard())
    local sender: Child.Handle | nil
    if retried then
      sender = signaller()
    else
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
    end
    log.complain = function(_: Log.Logger, _: string): boolean, string
      notices = notices + 1
      if sender ~= nil then signal(sender) end
      return true, ""
    end
    local ran, opened, reason = pcall(work.open, tmp)
    log.complain = complain
    assert(ran, tostring(opened))
    local caught = guard:take()
    guard:release()
    assert(opened == nil and reason:find("interrupted", 1, true), reason)
    assert(caught == sys.SIGTERM)
    assert(notices == (retried and 1 or 0), notices .. " notices")
    if sender ~= nil then done(sender) end
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
  local sender <close> = signaller()
  signal(sender)
  -- Long past the signal, which the ready handshake leaves only its
  -- 100 ms and a wake-up from, and within CI's 10 s per-test deadline:
  -- a wait the signal did not end answers "busy".
  local taken, reason = rebuild_lock.take(tmp, Clock.seconds(6))
  local caught = guard:take()
  guard:release()
  assert(taken == nil and reason:find("interrupted", 1, true), tostring(taken) .. " " .. reason)
  assert(caught == sys.SIGTERM)
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
