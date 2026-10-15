local Channel = require("cosmic.channel")
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")

local record Closer
  metamethod __close: function(Closer)
end

local function raises(fn: function(), words: string)
  local ok, err: boolean, any = pcall(fn)
  assert(not ok, "expected a raise naming " .. words)
  assert(tostring(err):find(words, 1, true), tostring(err))
end

--- A task that receives until `count` items or a failure, appending what
--- it gets to `into` and its last failure to `last`.
local function consumer(queue: Channel.Queue<integer>, into: {integer}, last: {string},
                        timeout_ns?: integer): Poll.Task
  return Poll.spawn(function()
    while true do
      local item, why = queue:receive(timeout_ns)
      if item == nil then
        last[#last + 1] = why
        return
      end
      into[#into + 1] = item
    end
  end)
end

local function test_items_leave_in_the_order_they_came()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 4 })
    for i = 1, 4 do assert(queue:send(i)) end
    assert(queue:len() == 4)
    for i = 1, 4 do
      local item, why = queue:receive()
      assert(item == i and why == "")
    end
    assert(queue:len() == 0)
    -- The ring wraps: more passes through than the capacity.
    for i = 1, 10 do
      assert(queue:send(i))
      assert(queue:receive() == i)
    end
  end)
end

local function test_options_are_checked_and_default_to_a_large_blocking_queue()
  Poll.run(function()
    raises(function() Channel.new({ capacity = 0 }) end, "capacity")
    local fractional: any = { capacity = 1.5 }
    raises(function() Channel.new(fractional as Channel.Options) end, "capacity")
    raises(function() Channel.new({ overflow = "sometimes" as Channel.Overflow }) end, "overflow")
    local queue: Channel.Queue<integer> = Channel.new()
    for i = 1, 256 do assert(queue:try_send(i)) end
    local ok, why = queue:try_send(257)
    assert(not ok and why == Channel.FULL)
    raises(function() queue:send(nil as integer) end, "nil")
    raises(function() queue:receive(-1) end, "timeout_ns")
  end)
  raises(function() Channel.new() end, "outside Poll.run")
end

local function test_block_makes_try_send_fail_and_send_time_out_when_full()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(1))
    local ok, why = queue:try_send(2)
    assert(not ok and why == Channel.FULL)
    ok, why = queue:send(2, Clock.ms(5))
    assert(not ok and why == Poll.TIMEOUT)
    ok, why = queue:send(2, 0)
    assert(not ok and why == Poll.TIMEOUT)
    assert(queue:len() == 1 and queue:dropped() == 0)
    assert(queue:receive() == 1)
  end)
end

local function test_drop_oldest_keeps_the_newest_and_counts_the_drops()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 3, overflow = "drop_oldest" })
    for i = 1, 7 do assert(queue:send(i)) end
    assert(queue:dropped() == 4 and queue:len() == 3)
    local got: {integer} = {}
    for _ = 1, 3 do got[#got + 1] = queue:receive() as integer end
    assert(table.concat(got as {string}, ",") == "5,6,7")
    assert(queue:try_send(8))
    assert(queue:receive() == 8)
  end)
end

local function test_drop_newest_keeps_the_oldest_and_counts_the_drops()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 3, overflow = "drop_newest" })
    for i = 1, 7 do assert(queue:send(i)) end
    assert(queue:dropped() == 4 and queue:len() == 3)
    local got: {integer} = {}
    for _ = 1, 3 do got[#got + 1] = queue:receive() as integer end
    assert(table.concat(got as {string}, ",") == "1,2,3")
  end)
end

local function test_close_policy_closes_on_overflow_and_the_consumer_drains()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 2, overflow = "close" })
    assert(queue:send(1) and queue:send(2))
    assert(not queue:closed())
    local ok, why = queue:send(3)
    assert(not ok and why == Channel.CLOSED and queue:closed())
    ok, why = queue:try_send(4)
    assert(not ok and why == Channel.CLOSED)
    assert(queue:receive() == 1 and queue:receive() == 2)
    local item, reason = queue:receive()
    assert(item == nil and reason == Channel.CLOSED)
    assert(queue:dropped() == 0)
  end)
end

