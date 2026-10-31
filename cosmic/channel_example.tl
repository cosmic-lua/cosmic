--- Worked examples for [`cosmic.channel`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Channel = require("cosmic.channel")
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")

local Example = {}

--- A producer task and a consumer loop: the consumer takes jobs in the
--- order they were queued until the producer closes the queue, which
--- ends with the word [`Channel.CLOSED`] once the queue is drained.
function Example.new()
  local taken: mut {string} = {}
  Poll.run(function()
    local queue: Channel.Queue<string> = Channel.new({ capacity = 2 })
    Poll.spawn(function()
      for i = 1, 5 do assert(queue:send(("job %d"):format(i))) end
      queue:close()
    end)
    while true do
      local job, why = queue:receive()
      if job == nil then
        print(why)
        assert(why == Channel.CLOSED)
        break
      end
      taken[#taken + 1] = job
    end
  end)
  print(table.concat(taken, ", "))
  assert(#taken == 5 and taken[1] == "job 1" and taken[5] == "job 5")
end

--- A full "block" queue makes `send` wait for room, so a fast producer
--- is slowed to its consumer's pace; `try_send` and a timeout say
--- no instead of waiting.
function Example.send()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(1))
    local ok, why = queue:try_send(2)
    print(ok, why)
    assert(not ok and why == Channel.FULL)
    ok, why = queue:send(2, Clock.ms(5))
    print(ok, why)
    assert(not ok and why == Poll.TIMEOUT)
    local producer = Poll.spawn(function() assert(queue:send(3)) end)
    assert(queue:receive() == 1)
    assert(producer:join())
    print(queue:len(), queue:receive())
  end)
end

--- A feed that keeps the latest items for a slow reader: when the queue
--- is full "drop_oldest" discards from the front, and `dropped` counts
--- what was lost.
function Example.dropped()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 3, overflow = "drop_oldest" })
    for i = 1, 10 do assert(queue:send(i)) end
    local oldest = queue:receive()
    print(queue:len(), queue:dropped(), oldest)
    assert(queue:len() == 2 and queue:dropped() == 7 and oldest == 8)
  end)
end

--- A "close" queue cuts off a consumer that falls behind: the send that
--- finds it full closes it, the consumer takes what was queued, and
--- `closed` says why nothing more comes.
function Example.closed()
  Poll.run(function()
    local queue: Channel.Queue<string> = Channel.new({ capacity = 1, overflow = "close" })
    assert(queue:send("first"))
    local ok, why = queue:send("second")
    print(ok, why, queue:closed())
    assert(not ok and why == Channel.CLOSED and queue:closed())
    assert(queue:receive() == "first")
    local item, reason = queue:receive()
    assert(item == nil and reason == Channel.CLOSED)
  end)
end

return Example
