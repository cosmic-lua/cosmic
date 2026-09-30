--- The cases of cosmic.child waiting in a task of [`Poll.run`]: each wait
--- goes through the run, so the other tasks run while a child does.
--- Each child is this program again, past its launcher, running a Lua
--- chunk, as in cosmic/child_tool_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local type raw_process = require("cosmic.internal.process")
local this_program = require("build.this_program")

--- What the tests read: the environment, which a child inherits, and
--- the program itself (`tool`), which every child is.
Test.needs{ env = { "*" }, tool = true }

local type Searcher = function(string): any, any
local type ChildModule = require("cosmic.child")

--- cosmic.child loaded again, over a raw table whose `exit_watch` gives
--- no descriptor, as a platform without one does: its waits look for
--- each exit every few milliseconds instead.
local function without_exit_watch(): ChildModule
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      local copy: {string: any} = {}
      for name, value in pairs(extra as {string: any}) do copy[name] = value end -- cast: to copy a table by name
      copy.exit_watch = function(_pid: integer): integer, string, integer
        return nil, "no exit watch here", sys.ENOSYS
      end
      local loaded = loader as function(string, any): ChildModule -- cast: the loader the store's searcher answers
      return loaded("cosmic.child", copy as raw_process) -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child is handed no raw table")
end

--- The module with an exit watch, and one without.
local function both(): {ChildModule}
  return { Child, without_exit_watch() }
end

--- This program again, past its launcher, running the Lua chunk `chunk`.
local function lua(chunk: string, opts?: Child.Options): {string}, Child.Options
  local started = this_program.program({ "-e", chunk }, opts)
  return started.argv, started.options
end

--- A chunk's statement that sleeps `ms` milliseconds.
local function sleep(ms: integer): string
  return 'require("cosmic.time").sleep_ns(' .. tostring(ms) .. ' * 1000000) '
end

local function now_ms(): integer
  return Time.monotonic_ns() // 1000000
end

--- Runs `main` as a task beside one that ticks every 5 ms until `main`
--- returns, and answers how many times it ticked.
local function ticking(main: function()): integer
  local ticks = 0
  Poll.run(function()
    local done = false
    local ticker = Poll.spawn(function()
      while not done do
        assert(Poll.delay(5))
        ticks = ticks + 1
      end
    end)
    main()
    done = true
    assert(ticker:join())
  end)
  return ticks
end

--- A run of a child in a task lets the others run until it ends: a task
--- beside it ticks all the while, where a run that held the thread
--- would let it tick only once the child had exited. So does a run
--- whose child's exit has no descriptor, which looks for it in turn.
local function test_a_run_in_a_task_lets_the_others_run()
  for _, module in ipairs(both()) do
    local r: Child.Result
    local ticks = ticking(function()
      r = assert(module.run(lua(sleep(300) .. 'print("done")', { stdout = "capture" })))
    end)
    assert(r.ok and r.stdout == "done\n", tostring(r.stdout))
    assert(ticks >= 10, "the other task ticked " .. ticks .. " times while the child ran")
  end
end

