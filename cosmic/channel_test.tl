local Channel = require("cosmic.channel")
local Clock = require("cosmic.clock")
local Defer = require("cosmic.defer")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local type Failure = require("cosmic.failure")

--- A receive's or a send's result in words: the item or true, "closed"
--- for false, or the Failure's message.
local function said(value?: integer | boolean, why?: Failure): string
  if why ~= nil then return why.message end
  if value == false then return "closed" end
  return tostring(value)
end

--- What a receive from `queue` returned, in words.
local function took(queue: Channel.Queue<integer>, timeout_ns?: integer): string
  local item, why = queue:receive(timeout_ns)
  return said(item, why)
end

--- What a send of `item` to `queue` returned, in words.
local function gave(queue: Channel.Queue<integer>, item: integer, timeout_ns?: integer): string
  local ok, why = queue:send(item, timeout_ns)
  return said(ok, why)
end

--- What a try_send of `item` to `queue` returned, in words.
local function tried(queue: Channel.Queue<integer>, item: integer): string
  local ok, why = queue:try_send(item)
  return said(ok, why)
end

--- A task that receives until the queue is closed or a failure, appending
--- what it gets to `into` and how it ended to `last` ("closed", or the
--- Failure's message).
local function consumer(queue: Channel.Queue<integer>, into: mut {integer}, last: mut {string},
                        timeout_ns?: integer): Poll.Task
  return Poll.spawn(function()
    while true do
      local item, why = queue:receive(timeout_ns)
      if item == nil or item == false then
        local ended = said(item, why)
        last[#last + 1] = ended
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
      assert(item == i and why == nil)
    end
    assert(queue:len() == 0)
    -- The ring wraps: more passes through than the capacity.
    for i = 1, 10 do
      assert(queue:send(i))
      assert(took(queue) == tostring(i))
    end
  end)
end

local function test_options_are_checked_and_default_to_a_large_blocking_queue()
  Poll.run(function()
    Test.raises(function() Channel.new({ capacity = 0 }) end, "capacity") -- checked: cannot_infer
    local queue: Channel.Queue<integer> = Channel.new()
    for i = 1, 256 do assert(queue:try_send(i)) end
    assert(tried(queue, 257) == Channel.FULL)
    Test.raises(function() local _, _ = queue:send(nil as integer) end, "nil") -- checked: cast_refused
    Test.raises(function() local _, _ = queue:receive(-1) end, "timeout_ns")
    -- A false item would read as what a receive from a closed queue returns.
    local flags: Channel.Queue<boolean> = Channel.new()
    Test.raises(function() local _, _ = flags:send(false) end, "send of false")
    Test.raises(function() local _, _ = flags:try_send(false) end, "send of false")
  end)
  Test.raises(function() Channel.new() end, "outside Poll.run") -- checked: cannot_infer
end

local function test_block_makes_try_send_fail_and_send_time_out_when_full()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(1))
    assert(tried(queue, 2) == Channel.FULL)
    local _, full = queue:try_send(2)
    assert(full ~= nil and full.kind == "other")
    assert(gave(queue, 2, Clock.ms(5)) == Poll.TIMEOUT)
    local _, late = queue:send(2, 0)
    assert(late ~= nil and late.kind == "timeout")
    assert(queue:len() == 1 and queue:dropped() == 0)
    assert(took(queue) == "1")
  end)
end

local function test_drop_oldest_keeps_the_newest_and_counts_the_drops()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 3, overflow = "drop_oldest" })
    for i = 1, 7 do assert(queue:send(i)) end
    assert(queue:dropped() == 4 and queue:len() == 3)
    local got: mut {string} = {}
    for _ = 1, 3 do
      local item = took(queue)
      got[#got + 1] = item
    end
    assert(table.concat(got, ",") == "5,6,7")
    assert(queue:try_send(8))
    assert(took(queue) == "8")
  end)
end

local function test_drop_newest_keeps_the_oldest_and_counts_the_drops()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 3, overflow = "drop_newest" })
    for i = 1, 7 do assert(queue:send(i)) end
    assert(queue:dropped() == 4 and queue:len() == 3)
    local got: mut {string} = {}
    for _ = 1, 3 do
      local item = took(queue)
      got[#got + 1] = item
    end
    assert(table.concat(got, ",") == "1,2,3")
  end)
end

local function test_close_policy_closes_on_overflow_and_the_consumer_drains()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 2, overflow = "close" })
    assert(queue:send(1))
    assert(queue:send(2))
    assert(not queue:closed())
    assert(gave(queue, 3) == "closed" and queue:closed())
    assert(tried(queue, 4) == "closed")
    assert(took(queue) == "1" and took(queue) == "2")
    local item, why = queue:receive()
    assert(item == false and why == nil)
    assert(queue:dropped() == 0)
  end)
