--- What the tests of the core's refused allocations and of its descriptors share (core/allocation_*_test.tl,
--- core/fault_test.tl and core/socket_test.tl): a walk that refuses each allocation of some work in turn, and the
--- descriptor the next open is handed. Test support.

local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")

local record allocation_fixture
end

--- Runs `work` once per allocation it makes, refusing that allocation,
--- and a last time with none refused; answers how many runs a refusal
--- ended. A run that nothing was refused in must succeed.
---
--- `settle`, when given, runs after each run with allocations granted
--- again, to release what the run was handed. The work cannot release it
--- itself: a worker's coverage hook runs Lua between any two lines, and
--- can itself be refused, so a refusal can fall between a binding's
--- return and the line that would have released what it returned.
--- @param work what to run
--- @param settle what to run after each, with allocations granted
--- @return how many runs a refusal ended
function allocation_fixture.under_every_failure(work: function(), settle?: function()): integer
  local ended = 0
  for after = 0, 1000000 do
    testing.fail_allocations(after)
    local ok, failure = pcall(work)
    local refused = testing.allow_allocations()
    if settle ~= nil then settle() end
    collectgarbage("collect")
    if refused == 0 then
      assert(ok, "the work failed with every allocation granted: " .. tostring(failure))
      return ended
    end
    ended = ended + 1
  end
  error("the work never ran with every allocation granted")
end

--- The descriptor the next open is handed: the lowest free one, so an
--- earlier one left open shows as a higher number.
--- @param tmp a directory to open a probe file in
--- @return the descriptor
function allocation_fixture.next_descriptor(tmp: string): integer
  local fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  local _, _ = sys.close(fd)
  return fd
end

return allocation_fixture