--- A wait in a task ends at the child's exit, as it happens. Each child
--- here says when it exits, 3 ms into the wait, a slice of 10 ms not
--- yet up: a wait that looked for the exit every slice would see it some
--- 7 ms late, where one woken by the exit sees it in well under 4, at
--- least once in a few tries. A wait with a timeout ends the child at
--- it, the other task ticking meanwhile.
local function test_a_wait_in_a_task_ends_at_the_exit_or_the_timeout(tmp: string)
  local said = tmp .. "/exited"
  local soonest = math.maxinteger
  local timed: Child.Result
  local ticks: integer
  ticking(function()
    for _ = 1, 3 do
      local h <close> = assert(Child.start(lua(
        'local Fs = require("cosmic.fs") local sys = require("cosmic.sys") ' ..
        'while assert(Fs.take(0, 4096)) ~= "" do end ' ..
        'assert(Fs.write(' .. string.format("%q", said) .. ', ' ..
        'tostring(require("cosmic.time").monotonic_ns()))) sys.exit(0)', { stdin = "pipe" })))
      assert(Poll.delay(50))
      local closer = Poll.spawn(function()
        assert(Poll.delay(3))
        assert(h:close_stdin())
      end)
      assert(assert(h:wait(60000)).ok)
      local seen = Time.monotonic_ns()
      assert(closer:join())
      local late = seen - assert(math.tointeger(tonumber((assert(Fs.read(said))))))
      if late < soonest then soonest = late end
    end
  end)
  ticks = ticking(function()
    local h <close> = assert(Child.start(lua(sleep(100000))))
    timed = assert(h:wait(200))
  end)
  assert(soonest < 4 * 1000000, "a wait saw a child's exit " .. soonest // 1000 .. " us late")
  assert(timed.timed_out and timed.signal == sys.SIGTERM, tostring(timed.signal))
  assert(ticks >= 20, "the other task ticked " .. ticks .. " times")
end

--- A cancelled task's wait answers nil and CANCELLED at once, and leaves
--- the child running for its handle; a run's, having ended its child.
local function test_a_cancelled_task_s_wait_answers_cancelled(tmp: string)
  for _, module in ipairs(both()) do
    local waited, running: string, boolean
    local ran: string
    local took: integer
    Poll.run(function()
      local h <close> = assert(module.start(lua(sleep(100000))))
      local waiter = Poll.spawn(function()
        local r, why = h:wait()
        assert(r == nil)
        waited = why
      end)
      local report = tmp .. "/pid"
      local runner = Poll.spawn(function()
        local r, why = module.run(lua(
          'local Fs = require("cosmic.fs") local sys = require("cosmic.sys") ' ..
          'assert(Fs.write(' .. string.format("%q", report) .. ', tostring(sys.getpid()))) ' ..
          sleep(100000)))
        assert(r == nil)
        ran = why
      end)
      local by = now_ms() + 30000
      while not Fs.exists(report) and now_ms() < by do assert(Poll.delay(5)) end
      local started = now_ms()
      waiter:cancel()
      runner:cancel()
      assert(waiter:join(5000))
      assert(runner:join(5000))
      took = now_ms() - started
      running = assert(h:try_wait()).finished == false
      local pid = assert(math.tointeger(tonumber((assert(Fs.read(report))))))
      assert(sys.kill(pid, 0) == false, "the run left its child running")
      assert(Fs.remove(report))
    end)
    assert(waited == Poll.CANCELLED, waited)
    assert(ran == Poll.CANCELLED, ran)
    assert(running, "the cancelled wait ended its child")
    assert(took < 5000, "the cancelled waits took " .. took .. " ms")
  end
end

--- A child's streams read and written in a task let the others run:
--- a streamed stdout read to its end while the child pauses between its
--- writes, and an `input` fed through to a captured stdout.
local function test_streams_in_a_task_let_the_others_run()
  for _, module in ipairs(both()) do
    local got: {string} = {}
    local fed: Child.Result
    local input = string.rep("0123456789", 20000)
    local ticks = ticking(function()
      local h <close> = assert(module.start(lua(
        'local Fs = require("cosmic.fs") assert(Fs.put(1, "a")) ' .. sleep(200) ..
        'assert(Fs.put(1, "b"))', { stdout = "stream" })))
      local reader = assert(h.stdout_stream)
      while true do
        local chunk, why = reader:read()
        if chunk == nil then
          assert(why == "", why)
          break
        end
        got[#got + 1] = chunk
      end
      assert(assert(h:wait()).ok)
      fed = assert(module.run(lua(
        'local Fs = require("cosmic.fs") ' .. sleep(100) ..
        'while true do local s = assert(Fs.take(0, 65536)) if s == "" then break end ' ..
        'assert(Fs.put(1, s)) end', { input = input, stdout = "capture" })))
    end)
    assert(table.concat(got) == "ab", table.concat(got, "|"))
    assert(fed.ok and fed.stdout == input, "fed " .. #tostring(fed.stdout) .. " bytes back")
    assert(ticks >= 20, "the other task ticked " .. ticks .. " times")
  end
end

--- Waits for any of several handles in a task end at the first exit,
--- the other task ticking meanwhile; cancelled, they answer CANCELLED.
local function test_wait_any_in_a_task_ends_at_the_first_exit()
  local first, cancelled: integer, string
  local ticks = ticking(function()
    local slow <close> = assert(Child.start(lua(sleep(100000))))
    local quick <close> = assert(Child.start(lua(sleep(200))))
    local done = assert(Child.wait_any({ slow, quick }))
    first = done.pid == quick.pid and 1 or 2
    local waiter = Poll.spawn(function()
      local none, why = Child.wait_any({ slow })
      assert(none == nil)
      cancelled = why
    end)
    assert(Poll.delay(20))
    waiter:cancel()
    assert(waiter:join(5000))
  end)
  assert(first == 1, "the slow child ended first")
  assert(cancelled == Poll.CANCELLED, cancelled)
  assert(ticks >= 20, "the other task ticked " .. ticks .. " times")
end

--- A signal a guard catches ends a run waiting in a task at once, as it
--- does out of one: the run answers "cancelled by signal N" and leaves
--- the signal to the guard open around it. The guards live in a nested
--- cosmic, where the signal is sent; a task there ticks meanwhile.
local function test_a_signal_ends_a_run_in_a_task(tmp: string)
  local report = tmp .. "/report"
  local started = this_program.program({ "-e", [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
local this_program = require("build.this_program")
local outer = assert(Child.guard())
local answer = ""
local ticks = 0
local took = 0
Poll.run(function()
  local runner = Poll.spawn(function()
    local sleeper = this_program.program({ "-e", 'require("cosmic.time").sleep_ns(100000 * 1000000)' })
    local r, why = Child.run(sleeper.argv, sleeper.options)
    answer = tostring(r) .. " " .. why
  end)
  local ticker = Poll.spawn(function()
    while answer == "" do
      assert(Poll.delay(5))
      ticks = ticks + 1
    end
  end)
  assert(Poll.delay(200))
  local sent = Time.monotonic_ns()
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  assert(runner:join(30000))
  took = (Time.monotonic_ns() - sent) // 1000000
  assert(ticker:join())
end)
local kept = assert(outer:release())
assert(Fs.write(..., answer .. "|" .. tostring(kept) .. "|" ..
  tostring(ticks >= 20) .. "|" .. tostring(took < 5000)))
]], report }, { stderr = "capture", timeout_ms = 60000 })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
    " " .. tostring(r.stderr))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == "nil cancelled by signal " .. term .. "|" .. term .. "|true|true", tostring(got))
end