end

local function test_a_waiting_receiver_is_woken_by_send()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local got: mut {integer} = {}
    local last: mut {string} = {}
    local task = consumer(queue, got, last)
    assert(Clock.sleep(0))
    assert(#got == 0)
    assert(queue:send(7))
    assert(Clock.sleep(0))
    assert(#got == 1 and got[1] == 7)
    queue:close()
    assert(task:join())
    assert(last[1] == "closed")
  end)
end

local function test_a_waiting_sender_is_woken_by_receive()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(1))
    local result: mut {string} = {}
    local sender = Poll.spawn(function()
      table.insert(result, gave(queue, 2))
    end)
    assert(Clock.sleep(0))
    assert(#result == 0 and queue:len() == 1)
    assert(took(queue) == "1")
    assert(sender:join())
    assert(result[1] == "true" and queue:len() == 1)
    assert(took(queue) == "2")
  end)
end

local function test_receive_times_out_and_a_late_send_is_not_lost()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    assert(took(queue, Clock.ms(5)) == Poll.TIMEOUT)
    local _, why = queue:receive(0)
    assert(why ~= nil and why.kind == "timeout")
    assert(queue:send(1))
    assert(took(queue, 0) == "1")
  end)
end

local function test_a_cancelled_waiter_answers_cancelled_and_loses_nothing()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    local reasons: mut {string} = {}
    local receiver = Poll.spawn(function()
      local _, why = queue:receive()
      assert(why ~= nil and why.kind == "cancelled")
      local ended = said(nil, why)
      reasons[#reasons + 1] = ended
    end)
    local second_got: mut {integer} = {}
    local second_last: mut {string} = {}
    local second = consumer(queue, second_got, second_last)
    assert(Clock.sleep(0))
    receiver:cancel()
    assert(receiver:join())
    assert(reasons[1] == Poll.CANCELLED)
    -- The item goes to the receiver still waiting.
    assert(queue:send(5))
    assert(Clock.sleep(0))
    assert(#second_got == 1 and second_got[1] == 5)
    queue:close()
    assert(second:join())

    local full: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(full:send(1))
    local sender = Poll.spawn(function()
      table.insert(reasons, gave(full, 2))
    end)
    assert(Clock.sleep(0))
    sender:cancel()
    assert(sender:join())
    assert(reasons[2] == Poll.CANCELLED)
    assert(full:len() == 1 and took(full) == "1")
  end)
end

local function test_a_receiver_that_loses_its_item_still_times_out_on_time()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local elapsed: integer = 0
    local why: string = ""
    local receiver = Poll.spawn(function()
      local start = Clock.monotonic_ns()
      why = took(queue, Clock.ms(100))
      elapsed = Clock.monotonic_ns() - start
    end)
    -- Late enough that a wait begun again would end near 150 ms or later.
    assert(Clock.sleep(Clock.ms(50)))
    -- The send notices the receiver; the item is gone before it runs.
    assert(queue:send(1))
    assert(took(queue) == "1")
    assert(receiver:join())
    assert(why == Poll.TIMEOUT)
    assert(elapsed >= Clock.ms(95) and elapsed < Clock.ms(140), "took " .. tostring(elapsed))
  end)
end

local function test_a_sender_that_loses_its_room_still_times_out_on_time()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(0))
    local elapsed: integer = 0
    local why: string = ""
    local sender = Poll.spawn(function()
      local start = Clock.monotonic_ns()
      why = gave(queue, 1, Clock.ms(100))
      elapsed = Clock.monotonic_ns() - start
    end)
    -- Late enough that a wait begun again would end near 150 ms or later.
    assert(Clock.sleep(Clock.ms(50)))
    -- The receive notices the sender; the room is gone before it runs.
    assert(took(queue) == "0")
    assert(queue:try_send(2))
    assert(sender:join())
    assert(why == Poll.TIMEOUT)
    assert(elapsed >= Clock.ms(95) and elapsed < Clock.ms(140), "took " .. tostring(elapsed))
    assert(queue:len() == 1 and took(queue) == "2")
  end)
end

local function test_a_killed_receiver_passes_the_item_to_the_next()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local got1: mut {integer} = {}
    local got2: mut {integer} = {}
    local last: mut {string} = {}
    local first = consumer(queue, got1, last)
    local second = consumer(queue, got2, last)
    assert(Clock.sleep(0))
    -- The first waiter is noticed, then killed before it runs.
    assert(queue:send(9))
    first:kill()
    local joined, _ = second:join(Clock.ms(20))
    assert(joined == nil)
    assert(#got1 == 0 and #got2 == 1 and got2[1] == 9)
    queue:close()
    assert(second:join())
  end)
