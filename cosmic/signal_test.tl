--- The cases of cosmic.signal's guard that start nothing: each sends
--- its signals to this process and releases every guard it opens, so
--- none is delivered again. Those whose guard closes on a signal, which
--- ends the process holding it, are in cosmic/signal_tool_test.tl.

local Signal = require("cosmic.signal")
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")

--- Guards nest, and each closes once: a guard opened inside another
--- is taken, and every guard closed, the next one taken afresh.
local function test_guards_nest_and_each_closes_once()
  local outer = assert(Signal.guard())
  local inner = assert(Signal.guard())
  assert(inner:cancelled() == 0)
  assert(inner:close())
  assert(inner:close())
  assert(outer:cancelled() == 0)
  assert(outer:close())
  assert(outer:close())
  assert(outer:cancelled() == 0)
  local again = assert(Signal.guard())
  assert(again:close())
end

--- What an inner guard sees and takes, the outer still sees and takes;
--- the inner's close, with the outer open, delivers nothing; and a
--- guard opened after the signal sees none of it. The signals are this
--- process's own, and every guard is released, so none is delivered
--- again.
local function test_an_outer_guard_sees_what_an_inner_one_took()
  local outer = assert(Signal.guard())
  local inner = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  assert(inner:take() == sys.SIGTERM)
  assert(inner:take() == 0)
  assert(inner:close())
  assert(inner:cancelled() == sys.SIGTERM)
  local late = assert(Signal.guard())
  assert(late:cancelled() == 0, "a guard opened after the signal saw it")
  assert(late:release() == 0)
  assert(outer:take() == sys.SIGTERM)
  assert(outer:release() == sys.SIGTERM)
end

--- A guard's wait takes the next signal while the run's other tasks go
--- on, however many tasks wait on it and another guard at once: each
--- wakes, and neither takes the other's. With none to take, a wait
--- ends at its timeout; outside a task it raises.
local function test_guard_wait_takes_a_signal_in_a_task()
  local outer = assert(Signal.guard())
  local inner = assert(Signal.guard())
  local got: {string} = {}
  Poll.run(function()
    local function waiter(g: Signal.Guard, name: string): Poll.Task
      return Poll.spawn(function()
        local signal, why = g:wait(Clock.seconds(5))
        got[#got + 1] = name .. "=" .. tostring(signal) .. why
      end)
    end
    local a = waiter(outer, "outer")
    local b = waiter(inner, "inner")
    assert(Poll.delay(Clock.ms(10)))
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    assert(a:join())
    assert(b:join())
    local signal, why = inner:wait(Clock.ms(10))
    got[#got + 1] = tostring(signal) .. " " .. why
  end)
  table.sort(got)
  local term = tostring(sys.SIGTERM)
  assert(table.concat(got, ",") == "0 " .. Poll.TIMEOUT .. ",inner=" .. term .. ",outer=" .. term,
    table.concat(got, ","))
  local ok, raised = pcall(outer.wait, outer)
  assert(not ok and tostring(raised):find("in a task of Poll.run", 1, true), tostring(raised))
  assert(inner:release() == sys.SIGTERM)
  assert(outer:release() == sys.SIGTERM)
end

--- A guard's wait ends once that guard closes, though another stays
--- open; a wait on the one still open waits on.
local function test_a_guard_s_wait_ends_when_it_closes_under_another()
  local outer = assert(Signal.guard())
  local inner = assert(Signal.guard())
  local got: {string} = {}
  Poll.run(function()
    local on_inner = Poll.spawn(function()
      local signal, why = inner:wait(Clock.seconds(5))
      got[#got + 1] = "inner=" .. tostring(signal) .. " " .. why
    end)
    local on_outer = Poll.spawn(function()
      local signal, why = outer:wait(Clock.ms(100))
      got[#got + 1] = "outer=" .. tostring(signal) .. " " .. why
    end)
    assert(Poll.delay(Clock.ms(10)))
    assert(inner:close())
    assert(on_inner:join())
    assert(on_outer:join())
  end)
  assert(table.concat(got, ",") == "inner=0 signal: the guard is closed,outer=0 " .. Poll.TIMEOUT,
    table.concat(got, ","))
  assert(outer:release() == 0)
end

local function test_guard_release_with_nothing_caught_answers_zero()
  local guard = assert(Signal.guard())
  local caught, trouble = guard:release()
  assert(caught == 0 and trouble == "", tostring(caught) .. " " .. trouble)
  assert(guard:release() == 0)
  assert(guard:close())
  local again = assert(Signal.guard())
  assert(again:close())
end
