local Array = require("cosmic.array")
local Defer = require("cosmic.defer")
local support = require("build.test_support_fixture")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Test = require("cosmic.test")

local process = require("cosmic.internal.process")

--- A wait's failure in the words it once returned: "" for none.
local function words(why?: Failure): string
  if why == nil then return "" end
  return why.message
end

--- The two ends of a named pipe in `dir`, neither waiting: the reading
--- end open first, as a pipe with no reader refuses a nonblocking writer.
local function fifo(dir: string, name: string): integer, integer
  local ends = support.fifo(dir, name)
  return ends.reader, ends.writer
end

local function test_milliseconds_round_a_timeout_up_and_no_limit_is_minus_one()
  assert(Poll.milliseconds(nil) == -1)
  assert(Poll.milliseconds(0) == 0)
  assert(Poll.milliseconds(1) == 1)
  assert(Poll.milliseconds(Clock.ms(3)) == 3)
  assert(Poll.milliseconds(Clock.ms(3) + 1) == 4)
end

local function test_tasks_take_turns_as_each_waits()
  local seen: mut {string} = {}
  Poll.run(function()
    local a = Poll.spawn(function()
      seen[#seen + 1] = "a1"
      assert(Clock.sleep(0))
      seen[#seen + 1] = "a2"
    end)
    local b = Poll.spawn(function()
      seen[#seen + 1] = "b1"
      assert(Clock.sleep(0))
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
  local order: mut {integer} = {}
  Poll.run(function()
    for _, ms in ipairs({ 150, 50, 100 }) do
      Poll.spawn(function()
        assert(Clock.sleep(Clock.ms(ms)))
        order[#order + 1] = ms
      end)
    end
  end)
  assert(table.concat(order, " ") == "50 100 150", table.concat(order, " "))
end

local function test_a_readable_wait_ends_when_data_arrives(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local got: string = ""
  Poll.run(function()
    local listener = Poll.spawn(function()
      assert(Poll.readable(reader, Clock.seconds(5)))
      got = assert(sys.read(reader, 16))
    end)
    assert(Clock.sleep(Clock.ms(10)))
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
    assert(not ok and why.kind == "timeout", why)
    local sleeper = Poll.spawn(function() local _, _ = Clock.sleep(Clock.seconds(1)) end)
    local joined, join_why = sleeper:join(Clock.ms(10))
    assert(not joined and join_why.kind == "timeout", join_why)
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

--- A cancelled task's wait, and every one after it, fails with
--- CANCELLED, so the task unwinds on its own terms.
local function test_cancel_ends_a_wait_and_every_later_one(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local answers: mut {string} = {}
  Poll.run(function()
    local task = Poll.spawn(function()
      local _, why = Poll.readable(reader)
      local said = words(why)
      answers[#answers + 1] = said
      local _, again = Clock.sleep(0)
      local said_again = words(again)
      answers[#answers + 1] = said_again
    end)
    assert(Clock.sleep(0))
    task:cancel()
    assert(task:join())
  end)
  assert(answers[1] == Poll.CANCELLED and answers[2] == Poll.CANCELLED,
    table.concat(answers, ","))
  sys.close(reader)
  sys.close(writer)
end

--- An error ends the run: the other tasks are closed where they wait,
--- their `<close>` variables with them, and `run` raises it; the next
--- `run` starts afresh.
local function test_an_error_ends_the_run_and_closes_the_rest()
  local closed: boolean = false
  local closer = function() closed = true end
  local ok, err: boolean, any = pcall(Poll.run, function()
    Poll.spawn(function()
      local _ <close> = Defer.new(closer)
      assert(Clock.sleep(Clock.seconds(1)))
    end)
    assert(Clock.sleep(0))
    error("broken", 0)
  end)
  assert(not ok and tostring(err):find("broken\nstack traceback:", 1, true) == 1, tostring(err))
  assert(closed, "the waiting task's <close> variable was not closed")
  local ran: boolean = false
  Poll.run(function() ran = true end)
  assert(ran, "a run after a raise did not run")
end

--- A raise names its module, however the call was wrong.
local function test_a_raise_names_the_module()
  local raising: {function()} = {
    function() Poll.spawn(function() end) end,
    function() Poll.checked_ns(-1, "poll", "span", 1) end,
    function() local _, _ = Poll.ready({ 0 }, { sys.POLLIN }) end,
  }
  for i, call in ipairs(raising) do
    local ok, err: boolean, any = pcall(call)
    assert(not ok and tostring(err):find(": poll: ", 1, true) ~= nil, tostring(i) .. ": " .. tostring(err))
  end
end

local function test_waiting_outside_a_task_raises()
  Test.raises(function() Poll.spawn(function() end) end, "outside Poll.run")
  Poll.run(function()
    Test.raises(function() Poll.run(function() end) end, "already running")
    local notifier = Poll.notifier()
    local inner = coroutine.wrap(function() local _, _ = notifier:wait(0) end)
    Test.raises(inner, "outside a task's own coroutine")
    Test.raises(function() local _, _ = notifier:wait(-1) end, "from 0")
  end)
end

--- A wait on one descriptor goes on where there is no task to wait in --
--- outside a run, in a coroutine of its own -- holding the thread for
--- as long as it would have waited, and returns as a task's does.
local function test_a_wait_outside_a_task_holds_the_thread(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local function outside()
    local began = Clock.monotonic_ns()
    local ok, why = Poll.wait(reader, sys.POLLIN, Clock.ms(40))
    assert(not ok and why.kind == "timeout", why)
    ok, why = Poll.readable(reader, Clock.ms(40))
    assert(not ok and (why ~= nil and why.kind == "timeout"), why)
    assert(Clock.monotonic_ns() - began >= Clock.ms(79), "a wait returned early")
    ok, why = Poll.writable(writer, Clock.ms(40))
    assert(ok and why == nil, why)
  end
  outside()
  Poll.run(function()
    coroutine.wrap(outside)()
  end)
  sys.close(reader)
  sys.close(writer)
end

local function test_tasks_waiting_only_on_each_other_raise()
  Test.raises(function()
    Poll.run(function()
      local other: Poll.Task?
      local first = Poll.spawn(function()
        assert(Clock.sleep(0))
        assert(assert(other, "other was spawned"):join())
      end)
      other = Poll.spawn(function() assert(first:join()) end)
      assert(first:join())
    end)
  end, "every task waits on another")
end

local function test_a_yield_of_its_own_raises()
  Test.raises(function()
    Poll.run(function() coroutine.yield() end) -- checked: field_unknown
  end, "yielded other than through cosmic.poll")
end

--- Many tasks each wait on a descriptor of their own at once, and each
--- is woken for its own.
local function test_many_tasks_wait_on_descriptors_at_once(tmp: string)
  local count = 200
  local readers: mut {integer} = {}
  local writers: mut {integer} = {}
  for i = 1, count do
    local reader, writer = fifo(tmp, "p" .. tostring(i))
    readers[#readers + 1], writers[#writers + 1] = reader, writer
  end
  local got: mut {integer: string} = {}
  Poll.run(function()
    for i = 1, count do
      Poll.spawn(function()
        assert(Poll.readable(Array.at(readers, i), Clock.seconds(5)))
        got[i] = assert(sys.read(Array.at(readers, i), 16))
      end)
    end
    assert(Clock.sleep(0))
    for i = count, 1, -1 do assert(assert(sys.write(Array.at(writers, i), tostring(i))) > 0) end
  end)
  for i = 1, count do
    assert(got[i] == tostring(i), "task " .. tostring(i) .. " read " .. tostring(got[i]))
    sys.close(Array.at(readers, i))
    sys.close(Array.at(writers, i))
  end
end

--- A wait woken one way is woken once: a readable wait with a
--- timeout, woken by data, leaves no timer to wake the task early
--- from its next wait.
local function test_a_wait_is_answered_once(tmp: string)
  local reader, writer = fifo(tmp, "p")
  assert(sys.write(writer, "x") == 1)
  local waited: integer = 0
  Poll.run(function()
    assert(Poll.readable(reader, Clock.ms(30)))
    local before = Clock.monotonic_ns()
    assert(Clock.sleep(Clock.ms(60)))
    waited = Clock.monotonic_ns() - before
  end)
  assert(waited >= Clock.ms(59), "the delay ended after " .. tostring(waited // Clock.ms(1)) .. " ms")
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
    assert(Clock.sleep(0))
    sys.close(writer)
    assert(task:join(Clock.seconds(5)))
    assert(Poll.readable(closed_reader, Clock.seconds(5)))
  end)
  sys.close(reader)
  sys.close(closed_writer)
end

--- Two tasks waiting on one descriptor are both woken by it.
local function test_waits_sharing_a_descriptor_are_each_answered(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local woke: integer = 0
  Poll.run(function()
    for _ = 1, 2 do
      Poll.spawn(function()
        assert(Poll.readable(reader, Clock.seconds(5)))
        woke = woke + 1
      end)
    end
    assert(Clock.sleep(0))
    assert(sys.write(writer, "x") == 1)
  end)
  assert(woke == 2, "woke " .. tostring(woke))
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
  local answers: mut {string} = {}
  local kept: Poll.Task? = nil
  Poll.run(function()
    local early = Poll.spawn(function()
      local _, why = Clock.sleep(Clock.seconds(1))
      local said = words(why)
      answers[#answers + 1] = said
    end)
    early:cancel()
    local selfish: Poll.Task?
    selfish = Poll.spawn(function()
      assert(selfish, "selfish was spawned"):cancel()
      local _, why = Clock.sleep(Clock.seconds(1))
      local said = words(why)
      answers[#answers + 1] = said
    end)
    assert(early:join())
    assert(selfish:join())
    kept = selfish
  end)
  assert(answers[1] == Poll.CANCELLED and answers[2] == Poll.CANCELLED, table.concat(answers, ","))
  assert(kept, "kept was spawned"):cancel()
end

--- A cancelled task that waits in a loop still lets the others run.
local function test_a_cancelled_task_waiting_in_a_loop_lets_others_run()
  local spins: integer = 0
  local spins_at_first: integer = -1
  Poll.run(function()
    local spinner = Poll.spawn(function()
      for _ = 1, 100 do
        local _, _ = Clock.sleep(Clock.seconds(1))
        spins = spins + 1
      end
    end)
    Poll.spawn(function()
      assert(Clock.sleep(0))
      spins_at_first = spins
    end)
    spinner:cancel()
  end)
  assert(spins == 100, "the spinner spun " .. tostring(spins) .. " times")
  assert(spins_at_first >= 0 and spins_at_first < 100,
    "the delayed task ran only after " .. tostring(spins_at_first) .. " spins")
end

--- A task that raises has its own `<close>` variables closed, as code
--- outside a task would.
local function test_a_raising_task_closes_its_own_close_variables()
  local closed: boolean = false
  local closer = function() closed = true end
  Test.raises(function()
    Poll.run(function()
      local _ <close> = Defer.new(closer)
      error("broken", 0)
    end)
  end, "broken")
  assert(closed, "the raising task's <close> variable was not closed")
end

--- A run that raised, for any reason, leaves the next free to run, and
--- a handle kept from it behaves as a task that has ended.
local function test_a_failed_run_leaves_the_next_free()
  local kept: Poll.Task? = nil
  Test.raises(function()
    Poll.run(function()
      kept = Poll.spawn(function() local _, _ = Clock.sleep(Clock.seconds(1)) end)
      assert(Clock.sleep(0))
      error("broken", 0)
    end)
  end, "broken")
  Test.raises(function()
    Poll.run(function()
      local other: Poll.Task?
      local first = Poll.spawn(function()
        assert(Clock.sleep(0))
        assert(assert(other, "other was spawned"):join())
      end)
      other = Poll.spawn(function() assert(first:join()) end)
    end)
  end, "every task waits on another")
  Poll.run(function()
    assert(kept, "kept was spawned"):cancel()
    local joined, why = assert(kept, "kept was spawned"):join(0)
    assert(not joined and why.kind == "cancelled", why)
  end)
end

--- Timeouts are bounded by what poll takes; a join bounded by one is no
--- deadlock.
local function test_timeouts_are_bounded_and_timed_joins_are_no_deadlock()
  Poll.run(function()
    Test.raises(function() local _, _ = Poll.readable(0, math.maxinteger) end, "from 0 to")
    local a: Poll.Task?
    local b = Poll.spawn(function() local _, _ = assert(a, "a was spawned"):join(Clock.ms(20)) end)
    a = Poll.spawn(function() local _, _ = b:join(Clock.ms(20)) end)
  end)
end

--- `in_task` returns whether the caller is a task of a running run.
local function test_in_task_answers_only_in_a_task()
  assert(not Poll.in_task(), "outside a run")
  local inside: boolean = false
  local nested: boolean = true
  Poll.run(function()
    inside = Poll.in_task()
    nested = coroutine.wrap(function(): boolean return Poll.in_task() end)() as boolean -- checked: cast_refused
  end)
  assert(inside and not nested, tostring(inside) .. " " .. tostring(nested))
end

--- `closing` wakes the waits on a descriptor about to be closed.
local function test_closing_answers_the_waits_on_a_descriptor(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local answered: boolean = false
  Poll.run(function()
    local waiter = Poll.spawn(function()
      local ready, _ = Poll.readable(reader, Clock.seconds(5))
      answered = ready
    end)
    assert(Clock.sleep(0))
    Poll.closing(reader)
    assert(waiter:join(Clock.seconds(1)))
  end)
  assert(answered, "the wait was not answered")
  Poll.closing(reader)
  sys.close(reader)
  sys.close(writer)
end

--- `answer` wakes each wait on a descriptor as though it had the events, every place given only what it asked: a
--- module that read into a buffer what another task waits on wakes that task to look there.
local function test_answer_wakes_the_waits_on_a_descriptor_with_its_events(tmp: string)
  local reader, writer = fifo(tmp, "a")
  local readable: boolean = false
  local answers: {integer}? = nil
  local woken_for_room = false
  Poll.run(function()
    local one = Poll.spawn(function()
      local ready, _ = Poll.readable(reader, Clock.seconds(5))
      readable = ready
    end)
    local both = Poll.spawn(function()
      answers = assert(Poll.ready({ writer, reader }, { sys.POLLIN, sys.POLLIN }, Clock.seconds(5)))
    end)
    -- A wait for room on it asked for none of the events: it stays parked.
    local other = Poll.spawn(function()
      local _, _ = Poll.wait(reader, sys.POLLOUT, Clock.seconds(5))
      woken_for_room = true
    end)
    assert(Clock.sleep(0))
    Poll.answer(reader, sys.POLLIN)
    assert(one:join(Clock.seconds(1)))
    assert(both:join(Clock.seconds(1)))
    assert(Clock.sleep(Clock.ms(20)))
    assert(not woken_for_room, "a wait for room was answered with what it did not ask")
    other:cancel()
    local _, _ = other:join()
    Test.raises(function() Poll.answer(-1, sys.POLLIN) end, "fd must be a descriptor")
    Test.raises(function() Poll.answer(reader, -1) end, "events must be a mask")
  end)
  assert(readable, "the wait was not answered")
  local got = assert(answers, "the wait on two was not answered")
  assert(got[1] == 0 and got[2] == sys.POLLIN, tostring(got[1]) .. " " .. tostring(got[2]))
  -- Outside a run it does nothing.
  Poll.answer(reader, sys.POLLIN)
  sys.close(reader)
  sys.close(writer)
end

--- A killed task is ended where it waits and never resumed: its
--- `<close>` variables are closed, its joiners' joins fail with
--- CANCELLED, and neither its descriptor turning ready nor its timeout
--- passing wakes it after.
local function test_kill_ends_a_parked_task_and_its_waits(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local closed: boolean = false
  local resumed: boolean = false
  local joined_ok: boolean? = nil
  local joined_why: string? = nil
  local closer = function() closed = true end
  Poll.run(function()
    local sleeper = Poll.spawn(function()
      local _ <close> = Defer.new(closer)
      local _, _ = Poll.readable(reader, Clock.ms(20))
      resumed = true
    end)
    local joiner = Poll.spawn(function()
      local ok, why = sleeper:join()
      joined_ok, joined_why = ok, words(why)
    end)
    assert(Clock.sleep(0))
    sleeper:kill()
    assert(closed, "the killed task's <close> variable was not closed")
    assert(sys.write(writer, "x") == 1)
    assert(Clock.sleep(Clock.ms(50)))
    assert(joiner:join())
    local ok, why = sleeper:join()
    assert(not ok and why.kind == "cancelled", why)
  end)
  assert(not resumed, "a killed task was resumed")
  assert(joined_ok ~= true and joined_why == Poll.CANCELLED, joined_why)
  sys.close(reader)
  sys.close(writer)
end

--- A task killed while it waits to be resumed -- not yet started, or
--- woken but not yet run, whether in the ready queue or in the batch
--- the run is resuming -- never runs again.
local function test_kill_takes_a_ready_task_from_the_queue()
  local ran: mut {string} = {}
  Poll.run(function()
    local unstarted = Poll.spawn(function() ran[#ran + 1] = "unstarted" end)
    unstarted:kill()
    local answered = Poll.spawn(function()
      local _, _ = Clock.sleep(Clock.seconds(1))
      ran[#ran + 1] = "answered"
    end)
    assert(Clock.sleep(0))
    answered:cancel()
    answered:kill()
    local later: Poll.Task?
    Poll.spawn(function() assert(later, "later was spawned"):kill() end)
    later = Poll.spawn(function() ran[#ran + 1] = "later" end)
  end)
  assert(#ran == 0, table.concat(ran, ","))
end

--- Killing a task that has ended, or one kept past its run, does
--- nothing; a task killing itself raises.
local function test_kill_of_an_ended_task_or_of_itself()
  local kept: Poll.Task? = nil
  Poll.run(function()
    local done = Poll.spawn(function() end)
    assert(done:join())
    done:kill()
    assert(done:join())
    local selfish: Poll.Task?
    selfish = Poll.spawn(function()
      Test.raises(function() assert(selfish, "selfish was spawned"):kill() end, "cannot kill itself")
    end)
    assert(selfish:join())
    kept = selfish
  end)
  assert(kept, "kept was spawned"):kill()
end

--- What a `<close>` handler raises as its task is killed, `kill` raises,
--- the task ended and its other `<close>` variables closed all the same;
--- uncaught, it ends the run. A handler there cannot wait, though it
--- is in a task, so a module that waits raises rather than hold the
--- thread.
local function test_kill_raises_what_a_close_handler_raises()
  local closed: boolean = false
  local wait_trouble: string = ""
  local sleep_trouble: string = ""
  local in_task: boolean = false
  local closer = function() closed = true end
  local raiser = function()
    local _, err: boolean, any = pcall(function() local _, _ = Poll.notifier():wait(0) end)
    wait_trouble = tostring(err)
    -- Clock.sleep holds the thread here, as a module's cleanup (ending a child) must wait.
    local slept, why = Clock.sleep(Clock.ms(1))
    sleep_trouble = if slept then "" else tostring(why) end
    local _, trouble: boolean, any = pcall(function() local _, _ = Poll.readable(0, 0) end)
    assert(tostring(trouble):find("while its task is killed", 1, true), tostring(trouble))
    in_task = Poll.in_task()
    error("broken close", 0)
  end
  Poll.run(function()
    local task = Poll.spawn(function()
      local _ <close> = Defer.new(closer)
      local _ <close> = Defer.new(raiser)
      local _, _ = Clock.sleep(Clock.seconds(1))
    end)
    assert(Clock.sleep(0))
    local killed, err: boolean, any = pcall(task.kill, task) -- checked: interface_method_value
    assert(not killed and err == "broken close", tostring(err))
    local ok, why = task:join()
    assert(not ok and why.kind == "cancelled", why)
  end)
  assert(closed, "a <close> variable after the raising one was not closed")
  assert(wait_trouble:find("while its task is killed", 1, true), wait_trouble)
  assert(sleep_trouble == "", "a killed task's close handler could not sleep: " .. sleep_trouble)
  assert(in_task, "in_task answered false for a task being killed")
  Test.raises(function()
    Poll.run(function()
      local task = Poll.spawn(function()
        local _ <close> = Defer.new(raiser)
        local _, _ = Clock.sleep(Clock.seconds(1))
      end)
      assert(Clock.sleep(0))
      task:kill()
    end)
  end, "broken close")
end

--- A wait on several descriptors returns what each had, by place, once
--- one is ready: here the second, while the first has nothing to read.
local function test_a_ready_wait_answers_each_descriptor_s_events(tmp: string)
  local quiet, quiet_writer = fifo(tmp, "q")
  local reader, writer = fifo(tmp, "p")
  local answers: {integer}? = nil
  Poll.run(function()
    local listener = Poll.spawn(function()
      answers = assert(Poll.ready({ quiet, reader }, { sys.POLLIN, sys.POLLIN }, Clock.seconds(5)))
    end)
    assert(Clock.sleep(Clock.ms(10)))
    assert(answers == nil, "the wait ended before anything was written")
    assert(sys.write(writer, "hi") == 2)
    assert(listener:join())
  end)
  local ready = assert(answers, "the wait answered")
  assert(ready[1] == 0 and assert(ready[2]) & sys.POLLIN ~= 0,
    tostring(ready[1]) .. " " .. tostring(ready[2]))
  for _, fd in ipairs({ quiet, quiet_writer, reader, writer }) do sys.close(fd) end
end

--- Past its timeout a ready wait returns nil and TIMEOUT, as a readable
--- wait fails; cancelled, it returns nil and CANCELLED; and a descriptor
--- about to close has POLLNVAL.
local function test_a_ready_wait_times_out_is_cancelled_and_is_closed(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local timed: string? = nil
  local cancelled: string? = nil
  local closed: {integer}? = nil
  Poll.run(function()
    local expired, expiry = Poll.ready({ reader }, { sys.POLLIN }, Clock.ms(20))
    assert(expired == nil)
    timed = words(expiry)
    local waiter = Poll.spawn(function()
      local answers, why = Poll.ready({ reader }, { sys.POLLIN })
      assert(answers == nil)
      cancelled = words(why)
    end)
    assert(Clock.sleep(0))
    waiter:cancel()
    assert(waiter:join())
    local closer = Poll.spawn(function()
      closed = assert(Poll.ready({ writer, reader }, { sys.POLLIN, sys.POLLIN }, Clock.seconds(5)))
    end)
    assert(Clock.sleep(0))
    Poll.closing(reader)
    assert(closer:join(Clock.seconds(1)))
  end)
  assert(timed == Poll.TIMEOUT, timed)
  assert(cancelled == Poll.CANCELLED, cancelled)
  local closing = assert(closed, "the wait answered")
  assert(closing[2] == sys.POLLNVAL, tostring(closing[2]))
  sys.close(reader)
  sys.close(writer)
end

local function test_a_ready_wait_refuses_what_is_no_wait()
  Poll.run(function()
    Test.raises(function() local _, _ = Poll.ready({}, {}) end, "one or more descriptors")
    Test.raises(function() local _, _ = Poll.ready({ 0 }, {}) end, "one or more descriptors")
    Test.raises(function() local _, _ = Poll.ready({ -1 }, { sys.POLLIN }) end, "fds[1] must be a descriptor")
    Test.raises(function() local _, _ = Poll.ready({ 0 }, { -1 }) end, "events[1] must be a mask")
  end)
  Test.raises(function() local _, _ = Poll.ready({ 0 }, { sys.POLLIN }) end, "Poll.ready outside Poll.run")
end

--- The growth of live memory, in KiB, from `base`, once what is no
--- longer reachable is collected.
local function grown_since(base: number): number
  collectgarbage()
  collectgarbage()
  return collectgarbage("count") - base
end

--- Long time waits woken early are not kept until their times come:
--- a server's tasks, each waiting with a long timeout and woken
--- first, would otherwise hold every wait it ever made, and its task,
--- behind a wait due sooner that is still waiting.
local function test_time_waits_answered_early_are_not_kept()
  local early: number = 0.0
  local late: number = 0.0
  Poll.run(function()
    local sooner = Poll.spawn(function()
      local _, _ = Clock.sleep(Clock.minutes(30))
    end)
    assert(Clock.sleep(0))
    collectgarbage()
    collectgarbage()
    local base = collectgarbage("count")
    for round = 1, 10 do
      local tasks: mut {Poll.Task} = {}
      for i = 1, 1000 do
        tasks[i] = Poll.spawn(function()
          local _, _ = Clock.sleep(Clock.minutes(60))
        end)
      end
      assert(Clock.sleep(0))
      for _, task in ipairs(tasks) do task:cancel() end
      for _, task in ipairs(tasks) do assert(task:join()) end
      local grown = grown_since(base)
      if round <= 2 then
        early = math.max(early, grown)
      else
        late = math.max(late, grown)
      end
    end
    sooner:cancel()
  end)
  assert(late < early + 128, ("grew %.0f KiB, then %.0f KiB"):format(early, late))
end

--- A task joined over and over with a timeout keeps none of the joins
--- its timeout ended, and still wakes the joins left waiting, in
--- the order they began.
local function test_joins_a_timeout_answers_are_not_kept()
  local early: number = 0.0
  local late: number = 0.0
  local order: mut {string} = {}
  Poll.run(function()
    local sleeper = Poll.spawn(function()
      local _, _ = Clock.sleep(Clock.minutes(60))
    end)
    local function joiner(name: string): Poll.Task
      return Poll.spawn(function()
        assert(sleeper:join())
        order[#order + 1] = name
      end)
    end
    local first = joiner("first")
    assert(Clock.sleep(0))
    collectgarbage()
    collectgarbage()
    local base = collectgarbage("count")
    for round = 1, 10 do
      for _ = 1, 1000 do
        local ok, why = sleeper:join(0)
        assert(not ok and why.kind == "timeout", why)
      end
      local grown = grown_since(base)
      if round <= 2 then
        early = math.max(early, grown)
      else
        late = math.max(late, grown)
      end
    end
    local second = joiner("second")
    assert(Clock.sleep(0))
    sleeper:cancel()
    assert(first:join())
    assert(second:join())
  end)
  assert(late < early + 64, ("grew %.0f KiB, then %.0f KiB"):format(early, late))
  assert(table.concat(order, " ") == "first second", table.concat(order, " "))
end

--- A join woken by a cancel, its task killed before it resumes,
--- is no joiner's either, as one killed while it waits is not.
local function test_joins_killed_after_their_answer_are_not_kept()
  local early: number = 0.0
  local late: number = 0.0
  Poll.run(function()
    local sleeper = Poll.spawn(function()
      local _, _ = Clock.sleep(Clock.minutes(60))
    end)
    assert(Clock.sleep(0))
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
        assert(Clock.sleep(0))
        answered:cancel()
        answered:kill()
        waiting:kill()
      end
      local grown = grown_since(base)
      if round <= 2 then
        early = math.max(early, grown)
      else
        late = math.max(late, grown)
      end
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
  Test.raises(function()
    Poll.run(function()
      local cancelled = Poll.spawn(function()
        local _, _ = Poll.ready({ reader, reader }, { sys.POLLIN, 0 }, Clock.seconds(100))
      end)
      local killed = Poll.spawn(function()
        local _, _ = Poll.readable(reader, Clock.seconds(100))
      end)
      assert(Clock.sleep(0))
      cancelled:cancel()
      killed:kill()
      assert(Clock.sleep(0))
      local first: Poll.Task?
      local second = Poll.spawn(function()
        local _, _ = assert(first, "first was spawned"):join()
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
--- round: each wait on a descriptor made ready is woken in the turn
--- it is, those of one turn in the order they began; a wait asking for
--- none of what came stays waiting; and one cancelled, or on a
--- descriptor about to close, is woken so.
local function test_waits_sharing_descriptors_come_and_go(tmp: string)
  local count = 6
  local readers: mut {integer} = {}
  local writers: mut {integer} = {}
  for i = 1, count do
    local reader, writer = fifo(tmp, "p" .. tostring(i))
    readers[#readers + 1], writers[#writers + 1] = reader, writer
  end
  Poll.run(function()
    for round = 1, 20 do
      local seen: mut {string} = {}
      local answers: mut {integer:{integer}} = {}
      local waiting: mut {integer:{Poll.Task}} = {}
      for i = 1, count do
        local row: mut {Poll.Task} = {}
        waiting[i] = row
        for r = 1, 3 do
          local task = Poll.spawn(function()
            local ok, why = Poll.readable(Array.at(readers, i), Clock.seconds(5))
            table.insert(seen, tostring(i) .. "r" .. tostring(r) .. (if ok then "" else " " .. words(why) end))
          end)
          row[#row + 1] = task
        end
        Poll.spawn(function()
          -- The writer is writable, but this wait does not ask that.
          answers[i] = assert(Poll.ready({ Array.at(readers, i), Array.at(writers, i) }, { sys.POLLIN, 0 }, Clock.seconds(5)))
          table.insert(seen, tostring(i) .. "q")
        end)
        Poll.spawn(function()
          assert(Poll.writable(Array.at(writers, i), Clock.seconds(5)))
          table.insert(seen, tostring(i) .. "w")
        end)
      end
      assert(Clock.sleep(0))
      assert(Clock.sleep(0))
      local expected: mut {string} = {}
      for i = 1, count do table.insert(expected, tostring(i) .. "w") end
      assert(table.concat(seen, ",") == table.concat(expected, ","), table.concat(seen, ","))
      seen, expected = {}, {}
      -- A cancel or a closing wakes its waits at once, a write at the
      -- next poll.
      local at_once, written: mut {string}, mut {string} = {}, {}
      for i = 1, count do
        local how = (i + round) % 3
        if how == 0 then
          Array.at(assert(waiting[i], "every wait of the round has its tasks recorded"), 2):cancel()
          at_once[#at_once + 1] = tostring(i) .. "r2 " .. Poll.CANCELLED
        elseif how == 1 then
          Poll.closing(Array.at(readers, i))
          for r = 1, 3 do at_once[#at_once + 1] = tostring(i) .. "r" .. tostring(r) end
          at_once[#at_once + 1] = tostring(i) .. "q"
        else
          assert(sys.write(Array.at(writers, i), "x") == 1)
          for r = 1, 3 do written[#written + 1] = tostring(i) .. "r" .. tostring(r) end
          written[#written + 1] = tostring(i) .. "q"
        end
      end
      assert(Clock.sleep(0))
      for _, list in ipairs({ at_once, written }) do
        for _, each in ipairs(list) do expected[#expected + 1] = each end
      end
      assert(table.concat(seen, ",") == table.concat(expected, ","), table.concat(seen, ","))
      seen, expected = {}, {}
      for i = 1, count do
        local how = (i + round) % 3
        if how == 0 then
          assert(sys.write(Array.at(writers, i), "x") == 1)
          table.insert(expected, tostring(i) .. "r1")
          table.insert(expected, tostring(i) .. "r3")
          table.insert(expected, tostring(i) .. "q")
        end
      end
      assert(Clock.sleep(0))
      assert(table.concat(seen, ",") == table.concat(expected, ","), table.concat(seen, ","))
      for i = 1, count do
        local how = (i + round) % 3
        local first = if how == 1 then sys.POLLNVAL else sys.POLLIN end
        local pair = assert(answers[i], tostring(i) .. ": the ready wait recorded no answers")
        local on_reader, on_writer = Array.at(pair, 1), Array.at(pair, 2)
        assert(on_reader & first ~= 0 and on_writer == 0,
          tostring(i) .. ": " .. tostring(on_reader) .. " " .. tostring(on_writer))
        if how ~= 1 then assert(sys.read(Array.at(readers, i), 16) == "x") end
      end
    end
  end)
  for i = 1, count do
    sys.close(Array.at(readers, i))
    sys.close(Array.at(writers, i))
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
      assert(Clock.sleep(0))
      deep_in_the_task()
    end)
    assert(failing:join())
  end)
  local text = tostring(err)
  assert(not ok and text:find("deep trouble\nstack traceback:", 1, true) == 1, text)
  assert(text:find("deep_in_the_task", 1, true) ~= nil, text)
  local raised = {} -- checked: literal_needs_type
  local again, value: boolean, any = pcall(Poll.run, function() error(raised) end)
  assert(not again and rawequal(value, raised), tostring(value))
end

--- A cancel wakes none of a shielded task's waits, which each wait for
--- what they wait for while the other tasks run; the first wait after
--- the shield fails with CANCELLED. Shields nest, and one left by a
--- raise is let go.
local function test_a_shielded_wait_outlasts_a_cancel()
  local seen: mut {string} = {}
  Poll.run(function()
    local ticks: integer = 0
    local ticker = Poll.spawn(function()
      while true do
        local ticked, _ = Clock.sleep(Clock.ms(1))
        if not ticked then break end
        ticks = ticks + 1
      end
    end)
    local shielded = Poll.spawn(function()
      Poll.shielded(function()
        local ok, why = Clock.sleep(Clock.ms(30))
        table.insert(seen, "delay " .. tostring(ok) .. words(why))
        Poll.shielded(function()
          local inner_ok, inner_why = Clock.sleep(0)
          table.insert(seen, "nested " .. tostring(inner_ok) .. words(inner_why))
        end)
        ok, why = Clock.sleep(0)
        table.insert(seen, "after nested " .. tostring(ok) .. words(why))
      end)
      Test.raises(function() Poll.shielded(function() error("inside", 0) end) end, "inside")
      local ok, why = Clock.sleep(Clock.ms(30))
      table.insert(seen, "after " .. tostring(ok) .. " " .. words(why))
    end)
    assert(Clock.sleep(0))
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
  local closed: integer = 0
  local closer = function() closed = closed + 1 end
  Poll.run(function()
    local victim = Poll.spawn(function()
      Poll.shielded(function()
        local _ <close> = Defer.new(closer)
        local _, _ = Clock.sleep(Clock.minutes(60))
      end)
    end)
    assert(Clock.sleep(0))
    victim:cancel()
    victim:kill()
    local ok, why = victim:join()
    assert(not ok and why.kind == "cancelled", why)
  end)
  assert(closed == 1, tostring(closed) .. " closed")
  local ok, err: boolean, any = pcall(Poll.run, function()
    Poll.spawn(function()
      Poll.shielded(function()
        local _ <close> = Defer.new(closer)
        local _, _ = Clock.sleep(Clock.minutes(60))
      end)
    end)
    assert(Clock.sleep(0))
    error("torn down", 0)
  end)
  assert(not ok and tostring(err):find("torn down", 1, true) == 1, tostring(err))
  assert(closed == 2, tostring(closed) .. " closed")
  Test.raises(function() Poll.shielded(function() end) end, "Poll.shielded outside Poll.run")
end

--- What the three waits of this tree took as their longest were each
--- 2^31-1 milliseconds, the most [`sys.poll`] takes.
local function test_the_longest_wait_is_what_sys_poll_takes()
  assert(Poll.MOST_NS == 2147483647 * Clock.ms(1), tostring(Poll.MOST_NS))
  Poll.run(function()
    -- Taken, and cut to a poll's own limit rather than wrapping it.
    local sleeper = Poll.spawn(function()
      local ok, why = Clock.sleep(Poll.MOST_NS)
      assert(not ok and why.kind == "cancelled", why)
    end)
    assert(Clock.sleep(Clock.ms(5)))
    sleeper:cancel()
    assert(sleeper:join())
  end)
end

--- A span is nanoseconds: a delay waits as long as it says, neither a
--- millionth of it nor a million times it, and one nanosecond is a wait
--- that ends rather than none.
local function test_a_wait_lasts_the_nanoseconds_it_is_given(tmp: string)
  local reader, writer = fifo(tmp, "p")
  local delayed: integer = 0
  local readable: integer = 0
  local ready: integer = 0
  local joined: integer = 0
  Poll.run(function()
    local began = Clock.monotonic_ns()
    assert(Clock.sleep(Clock.ms(80)))
    delayed = Clock.monotonic_ns() - began
    began = Clock.monotonic_ns()
    local ok, why = Poll.readable(reader, Clock.ms(80))
    assert(not ok and why.kind == "timeout", why)
    readable = Clock.monotonic_ns() - began
    began = Clock.monotonic_ns()
    local answers, answered = Poll.ready({ reader }, { sys.POLLIN }, Clock.ms(80))
    assert(answers == nil and answered.kind == "timeout", answered)
    ready = Clock.monotonic_ns() - began
    local sleeper = Poll.spawn(function() local _, _ = Clock.sleep(Clock.seconds(30)) end)
    began = Clock.monotonic_ns()
    local ended, reason = sleeper:join(Clock.ms(80))
    assert(not ended and reason.kind == "timeout", reason)
    joined = Clock.monotonic_ns() - began
    sleeper:kill()
    assert(Clock.sleep(1))
    assert(Clock.sleep(0))
  end)
  for name, took in pairs({ delay = delayed, readable = readable, ready = ready, join = joined }) do
    assert(took >= Clock.ms(79) and took < Clock.seconds(10),
      name .. " waited " .. tostring(took // Clock.ms(1)) .. " ms, not about 80")
  end
  sys.close(reader)
  sys.close(writer)
end

--- What a wait on one descriptor returns, in a task and out of one: true
--- and "" at once for what is ready, false and TIMEOUT at about its
--- timeout for what is not.
local function test_one_wait_answers_alike_in_a_task_and_out_of_one(tmp: string)
  local quiet, quiet_writer = fifo(tmp, "q")
  local ready, ready_writer = fifo(tmp, "r")
  assert(sys.write(ready_writer, "x"))
  local function answers()
    local began = Clock.monotonic_ns()
    local ok, why = Poll.wait(ready, sys.POLLIN, Clock.seconds(5))
    assert(ok and why == nil, why)
    assert(Clock.monotonic_ns() - began < Clock.seconds(2), "a ready descriptor was waited for")
    ok, why = Poll.wait(ready_writer, sys.POLLOUT, Clock.seconds(5))
    assert(ok and why == nil, why)
    began = Clock.monotonic_ns()
    ok, why = Poll.wait(quiet, sys.POLLIN, Clock.ms(60))
    assert(not ok and (why ~= nil and why.kind == "timeout"), why)
    local took = Clock.monotonic_ns() - began
    assert(took >= Clock.ms(59) and took < Clock.seconds(5), tostring(took))
    ok, why = Poll.readable(quiet, 0)
    assert(not ok and (why ~= nil and why.kind == "timeout"), why)
    ok, why = Poll.writable(quiet_writer, 0)
    assert(ok and why == nil, why)
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
    local cancelled: string = ""
    local waiter = Poll.spawn(function()
      local ok, why = Poll.wait(reader, sys.POLLIN)
      assert(not ok)
      cancelled = why.message
    end)
    assert(Clock.sleep(0))
    waiter:cancel()
    assert(waiter:join())
    assert(cancelled == Poll.CANCELLED, cancelled)
  end)
  for _, inside in ipairs({ false, true }) do
    local function refuses()
      Test.raises(function() local _, _ = Poll.wait(-1, sys.POLLIN) end, "fd must be a descriptor")
      Test.raises(function() local _, _ = Poll.wait(reader, -1) end, "events must be a mask")
      Test.raises(function() local _, _ = Poll.wait(reader, sys.POLLIN, -1) end, "timeout_ns must be")
      -- The caller of the wait is blamed, by its file and line.
      for _, call in ipairs({
          function() local _, _ = Poll.wait(-1, sys.POLLIN) end,
          function() local _, _ = Poll.readable(reader, -1) end,
          function() local _, _ = Poll.writable(-1) end,
      }) do
        local ok, err = pcall(call)
        assert(not ok and tostring(err):find("^cosmic%.poll_test:%d+: poll: ") ~= nil, tostring(err))
      end
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
    assert(text:find("poll: span must be nil or an integer from 0 to " .. tostring(Poll.MOST_NS), 1, true), text)
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
  local trouble: string = ""
  local waiter = function()
    local _, err: boolean, any = pcall(function() local _, _ = Poll.wait(reader, sys.POLLIN, 0) end)
    trouble = tostring(err)
  end
  local ok, err: boolean, any = pcall(Poll.run, function()
    Poll.spawn(function()
      local _ <close> = Defer.new(waiter)
      local _, _ = Clock.sleep(Clock.seconds(30))
    end)
    assert(Clock.sleep(0))
    error("the run fails", 0)
  end)
  assert(not ok and tostring(err):find("the run fails", 1, true) ~= nil, tostring(err))
  assert(trouble:find("Poll.wait while Poll.run closes its tasks", 1, true), trouble)
  sys.close(reader)
  sys.close(writer)
end

--- Starts `n` tasks that each wait on `notifier` and note `id` in `order`
--- when woken, then yields once so they all wait.
local function spawn_waiters(notifier: Poll.Notifier, n: integer, order: mut {integer}): {Poll.Task}
  local tasks: mut {Poll.Task} = {}
  for id = 1, n do
    tasks[id] = Poll.spawn(function()
      local ok, _ = notifier:wait(Clock.seconds(30))
      if ok then order[#order + 1] = id end
    end)
  end
  assert(Clock.sleep(0))
  assert(notifier:waiting() == n)
  return tasks
end

local function test_notify_one_wakes_the_longest_waiter_only()
  local order: mut {integer} = {}
  Poll.run(function()
    local notifier = Poll.notifier()
    local tasks = spawn_waiters(notifier, 3, order)
    notifier:notify_one()
    assert(notifier:waiting() == 2)
    assert(Clock.sleep(0))
    assert(#order == 1 and order[1] == 1)
    notifier:notify_one()
    assert(Clock.sleep(0))
    assert(#order == 2 and order[2] == 2)
    notifier:notify_all()
    for _, task in ipairs(tasks) do assert(task:join()) end
    assert(table.concat(order as {string}, ",") == "1,2,3") -- checked: cast_refused
  end)
end

local function test_notify_all_wakes_every_waiter_in_order_and_not_later_ones()
  local order: mut {integer} = {}
  Poll.run(function()
    local notifier = Poll.notifier()
    local tasks = spawn_waiters(notifier, 50, order)
    notifier:notify_all()
    assert(notifier:waiting() == 0)
    local late = Poll.spawn(function()
      local woke, _ = notifier:wait(Clock.ms(5))
      assert(woke == false)
    end)
    for _, task in ipairs(tasks) do assert(task:join()) end
    assert(late:join())
    assert(#order == 50)
    for i = 1, 50 do assert(order[i] == i, "woken out of order at " .. tostring(i)) end
  end)
end

local function test_a_notifier_wait_times_out()
  Poll.run(function()
    local notifier = Poll.notifier()
    local ok, why = notifier:wait(Clock.ms(5))
    assert(not ok and why.kind == "timeout")
    assert(notifier:waiting() == 0)
  end)
end

local function test_a_cancelled_notifier_wait_answers_cancelled_and_leaves()
  local answer: string = ""
  Poll.run(function()
    local notifier = Poll.notifier()
    local task = Poll.spawn(function()
      local _, why = notifier:wait()
      answer = words(why)
      local _, again = notifier:wait()
      assert((again ~= nil and again.kind == "cancelled"))
    end)
    assert(Clock.sleep(0))
    assert(notifier:waiting() == 1)
    task:cancel()
    assert(task:join())
    assert(notifier:waiting() == 0)
  end)
  assert(answer == Poll.CANCELLED)
end

local function test_a_notice_with_no_waiter_is_not_remembered()
  Poll.run(function()
    local notifier = Poll.notifier()
    notifier:notify_one()
    notifier:notify_all()
    assert(notifier:waiting() == 0)
    local ok, why = notifier:wait(Clock.ms(5))
    assert(not ok and why.kind == "timeout")
  end)
end

local function test_a_killed_waiter_is_removed_and_the_next_one_is_woken()
  local order: mut {integer} = {}
  Poll.run(function()
    local notifier = Poll.notifier()
    local tasks = spawn_waiters(notifier, 3, order)
    Array.at(tasks, 1):kill()
    assert(notifier:waiting() == 2)
    notifier:notify_one()
    assert(Array.at(tasks, 2):join())
    assert(#order == 1 and order[1] == 2)
    notifier:notify_all()
    assert(Array.at(tasks, 3):join())
  end)
end

local function test_a_queue_pattern_loses_no_item()
  local queue: mut {integer} = {}
  local got: mut {integer} = {}
  Poll.run(function()
    local notifier = Poll.notifier()
    local consumer = Poll.spawn(function()
      while #got < 3 do
        while #queue == 0 do assert(notifier:wait(Clock.seconds(30))) end
        local appended = assert(table.remove(queue, 1), "the wait above returns with an item queued")
        got[#got + 1] = appended
      end
    end)
    -- Queued before the consumer first waits, and in a burst.
    queue[#queue + 1] = 1
    notifier:notify_one()
    assert(Clock.sleep(0))
    queue[#queue + 1] = 2
    notifier:notify_one()
    queue[#queue + 1] = 3
    notifier:notify_one()
    assert(consumer:join(Clock.seconds(30)))
  end)
  assert(table.concat(got as {string}, ",") == "1,2,3") -- checked: cast_refused
end

local function test_notify_is_callable_from_a_close_handler()
  local done: boolean = false
  Poll.run(function()
    local notifier = Poll.notifier()
    local waiter = Poll.spawn(function()
      assert(notifier:wait(Clock.seconds(30)))
      done = true
    end)
    assert(Clock.sleep(0))
    local closing = function() notifier:notify_all() end
    local victim = Poll.spawn(function()
      local _ <close> = Defer.new(closing)
      local _, _ = Clock.sleep(Clock.seconds(30))
    end)
    assert(Clock.sleep(0))
    victim:kill()
    assert(waiter:join(Clock.seconds(30)))
  end)
  assert(done)
end

local function test_a_notifier_is_one_runs_and_waits_only_in_a_task()
  Test.raises(function() Poll.notifier() end, "Poll.notifier outside Poll.run")
  local kept: Poll.Notifier? = nil
  Poll.run(function()
    kept = Poll.notifier()
    Test.raises(function() local _, _ = assert(kept, "the notifier was made"):wait(-1) end, "timeout_ns must be")
  end)
  local notifier = assert(kept, "the notifier was made")
  notifier:notify_all()
  assert(notifier:waiting() == 0)
  Test.raises(function() local _, _ = notifier:wait(0) end, "Notifier:wait outside Poll.run")
  Poll.run(function()
    Test.raises(function() local _, _ = notifier:wait(0) end, "notifier of another run")
    local co = coroutine.wrap(function() local _, _ = notifier:wait(0) end)
    Test.raises(function() co() end, "outside a task's own coroutine")
  end)
end

local function test_a_notice_for_a_waiter_killed_before_it_runs_passes_on()
  local woken: mut {integer} = {}
  Poll.run(function()
    local notifier = Poll.notifier()
    local tasks: mut {Poll.Task} = {}
    for id = 1, 2 do
      tasks[id] = Poll.spawn(function()
        local woke, _ = notifier:wait(Clock.ms(300))
        if woke then woken[#woken + 1] = id end
      end)
    end
    assert(Clock.sleep(0))
    notifier:notify_one()
    Array.at(tasks, 1):kill()
    assert(Array.at(tasks, 2):join(Clock.seconds(30)))
    assert(#woken == 1 and woken[1] == 2)
  end)
end

local function test_a_notice_for_a_waiter_killed_in_the_same_batch_passes_on()
  local woken: mut {integer} = {}
  Poll.run(function()
    local notifier = Poll.notifier()
    local tasks: mut {Poll.Task} = {}
    for id = 1, 2 do
      local task = Poll.spawn(function()
        local woke, _ = notifier:wait(Clock.ms(300))
        if woke then woken[#woken + 1] = id end
      end)
      tasks[#tasks + 1] = task
    end
    assert(Clock.sleep(0))
    assert(notifier:waiting() == 2)
    -- Ready before the notice, so it runs ahead of the woken waiter in
    -- the one batch and kills it there.
    local killer = Poll.spawn(function() Array.at(tasks, 1):kill() end)
    notifier:notify_one()
    assert(killer:join(Clock.seconds(30)))
    assert(Array.at(tasks, 2):join(Clock.seconds(30)))
    assert(#woken == 1 and woken[1] == 2)
  end)
end

local function test_a_waiter_cancelled_after_its_notice_still_answers_true()
  local ok: boolean = false
  Poll.run(function()
    local notifier = Poll.notifier()
    local task = Poll.spawn(function()
      local woke, _ = notifier:wait(Clock.seconds(30))
      ok = woke
    end)
    assert(Clock.sleep(0))
    notifier:notify_one()
    task:cancel()
    assert(task:join(Clock.seconds(30)))
  end)
  assert(ok)
end

local function test_a_notice_beats_a_timeout_reached_in_the_same_tick()
  local answers: mut {string} = {}
  Poll.run(function()
    local notifier = Poll.notifier()
    local task = Poll.spawn(function()
      local ok, why = notifier:wait(Clock.ms(2))
      table.insert(answers, tostring(ok) .. ":" .. words(why))
    end)
    assert(Clock.sleep(0))
    -- Past the deadline, but not yet expired by the run.
    local until_ns = Clock.monotonic_ns() + Clock.ms(10)
    while Clock.monotonic_ns() < until_ns do end
    notifier:notify_one()
    assert(task:join(Clock.seconds(30)))
    assert(notifier:waiting() == 0)
  end)
  assert(#answers == 1 and answers[1] == "true:")
end

local function test_a_timeout_beats_a_notice_sent_in_the_same_tick()
  local answers: mut {string} = {}
  local spare: boolean = false
  Poll.run(function()
    local notifier = Poll.notifier()
    local task = Poll.spawn(function()
      local ok, why = notifier:wait(Clock.ms(5))
      table.insert(answers, tostring(ok) .. ":" .. words(why))
    end)
    local sender = Poll.spawn(function()
      assert(Clock.sleep(Clock.ms(5)))
      notifier:notify_one()
      spare = true
    end)
    assert(task:join(Clock.seconds(30)))
    assert(sender:join(Clock.seconds(30)))
    assert(notifier:waiting() == 0)
  end)
  assert(spare)
  assert(#answers == 1 and answers[1] == "false:" .. Poll.TIMEOUT)
end

local function test_a_notifier_wait_without_a_timeout_is_woken_by_a_later_task()
  local woken: boolean = false
  Poll.run(function()
    local notifier = Poll.notifier()
    local waiter = Poll.spawn(function()
      local woke, _ = notifier:wait()
      woken = woke
    end)
    local sender = Poll.spawn(function()
      assert(Clock.sleep(Clock.ms(20)))
      assert(notifier:waiting() == 1)
      notifier:notify_one()
    end)
    assert(waiter:join())
    assert(sender:join())
  end)
  assert(woken)
end

local function test_a_notifier_wait_nobody_can_end_is_a_deadlock()
  Test.raises(function()
    Poll.run(function()
      local notifier = Poll.notifier()
      local _, _ = notifier:wait()
    end)
  end, "every task waits on another")
end

--- Outside a run, `within` is a run of its own: `f` is a task, and the
--- call returns only once the task `f` left running has ended.
local function test_within_outside_a_run_runs_f_in_a_run_it_waits_out()
  local in_task: boolean = false
  local left_ended: boolean = false
  Poll.within(function()
    in_task = Poll.in_task()
    Poll.spawn(function()
      assert(Clock.sleep(0))
      left_ended = true
    end)
  end)
  assert(in_task, "f ran outside a task")
  assert(left_ended, "within returned before a task of its run ended")
  assert(not Poll.in_task(), "the run outlived within")
end

--- In a task, `within` is a call: `f` runs in the caller's task, which a
--- join of that task shows by refusing, and a task it leaves running
--- goes on in the caller's run past the return.
local function test_within_in_a_task_calls_f_there_and_leaves_its_tasks_to_the_run()
  local refused: string = ""
  local ended_at_return: boolean = true
  local left_ended: boolean = false
  Poll.run(function()
    local caller: Poll.Task?
    caller = Poll.spawn(function()
      Poll.within(function()
        refused = Test.raises(function()
          local _, _ = assert(caller, "the caller was spawned"):join()
        end)
        Poll.spawn(function()
          assert(Clock.sleep(0))
          left_ended = true
        end)
      end)
      ended_at_return = left_ended
    end)
  end)
  assert(refused:find("a task cannot join itself", 1, true) ~= nil, refused)
  assert(not ended_at_return, "within waited for a task f left running")
  assert(left_ended, "the run did not wait for the task f left running")
end

--- A `<close>` local that records its closing.
local class Closing
  mut closed: boolean

  function __close(self)
    self.closed = true
  end
end

--- A string `f` raises outside a run comes with `f`'s stack, the task it
--- spawned closed; a value that is no string is raised as it is.
local function test_within_outside_a_run_raises_what_f_raised_as_a_run_does()
  local closing: Closing = { closed = false }
  local resumed: boolean = false
  local why = Test.raises(function()
    Poll.within(function()
      Poll.spawn(function()
        local _held <close> = closing
        local _, _ = Clock.sleep(Poll.MOST_NS)
        resumed = true
      end)
      assert(Clock.sleep(0))
      error("f failed")
    end)
  end, "f failed")
  assert(why:find("stack traceback:", 1, true) ~= nil, why)
  assert(closing.closed and not resumed, "the task f spawned was not closed where it waited")
  assert(not Poll.in_task(), "the run outlived its error")
  local value: {string} = { "no string" }
  local ok, raised: boolean, any = pcall(Poll.within, function() error(value) end)
  assert(not ok and raised == value, tostring(raised))
end

--- In a task the caller catches what `f` raised, as raised, and both it
--- and the task `f` spawned go on.
local function test_within_in_a_task_raises_what_f_raised_to_its_caller()
  local raised: string = ""
  local left_ended: boolean = false
  Poll.run(function()
    local ok, err: boolean, any = pcall(Poll.within, function()
      Poll.spawn(function()
        assert(Clock.sleep(0))
        left_ended = true
      end)
      error("f failed", 0)
    end)
    assert(not ok)
    raised = tostring(err)
  end)
  assert(raised == "f failed", raised)
  assert(left_ended, "the task f spawned did not go on")
end

--- In a task, a cancel of the caller wakes the wait `f` is in.
local function test_within_in_a_task_is_cancelled_as_its_caller_is()
  local why: string = ""
  Poll.run(function()
    local caller = Poll.spawn(function()
      Poll.within(function()
        local _, trouble = Clock.sleep(Poll.MOST_NS)
        why = words(trouble)
      end)
    end)
    assert(Clock.sleep(0))
    caller:cancel()
    assert(caller:join())
  end)
  assert(why == Poll.CANCELLED, why)
end

--- In a coroutine a task made there is a run and no task: `f` is called
--- in place, where a spawn raises, and no second run is begun.
local function test_within_in_a_coroutine_of_a_task_calls_f_where_spawn_raises()
  local message: string = ""
  Poll.run(function()
    local inner = coroutine.wrap(function()
      message = Test.raises(function()
        Poll.within(function() Poll.spawn(function() end) end)
      end, "outside a task's own coroutine")
    end)
    inner()
  end)
  assert(message ~= "")
end

local function test_clock_sleep_in_a_task_lets_the_others_run()
  local seen: mut {string} = {}
  Poll.run(function()
    local a = Poll.spawn(function()
      seen[#seen + 1] = "a1"
      assert(Clock.sleep(0))
      seen[#seen + 1] = "a2"
    end)
    local b = Poll.spawn(function()
      seen[#seen + 1] = "b1"
      assert(Clock.sleep(0))
      seen[#seen + 1] = "b2"
    end)
    assert(a:join())
    assert(b:join())
  end)
  assert(table.concat(seen, " ") == "a1 b1 a2 b2", table.concat(seen, " "))
end

--- Under a C call a task cannot yield across, Clock.sleep sleeps the
--- thread. In a killed task's `<close>` handler it raises, as
--- test_kill_raises_what_a_close_handler_raises shows.
local function test_clock_sleep_sleeps_the_thread_where_a_task_cannot_park()
  local under_c: boolean = false
  Poll.run(function()
    local order: mut {integer} = { 2, 1 }
    table.sort(order, function(x: integer, y: integer): boolean
      local slept, _ = Clock.sleep(0)
      under_c = slept
      return x < y
    end)
  end)
  assert(under_c, "a sleep under table.sort did not answer true")
end

local function test_clock_sleep_in_a_task_takes_a_span_longer_than_a_delay_does()
  local why_ended: string = ""
  Poll.run(function()
    local task = Poll.spawn(function()
      local ok, why = Clock.sleep(Poll.MOST_NS + 1)
      if not ok then why_ended = why.kind end
    end)
    assert(Clock.sleep(0))
    task:cancel()
    local _, _ = task:join()
  end)
  assert(why_ended == "cancelled", why_ended)
end