end

local function test_a_killed_sender_passes_the_room_to_the_next()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(queue:send(0))
    local sent: mut {integer} = {}
    local function sender(item: integer): Poll.Task
      return Poll.spawn(function()
        if gave(queue, item) == "true" then sent[#sent + 1] = item end
      end)
    end
    local first = sender(1)
    local second = sender(2)
    assert(Clock.sleep(0))
    assert(took(queue) == "0")
    first:kill()
    assert(second:join())
    assert(#sent == 1 and sent[1] == 2)
    assert(took(queue) == "2")
  end)
end

local function test_close_wakes_receivers_and_senders_and_drains_first()
  Poll.run(function()
    local idle: Channel.Queue<integer> = Channel.new()
    local reasons: mut {string} = {}
    local receivers: mut {Poll.Task} = {}
    for _ = 1, 3 do
      receivers[#receivers + 1] = Poll.spawn(function()
        local ended = took(idle)
        reasons[#reasons + 1] = ended
      end)
    end
    local full: Channel.Queue<integer> = Channel.new({ capacity = 1 })
    assert(full:send(1))
    local senders: mut {Poll.Task} = {}
    for i = 1, 3 do
      senders[#senders + 1] = Poll.spawn(function()
        local ended = gave(full, i + 1)
        reasons[#reasons + 1] = ended
      end)
    end
    assert(Clock.sleep(0))
    idle:close()
    full:close()
    idle:close()
    for _, task in ipairs(receivers) do assert(task:join()) end
    for _, task in ipairs(senders) do assert(task:join()) end
    assert(#reasons == 6)
    for _, ended in ipairs(reasons) do assert(ended == "closed") end
    -- The queued item survives the close; then the queue is done.
    assert(full:closed() and full:len() == 1)
    assert(took(full) == "1")
    assert(took(full) == "closed")
    assert(gave(full, 5) == "closed")
  end)
end

local function test_close_from_a_close_handler_wakes_a_waiter()
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new()
    local closing = function() queue:close() end
    local got: mut {integer} = {}
    local last: mut {string} = {}
    local waiter = consumer(queue, got, last)
    assert(Clock.sleep(0))
    local victim = Poll.spawn(function()
      local _ <close> = Defer.new(closing)
      local _, _ = Clock.sleep(Clock.seconds(30))
    end)
    assert(Clock.sleep(0))
    victim:kill()
    assert(waiter:join(Clock.seconds(30)))
    assert(last[1] == "closed")
  end)
end

local function test_many_producers_and_consumers_lose_and_repeat_nothing()
  local producers, consumers, per = 5, 4, 40
  local seen: mut {integer: integer} = {}
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 3 })
    local makers: mut {Poll.Task} = {}
    for p = 1, producers do
      makers[#makers + 1] = Poll.spawn(function()
        for n = 1, per do
          assert(queue:send(p * 1000 + n))
          if n % 7 == 0 then assert(Clock.sleep(0)) end
        end
      end)
    end
    local takers: mut {Poll.Task} = {}
    for _ = 1, consumers do
      takers[#takers + 1] = Poll.spawn(function()
        while true do
          local item, why = queue:receive()
          if item == nil then error(why) end
          if item == false then return end
          seen[item] = (seen[item] or 0) + 1
          local n = item % 1000
          if n % 5 == 0 then assert(Clock.sleep(0)) end
        end
      end)
    end
    for _, task in ipairs(makers) do assert(task:join()) end
    queue:close()
    for _, task in ipairs(takers) do assert(task:join()) end
  end)
  for p = 1, producers do
    for n = 1, per do assert(seen[p * 1000 + n] == 1, "item " .. tostring(p * 1000 + n)) end
  end
end

local function test_one_consumer_sees_each_producers_items_in_order()
  local got: mut {integer} = {}
  Poll.run(function()
    local queue: Channel.Queue<integer> = Channel.new({ capacity = 2 })
    local last: mut {string} = {}
    local task = consumer(queue, got, last)
    local makers: mut {Poll.Task} = {}
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
  local at: mut {integer: integer} = {}
  for _, item in ipairs(got) do
    local p, n = item // 100, item % 100
    assert(n == (at[p] or 0) + 1, "producer " .. tostring(p) .. " out of order at " .. tostring(n))
    at[p] = n
  end
end

local function test_a_queue_of_another_run_is_refused_when_it_waits()
  local stale: Channel.Queue<integer>? = nil
  Poll.run(function() stale = Channel.new() end)
  local other = assert(stale)
  Poll.run(function()
    Test.raises(function() local _, _ = other:receive() end, "another run")
  end)
end
