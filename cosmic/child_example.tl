--- Worked examples for [`cosmic.child`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")
local Clock = require("cosmic.clock")

local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- What the examples start, as a program would: this program
--- itself, past its launcher ([`Proc.relaunch`]), so no start takes a
--- shell.
Test.needs{ tool = true }

-- TODO: confine the processes these examples start, once an example
-- may declare what its processes need, as a test does through
-- build.confine's `confine`: examples are shown by `cosmic docs`, and may
-- not import build.confine.

local Example = {}

--- Several children at once, and Ctrl-C ends them before it ends this
--- process: the guard holds SIGINT and SIGTERM while they run, each
--- round asks whether one came, and leaving the guard's scope delivers
--- it again once every child is gone.
function Example.guard()
  local guard <close> = assert(Child.guard())
  -- This program again, past its launcher, each child exiting with its i.
  local again = assert(Proc.relaunch())
  local running: {Child.Handle} = {}
  for i = 1, 3 do
    local argv = { table.unpack(again.argv) }
    argv[#argv + 1] = "-e"
    argv[#argv + 1] = "return " .. tostring(i)
    running[i] = assert(Child.start(argv, { env = again.env, fds = again.fds }))
  end
  while #running > 0 and guard:cancelled() == 0 do
    local done, trouble = Child.wait_any(running, Clock.ms(100))
    if done == nil and trouble ~= Poll.TIMEOUT then error(trouble) end
    local still: {Child.Handle} = {}
    for _, h in ipairs(running) do
      if rawequal(h, done) then
        local result = assert(h:wait())
        print(tostring(result.code))
      else
        still[#still + 1] = h
      end
    end
    running = still
  end
  for _, h in ipairs(running) do assert(h:close()) end
end

--- A supervisor that reports what it was running when a signal
--- interrupts it: it asks the guard after each round, closes the
--- handles still running, which ends their children, and releases the
--- guard rather than closing it, so the signal does not end this
--- process before its report is out. The SIGTERM it sends itself
--- stands in for a Ctrl-C or a `kill`.
function Example.supervisor()
  local guard <close> = assert(Child.guard())
  -- This program again, past its launcher, each child sleeping a minute.
  local again = assert(Proc.relaunch())
  local running: {Child.Handle} = {}
  local names: {Child.Handle:string} = {}
  for _, name in ipairs({ "build", "upload" }) do
    local argv = { table.unpack(again.argv) }
    argv[#argv + 1] = "-e"
    argv[#argv + 1] = "require('cosmic.clock').sleep_ns(60 * 1000000000)"
    local h = assert(Child.start(argv, { env = again.env, fds = again.fds }))
    running[#running + 1] = h
    names[h] = name
  end
  local report: {string} = {}
  while #running > 0 and guard:cancelled() == 0 do
    local done, trouble = Child.wait_any(running, Clock.ms(100))
    if done == nil and trouble ~= Poll.TIMEOUT then error(trouble) end
    local still: {Child.Handle} = {}
    for _, h in ipairs(running) do
      if rawequal(h, done) then
        local result = assert(h:wait())
        report[#report + 1] = names[h] .. (result.ok and " ok" or " failed")
      else
        still[#still + 1] = h
      end
    end
    running = still
    -- Stands in for a Ctrl-C that comes while the children run.
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
  end
  for _, h in ipairs(running) do
    assert(h:close())
    report[#report + 1] = names[h] .. " interrupted"
  end
  local caught = assert(guard:release())
  for _, line in ipairs(report) do print(line) end
  -- A program would exit with this status, as a shell's does for a
  -- command a signal ended.
  local status = caught ~= 0 and 128 + caught or 0
  assert(status == 128 + sys.SIGTERM, tostring(status))
end

--- One child supervised as a shell supervises a command: each signal
--- sent to this process alone is passed on to the child, and releasing
--- the guard, rather than closing it, re-raises the last one only if
--- the child died of it or never got it -- a child that handled Ctrl-C
--- and exited 0 leaves this process running. The last take follows the
--- release, which keeps a signal that lands between them.
function Example.release()
  local guard <close> = assert(Child.guard())
  -- This program again, past its launcher, running an empty chunk.
  local again = assert(Proc.relaunch())
  local argv = { table.unpack(again.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = ""
  local h = assert(Child.start(argv, { env = again.env, fds = again.fds }))
  local result: Child.Result
  while result == nil do
    local state = assert(h:try_wait())
    if state.finished then
      result = state.result
    else
      local taken = guard:take()
      if taken ~= 0 then assert(h:stop(taken)) end
      Clock.sleep_ns(Clock.ms(10))
    end
  end
  local caught = assert(guard:release())
  local untaken = guard:take()
  if caught ~= 0 and (untaken ~= 0 or result.signal == caught) then
    assert(sys.kill(sys.getpid(), caught))
  end
  print(tostring(result.code))
end

--- A child's output read as it comes rather than once it has exited:
--- a filter fed through its stdin stream while its stdout stream is
--- read, neither side stalling on the other however much goes through.
function Example.start()
  -- This program again, past its launcher, as a filter: stdin to
  -- stdout, upper-cased, until stdin ends.
  local again = assert(Proc.relaunch())
  local argv = { table.unpack(again.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = [[
local Fs = require("cosmic.fs")
while true do
  local s = assert(Fs.take(0, 65536))
  if s == "" then break end
  assert(Fs.put(1, s:upper()))
end]]
  local h <close> = assert(Child.start(argv,
    { env = again.env, fds = again.fds, stdin = "stream", stdout = "stream" }))
  local stdin = assert(h.stdin_stream)
  assert(stdin:write("streamed\n"))
  assert(stdin:close())
  assert(Stream.copy(assert(h.stdout_stream), Stream.to_fd(Fs.stdout)))
  assert(assert(h:wait()).ok)
end

--- Both outputs forwarded in bounded rounds to separate borrowed Writers;
--- a byte limit resumes the transfer without changing the child's status.
function Example.drain()
  local again = assert(Proc.relaunch())
  local argv = { table.unpack(again.argv) }
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = [[
local Fs = require("cosmic.fs")
assert(Fs.put(1, "output\n"))
assert(Fs.put(2, "diagnostic\n"))]]
  local h <close> = assert(Child.start(argv,
    { env = again.env, fds = again.fds, stdout = "stream", stderr = "stream" }))
  local options: Child.DrainOptions = {
    stdout = Stream.to_fd(Fs.stdout), stderr = Stream.to_fd(Fs.stderr),
    timeout_ns = Clock.seconds(5), max_bytes = 8,
  }
  while true do
    local drained = h:drain(options)
    if drained.kind == "eof" then break end
    assert(drained.kind == "limit", drained.kind .. ": " .. drained.reason)
  end
  assert(assert(h:wait()).ok)
end

return Example
