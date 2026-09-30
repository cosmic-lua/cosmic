--- Worked examples for [`cosmic.poll`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")

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
      assert(Poll.delay(20))
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
      assert(Poll.readable(reader, 5000))
      print(sys.read(reader, 64))
    end)
    assert(sys.write(writer, "hello") == 5)
    assert(listener:join(5000))
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
    local ok, why = Poll.readable(reader, 10)
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
    assert(Poll.writable(writer, 1000))
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
        assert(Poll.delay(ms))
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
      local _, why = Poll.delay(60000)
      answer = why
    end)
    assert(Poll.delay(0))
    sleeper:cancel()
    assert(sleeper:join())
  end)
  print(answer)
  assert(answer == Poll.CANCELLED)
end

return Example
