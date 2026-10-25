local Queue = require("queue")

local function test_a_queue_gives_its_words_back_in_the_order_they_came()
  local queue = Queue.new()
  queue:push("b")
  queue:push("a")
  assert(queue:pop() == "b" and queue:pop() == "a" and queue:pop() == nil)
end

local function test_the_words_waiting_come_sorted()
  local queue = Queue.new()
  for _, word in ipairs({ "pear", "apple", "fig" }) do
    queue:push(word)
  end
  queue:sort()
  assert(queue:line() == "apple,fig,pear")
end
