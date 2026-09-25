--- Worked examples for `cosmic.child`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Child = require("cosmic.child")

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

return Example
