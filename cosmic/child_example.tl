--- Worked examples for `cosmic.child`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Child = require("cosmic.child")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")

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

--- One child supervised as a shell supervises a command: a signal
--- sent to this process alone is passed on to the child, and releasing
--- the guard, rather than closing it, re-raises the signal only if the
--- child died of it -- a child that handled Ctrl-C and exited 0 leaves
--- this process running.
function Example.release()
  local guard <close> = assert(Child.guard())
  local h = assert(Child.start({ "/bin/sh", "-c", "exit 0" }))
  local passed_on = false
  local result: Child.Result
  while result == nil do
    local state = assert(h:try_wait())
    if state.finished then
      result = state.result
    else
      if not passed_on and guard:cancelled() ~= 0 then
        assert(h:stop(guard:cancelled()))
        passed_on = true
      end
      Time.sleep_ns(10 * 1000 * 1000)
    end
  end
  local caught = assert(guard:release())
  if caught ~= 0 and result.signal == caught then
    assert(sys.kill(sys.getpid(), caught))
  end
  print(tostring(result.code))
end

return Example
