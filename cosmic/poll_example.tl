--- Worked examples for [`cosmic.poll`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local Clock = require("cosmic.clock")

local Example = {}

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
  local said: {string} = {}
  Poll.run(function()
    Poll.spawn(function()
      assert(Poll.delay(Clock.ms(20)))
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

--- A wait bounded by its timeout answers false and [`Poll.TIMEOUT`] when
--- nothing comes in time.
function Example.readable()
  local dir = assert(Fs.mkdtemp("cosmic-poll-example-"))
  local reader, writer = pipe(dir)
  Poll.run(function()
    local ok, why = Poll.readable(reader, Clock.ms(10))
    print(ok, why)
    assert(not ok and why == Poll.TIMEOUT)
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
  local woke: {integer} = {}
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

--- A cancelled task's wait answers [`Poll.CANCELLED`], and it unwinds on
--- its own terms.
function Example.cancel()
  local answer = ""
  Poll.run(function()
    local sleeper = Poll.spawn(function()
      local _, why = Poll.delay(Clock.seconds(60))
      answer = why
    end)
    assert(Poll.delay(0))
    sleeper:cancel()
    assert(sleeper:join())
  end)
  print(answer)
  assert(answer == Poll.CANCELLED)
end

--- A task that waits on whatever its waits answer outlasts `cancel`,
--- and is ended by `kill` where it waits: its `<close>` variables are
--- closed, and a join answers [`Poll.CANCELLED`].
function Example.kill()
  local released = false
  local record Lease
    metamethod __close: function(Lease)
  end
  local lease_mt: metatable<Lease> = { __close = function() released = true end }
  Poll.run(function()
    local stubborn = Poll.spawn(function()
      local _ <close> = setmetatable({} as Lease, lease_mt)
      while true do local _, _ = Poll.delay(Clock.seconds(60)) end
    end)
    assert(Poll.delay(0))
    stubborn:cancel()
    local _, still = stubborn:join(Clock.ms(10))
    assert(still == Poll.TIMEOUT)
    stubborn:kill()
    local ended, why = stubborn:join()
    print(released, ended, why)
    assert(released and not ended and why == Poll.CANCELLED)
  end)
end

return Example