local function test_a_waiting_receiver_is_woken_by_send()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local got: {integer} = {}
    local last: {string} = {}
    local task = consumer(queue, got, last)
    assert(Poll.delay(0))
    assert(#got == 0)
    assert(queue:send(7))
    assert(Poll.delay(0))
    assert(#got == 1 and got[1] == 7)
    queue:close()
    assert(task:join())
    assert(last[1] == Channel.CLOSED)
  end)
end

local function test_a_waiting_sender_is_woken_by_receive()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(1))
    local result: {string} = {}
    local sender = Poll.spawn(function()
      local ok, why = queue:send(2)
      result[#result + 1] = tostring(ok) .. ":" .. why
    end)
    assert(Poll.delay(0))
    assert(#result == 0 and queue:len() == 1)
    assert(queue:receive() == 1)
    assert(sender:join())
    assert(result[1] == "true:" and queue:len() == 1)
    assert(queue:receive() == 2)
  end)
end

local function test_receive_times_out_and_a_late_send_is_not_lost()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local item, why = queue:receive(Clock.ms(5))
    assert(item == nil and why == Poll.TIMEOUT)
    item, why = queue:receive(0)
    assert(item == nil and why == Poll.TIMEOUT)
    assert(queue:send(1))
    assert(queue:receive(0) == 1)
  end)
end

local function test_a_cancelled_waiter_answers_cancelled_and_loses_nothing()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    local reasons: {string} = {}
    local receiver = Poll.spawn(function()
      local _, why = queue:receive()
      reasons[#reasons + 1] = why
    end)
    local second_got: {integer} = {}
    local second_last: {string} = {}
    local second = consumer(queue, second_got, second_last)
    assert(Poll.delay(0))
    receiver:cancel()
    assert(receiver:join())
    assert(reasons[1] == Poll.CANCELLED)
    -- The item goes to the receiver still waiting.
    assert(queue:send(5))
    assert(Poll.delay(0))
    assert(#second_got == 1 and second_got[1] == 5)
    queue:close()
    assert(second:join())

    local full: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(full:send(1))
    local sender = Poll.spawn(function()
      local ok, why = full:send(2)
      reasons[#reasons + 1] = tostring(ok) .. ":" .. why
    end)
    assert(Poll.delay(0))
    sender:cancel()
    assert(sender:join())
    assert(reasons[2] == "false:" .. Poll.CANCELLED)
    assert(full:len() == 1 and full:receive() == 1)
  end)
end

local function test_a_receiver_that_loses_its_item_still_times_out_on_time()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local took = { value = 0 }
    local why = { value = "" }
    local receiver = Poll.spawn(function()
      local start = Clock.monotonic_ns()
      local item, reason = queue:receive(Clock.ms(100))
      assert(item == nil)
      why.value = reason
      took.value = Clock.monotonic_ns() - start
    end)
    assert(Poll.delay(Clock.ms(30)))
    -- The send notices the receiver; the item is gone before it runs.
    assert(queue:send(1))
    assert(queue:receive() == 1)
    assert(receiver:join())
    assert(why.value == Poll.TIMEOUT)
    -- A wait that began again with the whole timeout would end near 130 ms.
    assert(took.value >= Clock.ms(95) and took.value < Clock.ms(120), "took " .. took.value)
  end)
end

local function test_a_sender_that_loses_its_room_still_times_out_on_time()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(0))
    local took = { value = 0 }
    local why = { value = "" }
    local sender = Poll.spawn(function()
      local start = Clock.monotonic_ns()
      local ok, reason = queue:send(1, Clock.ms(100))
      assert(not ok)
      why.value = reason
      took.value = Clock.monotonic_ns() - start
    end)
    assert(Poll.delay(Clock.ms(30)))
    -- The receive notices the sender; the room is gone before it runs.
    assert(queue:receive() == 0)
    assert(queue:try_send(2))
    assert(sender:join())
    assert(why.value == Poll.TIMEOUT)
    assert(took.value >= Clock.ms(95) and took.value < Clock.ms(120), "took " .. took.value)
    assert(queue:len() == 1 and queue:receive() == 2)
  end)
end

local function test_a_killed_receiver_passes_the_item_to_the_next()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local got1: {integer} = {}
    local got2: {integer} = {}
    local last: {string} = {}
    local first = consumer(queue, got1, last)
    local second = consumer(queue, got2, last)
    assert(Poll.delay(0))
    -- The first waiter is noticed, then killed before it runs.
    assert(queue:send(9))
    first:kill()
    assert(second:join(Clock.ms(20)) == false)
    assert(#got1 == 0 and #got2 == 1 and got2[1] == 9)
    queue:close()
    assert(second:join())
  end)
end

