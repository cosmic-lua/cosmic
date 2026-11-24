--- Worked examples for [`cosmic.poll`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Clock = require("cosmic.clock")
local Defer = require("cosmic.defer")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")

local Example = {} -- checked: literal_needs_type

--- A named pipe's two ends, neither waiting: what the examples below
--- wait on.
local function pipe(dir: string): integer, integer
  assert(sys.mkfifo(dir .. "/pipe", 384))
  local reader = assert(sys.open(dir .. "/pipe", sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local writer = assert(sys.open(dir .. "/pipe", sys.O_WRONLY | sys.O_NONBLOCK, 0))
  return reader, writer
end

--- Two tasks, each running until it waits: the first sleeps while the
--- second runs, and `run` returns once both have ended.
function Example.run()
  local said: mut {string} = {}
  Poll.run(function()
    Poll.spawn(function()
      assert(Clock.sleep(Clock.ms(20)))
      said[#said + 1] = "later"
    end)
    said[#said + 1] = "first"
  end)
  print(table.concat(said, ", "))
  assert(table.concat(said, ", ") == "first, later")
end

--- A task waits for what another sends, and the first waits for it to
--- end with `join`.
function Example.spawn()
  local dir = assert(Fs.mkdtemp("cosmic-poll-example-"))
  local reader, writer = pipe(dir)
  Poll.run(function()
    local listener = Poll.spawn(function()
      assert(Poll.readable(reader, Clock.seconds(5)))
      print(sys.read(reader, 64))
    end)
    assert(sys.write(writer, "hello") == 5)
    assert(listener:join(Clock.seconds(5)))
  end)
  sys.close(reader)
  sys.close(writer)
  assert(Fs.remove_tree(dir))
end

--- A wait bounded by its timeout answers false and a Failure of kind
--- "timeout" when nothing comes in time.
function Example.readable()
  local dir = assert(Fs.mkdtemp("cosmic-poll-example-"))
  local reader, writer = pipe(dir)
  Poll.run(function()
    local ok, why = Poll.readable(reader, Clock.ms(10))
    print(ok, why)
    assert(not ok and why.kind == "timeout")
  end)
  sys.close(reader)
  sys.close(writer)
  assert(Fs.remove_tree(dir))
end

--- A pipe with room takes a write without waiting.
function Example.writable()
  local dir = assert(Fs.mkdtemp("cosmic-poll-example-"))
  local reader, writer = pipe(dir)
  Poll.run(function()
    assert(Poll.writable(writer, Clock.seconds(1)))
    assert(sys.write(writer, "x") == 1)
  end)
  sys.close(reader)
  sys.close(writer)
  assert(Fs.remove_tree(dir))
end

--- Sleeping tasks wake in the order of their times, not their starts.
function Example.delay()
  local woke: mut {integer} = {}
  Poll.run(function()
    for _, ms in ipairs({ 20, 5 }) do
      Poll.spawn(function()
        assert(Poll.delay(Clock.ms(ms)))
        woke[#woke + 1] = ms
      end)
    end
  end)
  print(woke[1], woke[2])
  assert(woke[1] == 5 and woke[2] == 20)
end

--- A cancelled task's wait answers a Failure of kind "cancelled", and it
--- unwinds on its own terms.
function Example.cancel()
  local waited: mut {string: string} = { answer = "" }
  Poll.run(function()
    local sleeper = Poll.spawn(function()
      local _, why = Clock.sleep(Clock.seconds(60))
      waited["answer"] = if why ~= nil then why.kind else "" end
    end)
    assert(Clock.sleep(0))
    sleeper:cancel()
    assert(sleeper:join())
  end)
  print(waited["answer"])
  assert(waited["answer"] == "cancelled")
end

--- A task that waits on whatever its waits answer outlasts `cancel`,
--- and is ended by `kill` where it waits: its `<close>` variables are
--- closed, and a join answers a Failure of kind "cancelled".
function Example.kill()
  local released = false
  Poll.run(function()
    local stubborn = Poll.spawn(function()
      local _ <close> = Defer.new(function() released = true end)
      while true do local _, _ = Clock.sleep(Clock.seconds(60)) end
    end)
    assert(Clock.sleep(0))
    stubborn:cancel()
    local _, still = stubborn:join(Clock.ms(10))
    assert(still ~= nil and still.kind == "timeout")
    stubborn:kill()
    local ended, why = stubborn:join()
    print(released, ended, why)
    assert(released and not ended and why.kind == "cancelled")
  end)
end

--- A producer queues work and notifies; the consumer checks its queue,
--- waits only when it is empty, and checks again on waking, so a notice
--- sent while it was busy is not lost.
function Example.notifier()
  local queue: mut {string} = {}
  local handled: mut {string} = {}
  Poll.run(function()
    local notifier = Poll.notifier()
    local consumer = Poll.spawn(function()
      while #handled < 3 do
        while #queue == 0 do
          local woken, _ = notifier:wait(Clock.seconds(5))
          if not woken then return end
        end
        table.insert(handled, assert(table.remove(queue, 1)))
      end
    end)
    for _, job in ipairs({ "a", "b", "c" }) do
      queue[#queue + 1] = job
      notifier:notify_one()
      assert(Clock.sleep(0))
    end
    assert(consumer:join(Clock.seconds(5)))
  end)
  print(table.concat(handled, ", "))
  assert(table.concat(handled, ", ") == "a, b, c")
end

return Example -- checked: export_not_declared
