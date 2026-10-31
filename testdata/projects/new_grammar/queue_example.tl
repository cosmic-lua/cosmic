--- Worked examples for the queue, shown by `cosmic docs` and run by `cosmic test`.
local Queue = require("queue")

local record Example end

--- Words come out in the order they went in, and `pop` answers nil once none waits.
function Example.order()
  local queue = Queue.new()
  queue:push("first")
  queue:push("second")
  assert(queue:pop() == "first")
  assert(queue:pop() == "second")
  assert(queue:pop() == nil)
end

return Example
