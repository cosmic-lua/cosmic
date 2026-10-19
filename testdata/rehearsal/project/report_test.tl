local Queue = require("queue")
local Report = require("report")

local function test_a_report_says_how_many_words_wait_and_which()
  local queue = Queue.new()
  Queue.push(queue, "b")
  Queue.push(queue, "a")
  Queue.sort(queue)
  local text = assert(Report.of(queue))
  assert(text == '{"count":2,"words":"a,b"}', text)
end
