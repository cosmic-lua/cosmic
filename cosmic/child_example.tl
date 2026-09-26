--- Worked examples for `cosmic.child`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- The processes the examples start, as a program would.
Test.needs{ processes = true }

-- TODO: confine the shell these examples start, so their verdicts can
-- stand, once an example may declare what its processes need: examples
-- are shown by `cosmic docs`, and may not import
-- build.filesystem_observations.

local Example = {}

--- Several children at once, and Ctrl-C ends them before it ends this
--- process: the guard holds SIGINT and SIGTERM while they run, each
--- round asks whether one came, and leaving the guard's scope delivers
--- it again once every child is gone.
function Example.guard()
  local guard <close> = assert(Child.guard())
  local running: {Child.Handle} = {}
  for i = 1, 3 do
    running[i] = assert(Child.start({ "/bin/sh", "-c", "exit " .. tostring(i) }))
  end
  while #running > 0 and guard:cancelled() == 0 do
    local done, trouble = Child.wait_any(running, 100)
    if done == nil and trouble ~= "" then error(trouble) end
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

--- One child supervised as a shell supervises a command: each signal
--- sent to this process alone is passed on to the child, and releasing
--- the guard, rather than closing it, re-raises the last one only if
--- the child died of it or never got it -- a child that handled Ctrl-C
--- and exited 0 leaves this process running. The last take follows the
--- release, which keeps a signal that lands between them.
function Example.release()
  local guard <close> = assert(Child.guard())
  local h = assert(Child.start({ "/bin/sh", "-c", "exit 0" }))
  local result: Child.Result
  while result == nil do
    local state = assert(h:try_wait())
    if state.finished then
      result = state.result
    else
      local taken = guard:take()
      if taken ~= 0 then assert(h:stop(taken)) end
      Time.sleep_ns(10 * 1000 * 1000)
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
  local h <close> = assert(Child.start({ "/bin/sh", "-c", "tr a-z A-Z" },
    { stdin = "stream", stdout = "stream" }))
  local stdin = assert(h.stdin_stream)
  assert(stdin:write("streamed\n"))
  assert(stdin:close())
  assert(Stream.copy(assert(h.stdout_stream), Stream.to_fd(Fs.stdout)))
  assert(assert(h:wait()).ok)
end

return Example
