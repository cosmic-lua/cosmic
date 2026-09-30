local _ = require("cosmic.child") -- in the closure: `raw_behind` searches for it by hand
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")

local type Searcher = function(string): any, any

--- The raw table `require` hands `wrapper`'s loader.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares

--- The two ends of a named pipe in `dir`, neither waiting: the reading
--- end open first, as a pipe with no reader refuses a nonblocking writer.
local function fifo(dir: string, name: string): integer, integer
  local path = dir .. "/" .. name
  assert(sys.mkfifo(path, 384))
  local reader = assert(sys.open(path, sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local writer = assert(sys.open(path, sys.O_WRONLY | sys.O_NONBLOCK, 0))
  return reader, writer
end

local function raises(fn: function(), words: string)
  local ok, err: boolean, any = pcall(fn)
  assert(not ok, "expected a raise naming " .. words)
  assert(tostring(err):find(words, 1, true), tostring(err))
end

local function test_tasks_take_turns_as_each_waits()
  local seen: {string} = {}
  Poll.run(function()
    local a = Poll.spawn(function()
      seen[#seen + 1] = "a1"
      assert(Poll.delay(0))
      seen[#seen + 1] = "a2"
    end)
    local b = Poll.spawn(function()
      seen[#seen + 1] = "b1"
      assert(Poll.delay(0))
      seen[#seen + 1] = "b2"
    end)
    seen[#seen + 1] = "main"
    assert(a:join())
    assert(b:join())
  end)
  assert(table.concat(seen, " ") == "main a1 b1 a2 b2", table.concat(seen, " "))
end

local function test_delays_end_in_the_order_of_their_times()
  local order: {integer} = {}
  Poll.run(function()
    for _, ms in ipairs({ 30, 10, 20 }) do
      Poll.spawn(function()
        assert(Poll.delay(ms))
        order[#order + 1] = ms
      end)
    end
  end)
  assert(table.concat(order, " ") == "10 20 30", table.concat(order, " "))
end

local function test_a_readable_wait_ends_when_data_arrives(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local got = ""
  Poll.run(function()
    local listener = Poll.spawn(function()
      assert(Poll.readable(reader, 5000))
      got = assert(sys.read(reader, 16))
    end)
    assert(Poll.delay(10))
    assert(got == "", "the reader went on before anything was written")
    assert(sys.write(writer, "hi") == 2)
    assert(listener:join())
  end)
  assert(got == "hi", got)
  sys.close(reader)
  sys.close(writer)
end

local function test_a_wait_past_its_timeout_answers_timeout(tmp: string)
  local reader, writer = fifo(tmp, "p")
  Poll.run(function()
    local ok, why = Poll.readable(reader, 20)
    assert(not ok and why == Poll.TIMEOUT, why)
    local sleeper = Poll.spawn(function() local _, _ = Poll.delay(1000) end)
    local joined, join_why = sleeper:join(10)
    assert(not joined and join_why == Poll.TIMEOUT, join_why)
    sleeper:cancel()
  end)
  sys.close(reader)
  sys.close(writer)
end

local function test_a_writable_wait_ends_at_once_where_there_is_room(tmp: string)
  local reader, writer = fifo(tmp, "p")
  Poll.run(function()
    assert(Poll.writable(writer, 0))
  end)
  sys.close(reader)
  sys.close(writer)
end

--- A cancelled task's wait, and every one after it, answers CANCELLED,
--- so the task unwinds on its own terms.
local function test_cancel_ends_a_wait_and_every_later_one(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local answers: {string} = {}
  Poll.run(function()
    local task = Poll.spawn(function()
      local _, why = Poll.readable(reader)
      answers[#answers + 1] = why
      local _, again = Poll.delay(0)
      answers[#answers + 1] = again
    end)
    assert(Poll.delay(0))
    task:cancel()
    assert(task:join())
  end)
  assert(answers[1] == Poll.CANCELLED and answers[2] == Poll.CANCELLED,
    table.concat(answers, ","))
  sys.close(reader)
  sys.close(writer)
end

local record Closer
  metamethod __close: function(Closer)
end

--- An error ends the run: the other tasks are closed where they wait,
--- their `<close>` variables with them, and `run` raises it; the next
--- `run` starts afresh.
local function test_an_error_ends_the_run_and_closes_the_rest()
  local closed = false
  local closer_mt: metatable<Closer> = { __close = function() closed = true end }
  local ok, err: boolean, any = pcall(Poll.run, function()
    Poll.spawn(function()
      local _ <close> = setmetatable({} as Closer, closer_mt)
      assert(Poll.delay(1000))
    end)
    assert(Poll.delay(0))
    error("broken", 0)
  end)
  assert(not ok and err == "broken", tostring(err))
  assert(closed, "the waiting task's <close> variable was not closed")
  local ran = false
  Poll.run(function() ran = true end)
  assert(ran, "a run after a raise did not run")
end

local function test_waiting_outside_a_task_raises()
  raises(function() Poll.delay(0) end, "outside Poll.run")
  raises(function() Poll.spawn(function() end) end, "outside Poll.run")
  Poll.run(function()
    raises(function() Poll.run(function() end) end, "already running")
    local inner = coroutine.wrap(function() Poll.delay(0) end)
    raises(inner, "outside a task's own coroutine")
    raises(function() Poll.delay(-1) end, "from 0")
  end)
end

local function test_tasks_waiting_only_on_each_other_raise()
  raises(function()
    Poll.run(function()
      local other: Poll.Task
      local first = Poll.spawn(function()
        assert(Poll.delay(0))
        assert(other:join())
      end)
      other = Poll.spawn(function() assert(first:join()) end)
      assert(first:join())
    end)
  end, "every task waits on another")
end

local function test_a_yield_of_its_own_raises()
  raises(function()
    Poll.run(function() coroutine.yield() end)
  end, "yielded other than through cosmic.poll")
end

--- Many tasks each wait on a descriptor of their own at once, and each
--- is woken for its own.
local function test_many_tasks_wait_on_descriptors_at_once(tmp: string)
  local count = 200
  local readers: {integer} = {}
  local writers: {integer} = {}
  for i = 1, count do readers[i], writers[i] = fifo(tmp, "p" .. i) end
  local got: {integer: string} = {}
  Poll.run(function()
    for i = 1, count do
      Poll.spawn(function()
        assert(Poll.readable(readers[i], 5000))
        got[i] = assert(sys.read(readers[i], 16))
      end)
    end
    assert(Poll.delay(0))
    for i = count, 1, -1 do assert(sys.write(writers[i], tostring(i)) > 0) end
  end)
  for i = 1, count do
    assert(got[i] == tostring(i), "task " .. i .. " read " .. tostring(got[i]))
    sys.close(readers[i])
    sys.close(writers[i])
  end
end

--- A wait answered one way is answered once: a readable wait with a
--- timeout, answered by data, leaves no timer to wake the task early
--- from its next wait.
local function test_a_wait_is_answered_once(tmp: string)
  local reader, writer = fifo(tmp, "p")
  assert(sys.write(writer, "x") == 1)
  local waited = 0
  Poll.run(function()
    assert(Poll.readable(reader, 30))
    local before = assert(sys.clock_gettime(sys.CLOCK_MONOTONIC))
    assert(Poll.delay(60))
    waited = (assert(sys.clock_gettime(sys.CLOCK_MONOTONIC)) - before) // 1000000
  end)
  assert(waited >= 59, "the delay ended after " .. waited .. " ms")
  sys.close(reader)
  sys.close(writer)
end

--- The peer gone, or the descriptor closed, ends a readable wait: the
--- read then says which. The hang-up is a pipe's: macOS's poll never
--- reports a named pipe's writer gone.
local function test_a_hang_up_or_a_closed_descriptor_ends_a_wait(tmp: string)
  local ends = assert(process.pipe())
  local reader, writer = ends.reader, ends.writer
  assert(sys.set_nonblocking(reader, true))
  local closed_reader, closed_writer = fifo(tmp, "q")
  sys.close(closed_reader)
  Poll.run(function()
    local task = Poll.spawn(function()
      assert(Poll.readable(reader, 5000))
      assert(sys.read(reader, 16) == "", "the end of what was sent")
    end)
    assert(Poll.delay(0))
    sys.close(writer)
    assert(task:join(5000))
    assert(Poll.readable(closed_reader, 5000))
  end)
  sys.close(reader)
  sys.close(closed_writer)
end

--- Two tasks waiting on one descriptor are both answered by it.
local function test_waits_sharing_a_descriptor_are_each_answered(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local woke = 0
  Poll.run(function()
    for _ = 1, 2 do
      Poll.spawn(function()
        assert(Poll.readable(reader, 5000))
        woke = woke + 1
      end)
    end
    assert(Poll.delay(0))
    assert(sys.write(writer, "x") == 1)
  end)
  assert(woke == 2, "woke " .. woke)
  sys.close(reader)
  sys.close(writer)
end

--- A spawned task's error ends the run as main's does.
local function test_a_spawned_task_error_ends_the_run()
  local ok, err: boolean, any = pcall(Poll.run, function()
    local failing = Poll.spawn(function() error("spawned broke", 0) end)
    assert(failing:join())
    error("main went on")
  end)
  assert(not ok and err == "spawned broke", tostring(err))
end

--- A cancel lands wherever the task is: not yet started, cancelling
--- itself, or after the run has ended.
local function test_cancel_before_a_start_or_of_itself_or_after_the_run()
  local answers: {string} = {}
  local kept: Poll.Task
  Poll.run(function()
    local early = Poll.spawn(function()
      local _, why = Poll.delay(1000)
      answers[#answers + 1] = why
    end)
    early:cancel()
    local selfish: Poll.Task
    selfish = Poll.spawn(function()
      selfish:cancel()
      local _, why = Poll.delay(1000)
      answers[#answers + 1] = why
    end)
    assert(early:join())
    assert(selfish:join())
    kept = selfish
  end)
  assert(answers[1] == Poll.CANCELLED and answers[2] == Poll.CANCELLED, table.concat(answers, ","))
  kept:cancel()
end

--- A cancelled task that waits in a loop still lets the others run.
local function test_a_cancelled_task_waiting_in_a_loop_lets_others_run()
  local spins = 0
  local spins_at_first = -1
  Poll.run(function()
    local spinner = Poll.spawn(function()
      for _ = 1, 100 do
        local _, _ = Poll.delay(1000)
        spins = spins + 1
      end
    end)
    Poll.spawn(function()
      assert(Poll.delay(0))
      spins_at_first = spins
    end)
    spinner:cancel()
  end)
  assert(spins == 100, "the spinner spun " .. spins .. " times")
  assert(spins_at_first >= 0 and spins_at_first < 100,
    "the delayed task ran only after " .. spins_at_first .. " spins")
end

--- A task that raises has its own `<close>` variables closed, as code
--- outside a task would.
local function test_a_raising_task_closes_its_own_close_variables()
  local closed = false
  local closer_mt: metatable<Closer> = { __close = function() closed = true end }
  raises(function()
    Poll.run(function()
      local _ <close> = setmetatable({} as Closer, closer_mt)
      error("broken", 0)
    end)
  end, "broken")
  assert(closed, "the raising task's <close> variable was not closed")
end

--- A run that raised, for any reason, leaves the next free to run, and
--- a handle kept from it answers as a task that has ended.
local function test_a_failed_run_leaves_the_next_free()
  local kept: Poll.Task
  raises(function()
    Poll.run(function()
      kept = Poll.spawn(function() local _, _ = Poll.delay(1000) end)
      assert(Poll.delay(0))
      error("broken", 0)
    end)
  end, "broken")
  raises(function()
    Poll.run(function()
      local other: Poll.Task
      local first = Poll.spawn(function()
        assert(Poll.delay(0))
        assert(other:join())
      end)
      other = Poll.spawn(function() assert(first:join()) end)
    end)
  end, "every task waits on another")
  Poll.run(function()
    kept:cancel()
    local joined, why = kept:join(0)
    assert(not joined and why == Poll.CANCELLED, why)
  end)
end

--- Timeouts are bounded by what poll takes; a join bounded by one is no
--- deadlock.
local function test_timeouts_are_bounded_and_timed_joins_are_no_deadlock()
  Poll.run(function()
    raises(function() Poll.delay(0x80000000) end, "from 0 to")
    raises(function() Poll.readable(0, math.maxinteger) end, "from 0 to")
    local a: Poll.Task
    local b = Poll.spawn(function() local _, _ = a:join(20) end)
    a = Poll.spawn(function() local _, _ = b:join(20) end)
  end)
end