local function test_a_killed_sender_passes_the_room_to_the_next()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(0))
    local sent: {integer} = {}
    local function sender(item: integer): Poll.Task
      return Poll.spawn(function()
        if queue:send(item) then sent[#sent + 1] = item end
      end)
    end
    local first = sender(1)
    local second = sender(2)
    assert(Poll.delay(0))
    assert(queue:receive() == 0)
    first:kill()
    assert(second:join())
    assert(#sent == 1 and sent[1] == 2)
    assert(queue:receive() == 2)
  end)
end

local function test_close_wakes_receivers_and_senders_and_drains_first()
  Poll.run(function()
    local idle: Channel.Queue<integer> = Channel.new()
    local reasons: {string} = {}
    local receivers: {Poll.Task} = {}
    for _ = 1, 3 do
      receivers[#receivers + 1] = Poll.spawn(function()
        local item, why = idle:receive()
        assert(item == nil)
        reasons[#reasons + 1] = why
      end)
    end
    local full: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(full:send(1))
    local senders: {Poll.Task} = {}
    for i = 1, 3 do
      senders[#senders + 1] = Poll.spawn(function()
        local ok, why = full:send(i + 1)
        assert(not ok)
        reasons[#reasons + 1] = why
      end)
    end
    assert(Poll.delay(0))
    idle:close()
    full:close()
    idle:close()
    for _, task in ipairs(receivers) do assert(task:join()) end
    for _, task in ipairs(senders) do assert(task:join()) end
    assert(#reasons == 6)
    for _, why in ipairs(reasons) do assert(why == Channel.CLOSED) end
    -- The queued item survives the close; then the queue is done.
    assert(full:closed() and full:len() == 1)
    assert(full:receive() == 1)
    local item, why = full:receive()
    assert(item == nil and why == Channel.CLOSED)
    local ok, reason = full:send(5)
    assert(not ok and reason == Channel.CLOSED)
  end)
end

local function test_close_from_a_close_handler_wakes_a_waiter()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local closing_mt: metatable<Closer> = { __close = function() queue:close() end }
    local got: {integer} = {}
    local last: {string} = {}
    local waiter = consumer(queue, got, last)
    assert(Poll.delay(0))
    local victim = Poll.spawn(function()
      local _ <close> = setmetatable({} as Closer, closing_mt)
      local _, _ = Poll.delay(Clock.seconds(30))
    end)
    assert(Poll.delay(0))
    victim:kill()
    assert(waiter:join(Clock.seconds(30)))
    assert(last[1] == Channel.CLOSED)
  end)
end

local function test_many_producers_and_consumers_lose_and_repeat_nothing()
  local producers, consumers, per = 5, 4, 40
  local seen: {integer: integer} = {}
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 3 })
    local makers: {Poll.Task} = {}
    for p = 1, producers do
      makers[#makers + 1] = Poll.spawn(function()
        for n = 1, per do
          assert(queue:send(p * 1000 + n))
          if n % 7 == 0 then assert(Poll.delay(0)) end
        end
      end)
    end
    local takers: {Poll.Task} = {}
    for _ = 1, consumers do
      takers[#takers + 1] = Poll.spawn(function()
        while true do
          local item = queue:receive()
          if item == nil then return end
          seen[item] = (seen[item] or 0) + 1
          local n = item % 1000
          if n % 5 == 0 then assert(Poll.delay(0)) end
        end
      end)
    end
    for _, task in ipairs(makers) do assert(task:join()) end
    queue:close()
    for _, task in ipairs(takers) do assert(task:join()) end
  end)
  for p = 1, producers do
    for n = 1, per do assert(seen[p * 1000 + n] == 1, "item " .. p * 1000 + n) end
  end
end

local function test_one_consumer_sees_each_producers_items_in_order()
  local got: {integer} = {}
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 2 })
    local last: {string} = {}
    local task = consumer(queue, got, last)
    local makers: {Poll.Task} = {}
    for p = 1, 3 do
      makers[#makers + 1] = Poll.spawn(function()
        for n = 1, 20 do assert(queue:send(p * 100 + n)) end
      end)
    end
    for _, maker in ipairs(makers) do assert(maker:join()) end
    queue:close()
    assert(task:join())
  end)
  assert(#got == 60)
  local at: {integer: integer} = {}
  for _, item in ipairs(got) do
    local p, n = item // 100, item % 100
    assert(n == (at[p] or 0) + 1, "producer " .. p .. " out of order at " .. n)
    at[p] = n
  end
end

local function test_a_queue_of_another_run_is_refused_when_it_waits()
  local stale = { value = nil as Channel.Queue<integer> | nil }
  Poll.run(function() stale.value = Channel.new() end)
  local other = assert(stale.value)
  Poll.run(function()
    raises(function() other:receive() end, "another run")
  end)
end
