local _ = require("cosmic.child") -- in the closure: [`raw_behind`] searches for it by hand
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")
local Clock = require("cosmic.clock")

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

local function test_milliseconds_round_a_timeout_up_and_no_limit_is_minus_one()
  assert(Poll.milliseconds(nil) == -1)
  assert(Poll.milliseconds(0) == 0)
  assert(Poll.milliseconds(1) == 1)
  assert(Poll.milliseconds(Clock.ms(3)) == 3)
  assert(Poll.milliseconds(Clock.ms(3) + 1) == 4)
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

--- Each delay is armed from its own reading of the clock, so the times
--- lie far enough apart that a host stalling less than 50 ms in all
--- while it arms them still sees them end in order.
local function test_delays_end_in_the_order_of_their_times()
  local order: {integer} = {}
  Poll.run(function()
    for _, ms in ipairs({ 150, 50, 100 }) do
      Poll.spawn(function()
        assert(Poll.delay(Clock.ms(ms)))
        order[#order + 1] = ms
      end)
    end
  end)
  assert(table.concat(order, " ") == "50 100 150", table.concat(order, " "))
end

local function test_a_readable_wait_ends_when_data_arrives(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local got = ""
  Poll.run(function()
    local listener = Poll.spawn(function()
      assert(Poll.readable(reader, Clock.seconds(5)))
      got = assert(sys.read(reader, 16))
    end)
    assert(Poll.delay(Clock.ms(10)))
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
    local ok, why = Poll.readable(reader, Clock.ms(20))
    assert(not ok and why == Poll.TIMEOUT, why)
    local sleeper = Poll.spawn(function() local _, _ = Poll.delay(Clock.seconds(1)) end)
    local joined, join_why = sleeper:join(Clock.ms(10))
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
      assert(Poll.delay(Clock.seconds(1)))
    end)
    assert(Poll.delay(0))
    error("broken", 0)
  end)
  assert(not ok and tostring(err):find("broken\nstack traceback:", 1, true) == 1, tostring(err))
  assert(closed, "the waiting task's <close> variable was not closed")
  local ran = false
  Poll.run(function() ran = true end)
  assert(ran, "a run after a raise did not run")
end

--- A raise names its module, however the call was wrong.
local function test_a_raise_names_the_module()
  local raising: {function()} = {
    function() Poll.delay(0) end,
    function() Poll.spawn(function() end) end,
    function() Poll.run(nil as function()) end,
    function() Poll.shielded(nil as function()) end,
    function() Poll.checked_ns(-1, "poll", "span", 1) end,
    function() local _, _ = Poll.ready({ 0 }, { sys.POLLIN }) end,
  }
  for i, call in ipairs(raising) do
    local ok, err: boolean, any = pcall(call)
    assert(not ok and tostring(err):find(": poll: ", 1, true) ~= nil, i .. ": " .. tostring(err))
  end
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

--- A wait on one descriptor goes on where there is no task to wait in --
--- outside a run, in a coroutine of its own -- holding the thread for
--- as long as it would have waited, and answers as a task's does.
local function test_a_wait_outside_a_task_holds_the_thread(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local function outside()
    local began = Clock.monotonic_ns()
    local ok, why = Poll.wait(reader, sys.POLLIN, Clock.ms(40))
    assert(not ok and why == Poll.TIMEOUT, why)
    ok, why = Poll.readable(reader, Clock.ms(40))
    assert(not ok and why == Poll.TIMEOUT, why)
    assert(Clock.monotonic_ns() - began >= Clock.ms(79), "a wait returned early")
    ok, why = Poll.writable(writer, Clock.ms(40))
    assert(ok and why == "", why)
  end
  outside()
  Poll.run(function()
    coroutine.wrap(outside)()
  end)
  sys.close(reader)
  sys.close(writer)
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
        assert(Poll.readable(readers[i], Clock.seconds(5)))
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
    assert(Poll.readable(reader, Clock.ms(30)))
    local before = Clock.monotonic_ns()
    assert(Poll.delay(Clock.ms(60)))
    waited = Clock.monotonic_ns() - before
  end)
  assert(waited >= Clock.ms(59), "the delay ended after " .. waited // Clock.ms(1) .. " ms")
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
      assert(Poll.readable(reader, Clock.seconds(5)))
      assert(sys.read(reader, 16) == "", "the end of what was sent")
    end)
    assert(Poll.delay(0))
    sys.close(writer)
    assert(task:join(Clock.seconds(5)))
    assert(Poll.readable(closed_reader, Clock.seconds(5)))
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
        assert(Poll.readable(reader, Clock.seconds(5)))
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
  assert(not ok and tostring(err):find("spawned broke\nstack traceback:", 1, true) == 1,
    tostring(err))
end

--- A cancel lands wherever the task is: not yet started, cancelling
--- itself, or after the run has ended.
local function test_cancel_before_a_start_or_of_itself_or_after_the_run()
  local answers: {string} = {}
  local kept: Poll.Task
  Poll.run(function()
    local early = Poll.spawn(function()
      local _, why = Poll.delay(Clock.seconds(1))
      answers[#answers + 1] = why
    end)
    early:cancel()
    local selfish: Poll.Task
    selfish = Poll.spawn(function()
      selfish:cancel()
      local _, why = Poll.delay(Clock.seconds(1))
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
        local _, _ = Poll.delay(Clock.seconds(1))
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
      kept = Poll.spawn(function() local _, _ = Poll.delay(Clock.seconds(1)) end)
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
    raises(function() Poll.delay(Poll.MOST_NS + 1) end, "from 0 to")
    raises(function() Poll.readable(0, math.maxinteger) end, "from 0 to")
    local a: Poll.Task
    local b = Poll.spawn(function() local _, _ = a:join(Clock.ms(20)) end)
    a = Poll.spawn(function() local _, _ = b:join(Clock.ms(20)) end)
  end)
end

--- `in_task` answers whether the caller is a task of a running run.
local function test_in_task_answers_only_in_a_task()
  assert(not Poll.in_task(), "outside a run")
  local inside, nested = false, true
  Poll.run(function()
    inside = Poll.in_task()
    nested = coroutine.wrap(function(): boolean return Poll.in_task() end)()
  end)
  assert(inside and not nested, tostring(inside) .. " " .. tostring(nested))
end

--- `closing` answers the waits on a descriptor about to be closed.
local function test_closing_answers_the_waits_on_a_descriptor(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local answered = false
  Poll.run(function()
    local waiter = Poll.spawn(function()
      answered = Poll.readable(reader, Clock.seconds(5))
    end)
    assert(Poll.delay(0))
    Poll.closing(reader)
    assert(waiter:join(Clock.seconds(1)))
  end)
  assert(answered, "the wait was not answered")
  Poll.closing(reader)
  sys.close(reader)
  sys.close(writer)
end

--- A killed task is ended where it waits and never resumed: its
--- `<close>` variables are closed, its joiners answer CANCELLED, and
--- neither its descriptor turning ready nor its timeout passing wakes
--- it after.
local function test_kill_ends_a_parked_task_and_its_waits(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local closed, resumed = false, false
  local joined_ok, joined_why: boolean, string
  local closer_mt: metatable<Closer> = { __close = function() closed = true end }
  Poll.run(function()
    local sleeper = Poll.spawn(function()
      local _ <close> = setmetatable({} as Closer, closer_mt)
      local _, _ = Poll.readable(reader, Clock.ms(20))
      resumed = true
    end)
    local joiner = Poll.spawn(function() joined_ok, joined_why = sleeper:join() end)
    assert(Poll.delay(0))
    sleeper:kill()
    assert(closed, "the killed task's <close> variable was not closed")
    assert(sys.write(writer, "x") == 1)
    assert(Poll.delay(Clock.ms(50)))
    assert(joiner:join())
    local ok, why = sleeper:join()
    assert(not ok and why == Poll.CANCELLED, why)
  end)
  assert(not resumed, "a killed task was resumed")
  assert(not joined_ok and joined_why == Poll.CANCELLED, joined_why)
  sys.close(reader)
  sys.close(writer)
end

--- A task killed while it waits to be resumed -- not yet started, or
--- answered but not yet run, whether in the ready queue or in the batch
--- the run is resuming -- never runs again.
local function test_kill_takes_a_ready_task_from_the_queue()
  local ran: {string} = {}
  Poll.run(function()
    local unstarted = Poll.spawn(function() ran[#ran + 1] = "unstarted" end)
    unstarted:kill()
    local answered = Poll.spawn(function()
      local _, _ = Poll.delay(Clock.seconds(1))
      ran[#ran + 1] = "answered"
    end)
    assert(Poll.delay(0))
    answered:cancel()
    answered:kill()
    local later: Poll.Task
    Poll.spawn(function() later:kill() end)
    later = Poll.spawn(function() ran[#ran + 1] = "later" end)
  end)
  assert(#ran == 0, table.concat(ran, ","))
end

--- Killing a task that has ended, or one kept past its run, does
--- nothing; a task killing itself raises.
local function test_kill_of_an_ended_task_or_of_itself()
  local kept: Poll.Task
  Poll.run(function()
    local done = Poll.spawn(function() end)
    assert(done:join())
    done:kill()
    assert(done:join())
    local selfish: Poll.Task
    selfish = Poll.spawn(function()
      raises(function() selfish:kill() end, "cannot kill itself")
    end)
    assert(selfish:join())
    kept = selfish
  end)
  kept:kill()
end

--- What a `<close>` handler raises as its task is killed, `kill` raises,
--- the task ended and its other `<close>` variables closed all the same;
--- uncaught, it ends the run. A handler there cannot wait, though it
--- is in a task, so a module that waits raises rather than hold the
--- thread.
local function test_kill_raises_what_a_close_handler_raises()
  local closed = false
  local wait_trouble = ""
  local in_task = false
  local closer_mt: metatable<Closer> = { __close = function() closed = true end }
  local raiser_mt: metatable<Closer> = { __close = function()
    local _, err: boolean, any = pcall(Poll.delay, 0)
    wait_trouble = tostring(err)
    local _, trouble: boolean, any = pcall(Poll.readable, 0, 0)
    assert(tostring(trouble):find("while its task is killed", 1, true), tostring(trouble))
    in_task = Poll.in_task()
    error("broken close", 0)
  end }
  Poll.run(function()
    local task = Poll.spawn(function()
      local _ <close> = setmetatable({} as Closer, closer_mt)
      local _ <close> = setmetatable({} as Closer, raiser_mt)
      local _, _ = Poll.delay(Clock.seconds(1))
    end)
    assert(Poll.delay(0))
    local killed, err: boolean, any = pcall(task.kill, task)
    assert(not killed and err == "broken close", tostring(err))
    local ok, why = task:join()
    assert(not ok and why == Poll.CANCELLED, why)
  end)
  assert(closed, "a <close> variable after the raising one was not closed")
  assert(wait_trouble:find("while its task is killed", 1, true), wait_trouble)
  assert(in_task, "in_task answered false for a task being killed")
  raises(function()
    Poll.run(function()
      local task = Poll.spawn(function()
        local _ <close> = setmetatable({} as Closer, raiser_mt)
        local _, _ = Poll.delay(Clock.seconds(1))
      end)
      assert(Poll.delay(0))
      task:kill()
    end)
  end, "broken close")
end

--- A wait on several descriptors answers what each had, by place, once
--- one is ready: here the second, while the first has nothing to read.
local function test_a_ready_wait_answers_each_descriptor_s_events(tmp: string)
  local quiet, quiet_writer = fifo(tmp, "q")
  local reader, writer = fifo(tmp, "p")
  local answers: {integer}
  Poll.run(function()
    local listener = Poll.spawn(function()
      answers = assert(Poll.ready({ quiet, reader }, { sys.POLLIN, sys.POLLIN }, Clock.seconds(5)))
    end)
    assert(Poll.delay(Clock.ms(10)))
    assert(answers == nil, "the wait ended before anything was written")
    assert(sys.write(writer, "hi") == 2)
    assert(listener:join())
  end)
  assert(answers[1] == 0 and answers[2] & sys.POLLIN ~= 0,
    tostring(answers[1]) .. " " .. tostring(answers[2]))
  for _, fd in ipairs({ quiet, quiet_writer, reader, writer }) do sys.close(fd) end
end

--- Past its timeout a ready wait answers nil and TIMEOUT, as a readable
--- wait fails; cancelled, it answers nil and CANCELLED; and a descriptor
--- about to close answers POLLNVAL.
local function test_a_ready_wait_times_out_is_cancelled_and_is_closed(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local timed, cancelled, closed: string, string, {integer}
  Poll.run(function()
    local expired, expiry = Poll.ready({ reader }, { sys.POLLIN }, Clock.ms(20))
    assert(expired == nil)
    timed = expiry
    local waiter = Poll.spawn(function()
      local answers, why = Poll.ready({ reader }, { sys.POLLIN })
      assert(answers == nil)
      cancelled = why
    end)
    assert(Poll.delay(0))
    waiter:cancel()
    assert(waiter:join())
    local closer = Poll.spawn(function()
      closed = assert(Poll.ready({ writer, reader }, { sys.POLLIN, sys.POLLIN }, Clock.seconds(5)))
    end)
    assert(Poll.delay(0))
    Poll.closing(reader)
    assert(closer:join(Clock.seconds(1)))
  end)
  assert(timed == Poll.TIMEOUT, timed)
  assert(cancelled == Poll.CANCELLED, cancelled)
  assert(closed[2] == sys.POLLNVAL, tostring(closed[2]))
  sys.close(reader)
  sys.close(writer)
end

local function test_a_ready_wait_refuses_what_is_no_wait()
  Poll.run(function()
    raises(function() local _, _ = Poll.ready({}, {}) end, "one or more descriptors")
    raises(function() local _, _ = Poll.ready({ 0 }, {}) end, "one or more descriptors")
    raises(function() local _, _ = Poll.ready({ -1 }, { sys.POLLIN }) end, "fds[1] must be a descriptor")
    raises(function() local _, _ = Poll.ready({ 0 }, { -1 }) end, "events[1] must be a mask")
  end)
  raises(function() local _, _ = Poll.ready({ 0 }, { sys.POLLIN }) end, "Poll.ready outside Poll.run")
end

--- The growth of live memory, in KiB, from `base`, once what is no
--- longer reachable is collected.
local function grown_since(base: number): number
  collectgarbage()
  collectgarbage()
  return collectgarbage("count") - base
end

--- Long time waits answered early are not kept until their times come:
--- a server's tasks, each waiting with a long timeout and answered
--- first, would otherwise hold every wait it ever made, and its task,
--- behind a wait due sooner that is still waiting.
local function test_time_waits_answered_early_are_not_kept()
  local early, late = 0.0, 0.0
  Poll.run(function()
    local sooner = Poll.spawn(function()
      local _, _ = Poll.delay(Clock.minutes(30))
    end)
    assert(Poll.delay(0))
    collectgarbage()
    collectgarbage()
    local base = collectgarbage("count")
    for round = 1, 10 do
      local tasks: {Poll.Task} = {}
      for i = 1, 1000 do
        tasks[i] = Poll.spawn(function()
          local _, _ = Poll.delay(Clock.minutes(60))
        end)
      end
      assert(Poll.delay(0))
      for _, task in ipairs(tasks) do task:cancel() end
      for _, task in ipairs(tasks) do assert(task:join()) end
      local grown = grown_since(base)
      if round <= 2 then early = math.max(early, grown) else late = math.max(late, grown) end
    end
    sooner:cancel()
  end)
  assert(late < early + 128, ("grew %.0f KiB, then %.0f KiB"):format(early, late))
end

--- A task joined over and over with a timeout keeps none of the joins
--- its timeout answered, and still answers the joins left waiting, in
--- the order they began.
local function test_joins_a_timeout_answers_are_not_kept()
  local early, late = 0.0, 0.0
  local order: {string} = {}
  Poll.run(function()
    local sleeper = Poll.spawn(function()
      local _, _ = Poll.delay(Clock.minutes(60))
    end)
    local function joiner(name: string): Poll.Task
      return Poll.spawn(function()
        assert(sleeper:join())
        order[#order + 1] = name
      end)
    end
    local first = joiner("first")
    assert(Poll.delay(0))
    collectgarbage()
    collectgarbage()
    local base = collectgarbage("count")
    for round = 1, 10 do
      for _ = 1, 1000 do
        local ok, why = sleeper:join(0)
        assert(not ok and why == Poll.TIMEOUT, why)
      end
      local grown = grown_since(base)
      if round <= 2 then early = math.max(early, grown) else late = math.max(late, grown) end
    end
    local second = joiner("second")
    assert(Poll.delay(0))
    sleeper:cancel()
    assert(first:join())
    assert(second:join())
  end)
  assert(late < early + 64, ("grew %.0f KiB, then %.0f KiB"):format(early, late))
  assert(table.concat(order, " ") == "first second", table.concat(order, " "))
end

--- A join answered by a cancel, its task killed before it resumes,
--- is no joiner's either, as one killed while it waits is not.
local function test_joins_killed_after_their_answer_are_not_kept()
  local early, late = 0.0, 0.0
  Poll.run(function()
    local sleeper = Poll.spawn(function()
      local _, _ = Poll.delay(Clock.minutes(60))
    end)
    assert(Poll.delay(0))
    collectgarbage()
    collectgarbage()
    local base = collectgarbage("count")
    for round = 1, 10 do
      for _ = 1, 100 do
        local answered = Poll.spawn(function()
          local _, _ = sleeper:join()
        end)
        local waiting = Poll.spawn(function()
          local _, _ = sleeper:join(Clock.seconds(1))
        end)
        assert(Poll.delay(0))
        answered:cancel()
        answered:kill()
        waiting:kill()
      end
      local grown = grown_since(base)
      if round <= 2 then early = math.max(early, grown) else late = math.max(late, grown) end
    end
    sleeper:cancel()
  end)
  assert(late < early + 128, ("grew %.0f KiB, then %.0f KiB"):format(early, late))
end

--- Waits on descriptors that end by a cancel or a kill leave nothing
--- polled: tasks left waiting only on each other still raise rather
--- than wait on a descriptor no task waits on.
local function test_ended_descriptor_waits_leave_nothing_polled(tmp: string)
  local reader, writer = fifo(tmp, "p")
  raises(function()
    Poll.run(function()
      local cancelled = Poll.spawn(function()
        local _, _ = Poll.ready({ reader, reader }, { sys.POLLIN, 0 }, Clock.seconds(100))
      end)
      local killed = Poll.spawn(function()
        local _, _ = Poll.readable(reader, Clock.seconds(100))
      end)
      assert(Poll.delay(0))
      cancelled:cancel()
      killed:kill()
      assert(Poll.delay(0))
      local first: Poll.Task
      local second = Poll.spawn(function()
        local _, _ = first:join()
      end)
      first = Poll.spawn(function()
        local _, _ = second:join()
      end)
      local _, _ = first:join()
    end)
  end, "every task waits on another")
  sys.close(reader)
  sys.close(writer)
end

--- Waits begin and end on descriptors many of them share, round after
--- round: each wait on a descriptor made ready is answered in the turn
--- it is, those of one turn in the order they began; a wait asking for
--- none of what came stays waiting; and one cancelled, or on a
--- descriptor about to close, is answered so.
local function test_waits_sharing_descriptors_come_and_go(tmp: string)
  local count = 6
  local readers: {integer} = {}
  local writers: {integer} = {}
  for i = 1, count do readers[i], writers[i] = fifo(tmp, "p" .. i) end
  Poll.run(function()
    for round = 1, 20 do
      local seen: {string} = {}
      local answers: {integer:{integer}} = {}
      local waiting: {integer:{Poll.Task}} = {}
      for i = 1, count do
        waiting[i] = {}
        for r = 1, 3 do
          waiting[i][r] = Poll.spawn(function()
            local ok, why = Poll.readable(readers[i], Clock.seconds(5))
            seen[#seen + 1] = i .. "r" .. r .. (ok and "" or " " .. why)
          end)
        end
        Poll.spawn(function()
          -- The writer is writable, but this wait does not ask that.
          answers[i] = assert(Poll.ready({ readers[i], writers[i] }, { sys.POLLIN, 0 }, Clock.seconds(5)))
          seen[#seen + 1] = i .. "q"
        end)
        Poll.spawn(function()
          assert(Poll.writable(writers[i], Clock.seconds(5)))
          seen[#seen + 1] = i .. "w"
        end)
      end
      assert(Poll.delay(0))
      assert(Poll.delay(0))
      local expected: {string} = {}
      for i = 1, count do expected[#expected + 1] = i .. "w" end
      assert(table.concat(seen, ",") == table.concat(expected, ","), table.concat(seen, ","))
      seen, expected = {}, {}
      -- A cancel or a closing answers its waits at once, a write at the
      -- next poll.
      local at_once, written: {string}, {string} = {}, {}
      for i = 1, count do
        local how = (i + round) % 3
        if how == 0 then
          waiting[i][2]:cancel()
          at_once[#at_once + 1] = i .. "r2 " .. Poll.CANCELLED
        elseif how == 1 then
          Poll.closing(readers[i])
          for r = 1, 3 do at_once[#at_once + 1] = i .. "r" .. r end
          at_once[#at_once + 1] = i .. "q"
        else
          assert(sys.write(writers[i], "x") == 1)
          for r = 1, 3 do written[#written + 1] = i .. "r" .. r end
          written[#written + 1] = i .. "q"
        end
      end
      assert(Poll.delay(0))
      for _, list in ipairs({ at_once, written }) do
        for _, each in ipairs(list) do expected[#expected + 1] = each end
      end
      assert(table.concat(seen, ",") == table.concat(expected, ","), table.concat(seen, ","))
      seen, expected = {}, {}
      for i = 1, count do
        local how = (i + round) % 3
        if how == 0 then
          assert(sys.write(writers[i], "x") == 1)
          expected[#expected + 1] = i .. "r1"
          expected[#expected + 1] = i .. "r3"
          expected[#expected + 1] = i .. "q"
        end
      end
      assert(Poll.delay(0))
      assert(table.concat(seen, ",") == table.concat(expected, ","), table.concat(seen, ","))
      for i = 1, count do
        local how = (i + round) % 3
        local first = how == 1 and sys.POLLNVAL or sys.POLLIN
        assert(answers[i][1] & first ~= 0 and answers[i][2] == 0,
          i .. ": " .. answers[i][1] .. " " .. answers[i][2])
        if how ~= 1 then assert(sys.read(readers[i], 16) == "x") end
      end
    end
  end)
  for i = 1, count do
    sys.close(readers[i])
    sys.close(writers[i])
  end
end

--- The error a task raises ends the run with the task's own stack
--- beneath it, down to the function that raised; an error that is no
--- string ends it as it was raised.
local function test_a_task_error_carries_the_task_s_stack()
  local function deep_in_the_task()
    error("deep trouble", 0)
  end
  local ok, err: boolean, any = pcall(Poll.run, function()
    local failing = Poll.spawn(function()
      assert(Poll.delay(0))
      deep_in_the_task()
    end)
    assert(failing:join())
  end)
  local text = tostring(err)
  assert(not ok and text:find("deep trouble\nstack traceback:", 1, true) == 1, text)
  assert(text:find("deep_in_the_task", 1, true) ~= nil, text)
  local raised = {}
  local again, value: boolean, any = pcall(Poll.run, function() error(raised) end)
  assert(not again and rawequal(value, raised), tostring(value))
end

--- A cancel answers none of a shielded task's waits, which each wait
--- for what they wait for while the other tasks run; the first wait
--- after the shield answers CANCELLED. Shields nest, and one left by a
--- raise is let go.
local function test_a_shielded_wait_outlasts_a_cancel()
  local seen: {string} = {}
  Poll.run(function()
    local ticks = 0
    local ticker = Poll.spawn(function()
      while Poll.delay(Clock.ms(1)) do ticks = ticks + 1 end
    end)
    local shielded = Poll.spawn(function()
      Poll.shielded(function()
        local ok, why = Poll.delay(Clock.ms(30))
        seen[#seen + 1] = "delay " .. tostring(ok) .. why
        Poll.shielded(function()
          ok, why = Poll.delay(0)
          seen[#seen + 1] = "nested " .. tostring(ok) .. why
        end)
        ok, why = Poll.delay(0)
        seen[#seen + 1] = "after nested " .. tostring(ok) .. why
      end)
      raises(function() Poll.shielded(function() error("inside", 0) end) end, "inside")
      local ok, why = Poll.delay(Clock.ms(30))
      seen[#seen + 1] = "after " .. tostring(ok) .. " " .. why
    end)
    assert(Poll.delay(0))
    shielded:cancel()
    local before = ticks
    assert(shielded:join())
    assert(ticks > before, "nothing else ran while the shielded task waited")
    ticker:cancel()
  end)
  assert(table.concat(seen, ", ") ==
      "delay true, nested true, after nested true, after false " .. Poll.CANCELLED,
    table.concat(seen, ", "))
end

--- A kill still ends a shielded task where it waits, and a failed run
--- still closes one; shielding outside a task, or no function, raises.
local function test_a_shielded_task_is_killed_and_closed()
  local closed = 0
  local closer_mt: metatable<Closer> = { __close = function() closed = closed + 1 end }
  Poll.run(function()
    local victim = Poll.spawn(function()
      Poll.shielded(function()
        local _ <close> = setmetatable({} as Closer, closer_mt)
        local _, _ = Poll.delay(Clock.minutes(60))
      end)
    end)
    assert(Poll.delay(0))
    victim:cancel()
    victim:kill()
    local ok, why = victim:join()
    assert(not ok and why == Poll.CANCELLED, why)
    raises(function() Poll.shielded(nil) end, "Poll.shielded takes a function")
  end)
  assert(closed == 1, closed .. " closed")
  local ok, err: boolean, any = pcall(Poll.run, function()
    Poll.spawn(function()
      Poll.shielded(function()
        local _ <close> = setmetatable({} as Closer, closer_mt)
        local _, _ = Poll.delay(Clock.minutes(60))
      end)
    end)
    assert(Poll.delay(0))
    error("torn down", 0)
  end)
  assert(not ok and tostring(err):find("torn down", 1, true) == 1, tostring(err))
  assert(closed == 2, closed .. " closed")
  raises(function() Poll.shielded(function() end) end, "Poll.shielded outside Poll.run")
end

--- What the three waits of this tree took as their longest were each
--- 2^31-1 milliseconds, the most [`sys.poll`] takes.
local function test_the_longest_wait_is_what_sys_poll_takes()
  assert(Poll.MOST_NS == 2147483647 * Clock.ms(1), tostring(Poll.MOST_NS))
  Poll.run(function()
    -- Taken, and cut to a poll's own limit rather than wrapping it.
    local sleeper = Poll.spawn(function()
      local ok, why = Poll.delay(Poll.MOST_NS)
      assert(not ok and why == Poll.CANCELLED, why)
    end)
    assert(Poll.delay(Clock.ms(5)))
    sleeper:cancel()
    assert(sleeper:join())
  end)
end

--- A span is nanoseconds: a delay waits as long as it says, neither a
--- millionth of it nor a million times it, and one nanosecond is a wait
--- that ends rather than none.
local function test_a_wait_lasts_the_nanoseconds_it_is_given(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local delayed, readable, ready, joined = 0, 0, 0, 0
  Poll.run(function()
    local began = Clock.monotonic_ns()
    assert(Poll.delay(Clock.ms(80)))
    delayed = Clock.monotonic_ns() - began
    began = Clock.monotonic_ns()
    local ok, why = Poll.readable(reader, Clock.ms(80))
    assert(not ok and why == Poll.TIMEOUT, why)
    readable = Clock.monotonic_ns() - began
    began = Clock.monotonic_ns()
    local answers, answered = Poll.ready({ reader }, { sys.POLLIN }, Clock.ms(80))
    assert(answers == nil and answered == Poll.TIMEOUT, answered)
    ready = Clock.monotonic_ns() - began
    local sleeper = Poll.spawn(function() local _, _ = Poll.delay(Clock.seconds(30)) end)
    began = Clock.monotonic_ns()
    local ended, reason = sleeper:join(Clock.ms(80))
    assert(not ended and reason == Poll.TIMEOUT, reason)
    joined = Clock.monotonic_ns() - began
    sleeper:kill()
    assert(Poll.delay(1))
    assert(Poll.delay(0))
  end)
  for name, took in pairs({ delay = delayed, readable = readable, ready = ready, join = joined }) do
    assert(took >= Clock.ms(79) and took < Clock.seconds(10),
      name .. " waited " .. tostring(took // Clock.ms(1)) .. " ms, not about 80")
  end
  sys.close(reader)
  sys.close(writer)
end

--- What a wait on one descriptor answers, in a task and out of one: true
--- and "" at once for what is ready, false and TIMEOUT at about its
--- timeout for what is not.
local function test_one_wait_answers_alike_in_a_task_and_out_of_one(tmp: string)
  local quiet, quiet_writer = fifo(tmp, "q")
  local ready, ready_writer = fifo(tmp, "r")
  assert(sys.write(ready_writer, "x"))
  local function answers()
    local began = Clock.monotonic_ns()
    local ok, why = Poll.wait(ready, sys.POLLIN, Clock.seconds(5))
    assert(ok and why == "", why)
    assert(Clock.monotonic_ns() - began < Clock.seconds(2), "a ready descriptor was waited for")
    ok, why = Poll.wait(ready_writer, sys.POLLOUT, Clock.seconds(5))
    assert(ok and why == "", why)
    began = Clock.monotonic_ns()
    ok, why = Poll.wait(quiet, sys.POLLIN, Clock.ms(60))
    assert(not ok and why == Poll.TIMEOUT, why)
    local took = Clock.monotonic_ns() - began
    assert(took >= Clock.ms(59) and took < Clock.seconds(5), tostring(took))
    ok, why = Poll.readable(quiet, 0)
    assert(not ok and why == Poll.TIMEOUT, why)
    ok, why = Poll.writable(quiet_writer, 0)
    assert(ok and why == "", why)
  end
  answers()
  Poll.run(answers)
  for _, fd in ipairs({ quiet, quiet_writer, ready, ready_writer }) do sys.close(fd) end
end

--- A wait is cancelled in a task, as every wait is, and refuses what is
--- no wait wherever it is called.
local function test_a_wait_is_cancelled_and_refuses_what_is_no_wait(tmp: string)
  local reader, writer = fifo(tmp, "p")
  Poll.run(function()
    local cancelled = ""
    local waiter = Poll.spawn(function()
      local ok, why = Poll.wait(reader, sys.POLLIN)
      assert(not ok)
      cancelled = why
    end)
    assert(Poll.delay(0))
    waiter:cancel()
    assert(waiter:join())
    assert(cancelled == Poll.CANCELLED, cancelled)
  end)
  for _, inside in ipairs({ false, true }) do
    local function refuses()
      raises(function() local _, _ = Poll.wait(-1, sys.POLLIN) end, "fd must be a descriptor")
      raises(function() local _, _ = Poll.wait(reader, -1) end, "events must be a mask")
      raises(function() local _, _ = Poll.wait(reader, sys.POLLIN, -1) end, "timeout_ns must be")
    end
    if inside then Poll.run(refuses) else refuses() end
  end
  sys.close(reader)
  sys.close(writer)
end

--- The check every timeout is held to, at the level the caller names: a
--- float, a negative and one past what a wait takes raise, nil and
--- the ends of the range do not.
local function test_checked_ns_refuses_what_no_wait_can_last()
  Poll.checked_ns(nil, "poll", "span", 1)
  Poll.checked_ns(0, "poll", "span", 1)
  Poll.checked_ns(Poll.MOST_NS, "poll", "span", 1)
  local function refused(value: any)
    local ok, err: boolean, any = pcall(function() Poll.checked_ns(value, "poll", "span", 1) end)
    assert(not ok, "accepted " .. tostring(value))
    local text = tostring(err)
    assert(text:find("poll: span must be nil or an integer from 0 to " .. Poll.MOST_NS, 1, true), text)
    -- Level 1 is the function that calls it: this file's own, not poll.tl.
    assert(text:find("poll_test:", 1, true), text)
  end
  refused(1.5)
  refused(2.0)
  refused(-1)
  refused(Poll.MOST_NS + 1)
  refused("1")
end

--- While a failed run closes its tasks, a `<close>` handler that waits
--- is refused rather than allowed to hold the thread, as in a task being
--- killed: `wait` raises, naming the closing.
local function test_a_wait_raises_while_the_run_closes_its_tasks(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local trouble = ""
  local waiter_mt: metatable<Closer> = { __close = function()
    local _, err: boolean, any = pcall(Poll.wait, reader, sys.POLLIN, 0)
    trouble = tostring(err)
  end }
  local ok, err: boolean, any = pcall(Poll.run, function()
    Poll.spawn(function()
      local _ <close> = setmetatable({} as Closer, waiter_mt)
      local _, _ = Poll.delay(Clock.seconds(30))
    end)
    assert(Poll.delay(0))
    error("the run fails", 0)
  end)
  assert(not ok and tostring(err):find("the run fails", 1, true), tostring(err))
  assert(trouble:find("Poll.wait while Poll.run closes its tasks", 1, true), trouble)
  sys.close(reader)
  sys.close(writer)
end
