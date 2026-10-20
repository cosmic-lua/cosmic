local Queue = require("queue")

local function test_a_queue_gives_its_words_back_in_the_order_they_came()
  local queue = Queue.new()
  Queue.push(queue, "b")
  Queue.push(queue, "a")
  assert(Queue.pop(queue) == "b" and Queue.pop(queue) == "a" and Queue.pop(queue) == nil)
end

local function test_the_words_waiting_come_sorted()
  local queue = Queue.new()
  for _, word in ipairs({ "pear", "apple", "fig" }) do
    Queue.push(queue, word)
  end
  Queue.sort(queue)
  assert(Queue.line(queue) == "apple,fig,pear")
end
