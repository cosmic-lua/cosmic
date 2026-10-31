local Queue = require("queue")

local function test_a_queue_gives_its_words_back_in_the_order_they_came()
  local queue = Queue.new()
  queue:push("b")
  queue:push("a")
  assert(queue:pop() == "b" and queue:pop() == "a" and queue:pop() == nil)
  assert(queue.length == 0)
end
