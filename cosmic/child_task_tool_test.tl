--- The cases of cosmic.child waiting in a task of [`Poll.run`]: each wait
--- goes through the run, so the other tasks run while a child does.
--- Each child is this program again, past its launcher, running a Lua
--- chunk, as in cosmic/child_tool_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local this_program = require("build.this_program")

--- What the tests read: the environment, which a child inherits, and
--- What the tests read: the environment, which a child inherits, the
--- program itself, which every child is, started only to run a chunk
--- (`lua`), and /proc, for the signal dispositions a run restores.
Test.needs{ env = { "*" }, lua = true, host = { "/proc" } }

local type Searcher = function(string): any, any
local type ChildModule = require("cosmic.child")

--- cosmic.child loaded again, over a copy of the raw table it is handed
--- that `alter` changes: the copy keeps the core's own functions until
--- `alter` replaces one.
local function reloaded(alter: function({string: any})): ChildModule
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      local copy: {string: any} = {}
      for name, value in pairs(extra as {string: any}) do copy[name] = value end -- cast: to copy a table by name
      alter(copy)
      local loaded = loader as function(string, any): ChildModule -- cast: the loader the store's searcher answers
      return loaded("cosmic.child", copy as raw_process) -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child is handed no raw table")
end

--- cosmic.child loaded again, over a raw table whose `exit_watch` gives
--- no descriptor, as a platform without one does: its waits look for
--- each exit every few milliseconds instead.
local function without_exit_watch(): ChildModule
  return reloaded(function(copy: {string: any})
    copy.exit_watch = function(_pid: integer): integer, string, integer
      return nil, "no exit watch here", sys.ENOSYS
    end
  end)
end

--- The module with an exit watch, and one without. Each is used after
--- the other, never at once: each copy's `collect` reaps every child
--- this process adopts, and would take a status the other's handle
--- waits for from under it.
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
  return 'require("cosmic.clock").sleep_ns(require("cosmic.clock").ms(' .. tostring(ms) .. ')) '
end

--- Runs `main` as a task beside one that ticks every 5 ms until `main`
--- returns, and answers how many times it ticked. A wait that held the
--- thread lets it tick once at most, so two ticks show the wait yielded,
--- however a loaded host stretches the 5 ms.
local function ticking(main: function()): integer
  local ticks = 0
  Poll.run(function()
    local done = false
    local ticker = Poll.spawn(function()
      while not done do
        assert(Poll.delay(Clock.ms(5)))
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
    assert(ticks >= 2, "the other task ticked " .. ticks .. " times while the child ran")
  end
end

--- A wait in a task whose child has an exit watch waits on the watch
--- alone, with no slice to look for the exit by, and ends once the watch
--- is readable. The watch here is a pipe this test writes to, standing
--- in for the core's, which core/syscalls_tool_test.tl holds readable at
--- the exit: the child exits -- the core's own watch, opened beside it,
--- says so -- and the wait goes on through several slices of a wait
--- that looked, until the pipe is written. How soon after a child's last
--- act the core's watch is readable is the kernel's to say -- the
--- child's teardown and, on a busy host, its scheduling come first -- and
--- is not measured here: a whole suite run on a macOS runner has taken
--- some 6 ms over it.
local function test_a_wait_in_a_task_is_woken_by_its_exit_watch()
  local ends: raw_process.Pipe
  local watch: function(integer): integer, string, integer
  local module = reloaded(function(copy: {string: any})
    local pipe = copy.pipe as function(): raw_process.Pipe, string, integer -- cast: the raw table's `pipe`
    watch = copy.exit_watch as function(integer): integer, string, integer -- cast: the raw table's `exit_watch`
    ends = assert(pipe())
    copy.exit_watch = function(_pid: integer): integer, string, integer
      return ends.reader, "", 0
    end
  end)
  local waited: Child.Result
  local early = false
  Poll.run(function()
    -- Not grouped: a grouped start makes an adopting process, whose waits
    -- wake every second to reap orphans, and so look.
    local h <close> = assert(module.start(lua(
      'local Fs = require("cosmic.fs") while assert(Fs.take(0, 4096)) ~= "" do end',
      { stdin = "stream", process_group = false })))
    local exited = assert(watch(h.pid))
    local waiter = Poll.spawn(function()
      waited = assert(h:wait())
    end)
    -- The waiter runs first: it finds the child running, and waits.
    assert(Poll.delay(Clock.ms(1)))
    assert(assert(h.stdin_stream):close())
    assert(Poll.readable(exited, Clock.seconds(30)))
    assert(Poll.delay(Clock.ms(50)))
    -- A wait that ended has closed the pipe's other end.
    early = waited ~= nil
    if not early then assert(sys.write(ends.writer, "x")) end
    assert(waiter:join(Clock.seconds(30)))
    assert(sys.close(exited))
    assert(sys.close(ends.writer))
  end)
  assert(not early, "a wait with an exit watch found its child's exit without it")
  assert(waited.ok, tostring(waited.code))
end

--- Every child cosmic.child starts here has the core's exit watch: a
--- platform that has one gives it, rather than leaving the waits to
--- look for each exit in turn. Each child runs until its stdin closes,
--- so it is alive when the watch is asked for: a watch asked for after
--- a child has exited may be refused (ESRCH, on Darwin, where a kqueue
--- cannot watch an exited child), which the next test holds apart.
local function test_every_child_started_here_has_an_exit_watch()
  local given, refused = 0, ""
  local module = reloaded(function(copy: {string: any})
    local watch = copy.exit_watch as function(integer): integer, string, integer -- cast: the raw table's `exit_watch`
    copy.exit_watch = function(pid: integer): integer, string, integer
      local fd, why, errno = watch(pid)
      if fd ~= nil then given = given + 1 else refused = why end
      return fd, why, errno
    end
  end)
  Poll.run(function()
    for _ = 1, 3 do
      local h <close> = assert(module.start(lua(
        'local Fs = require("cosmic.fs") while assert(Fs.take(0, 4096)) ~= "" do end',
        { stdin = "stream", process_group = false })))
      assert(assert(h.stdin_stream):close())
      assert(assert(h:wait()).ok)
    end
  end)
  assert(given == 3, "an exit watch was given for " .. given .. " of 3 children: " .. refused)
end

--- A child that has exited by the time its watch is asked for is waited
--- for as any other: a `run` or a `wait` answers its status, whether the
--- watch was refused, as a Darwin kqueue refuses one (ESRCH, "No such
--- process"), or not given at all. Here the watch is asked for after the
--- core's own, opened beside it, says the child has exited, and then
--- refused, which is what a child that exits at once meets on Darwin
--- when it wins the race against the start; `lua("")` is such a child.
local function test_a_child_that_exited_before_its_watch_was_asked_for_is_waited_for()
  local asked = 0
  local module = reloaded(function(copy: {string: any})
    local watch = copy.exit_watch as function(integer): integer, string, integer -- cast: the raw table's `exit_watch`
    copy.exit_watch = function(pid: integer): integer, string, integer
      asked = asked + 1
      local fd, _, _ = watch(pid)
      if fd ~= nil then
        assert(assert(sys.poll({ fd }, { sys.POLLIN }, 30000))[1] & sys.POLLIN ~= 0,
          "the child did not exit")
        assert(sys.close(fd))
      end
      return nil, "No such process", sys.ESRCH
    end
  end)
  Poll.run(function()
    for _ = 1, 3 do
      local r = assert(module.run(lua('require("cosmic.proc").exit(3)')))
      assert(not r.ok and r.code == 3, tostring(r.code))
    end
    local h <close> = assert(module.start(lua("")))
    assert(assert(h:wait(Clock.seconds(30))).ok)
  end)
  assert(asked == 4, "an exit watch was asked for " .. asked .. " times, not 4")
end

--- A wait with a timeout ends the child at it, the other task ticking
--- meanwhile.
local function test_a_wait_in_a_task_ends_its_child_at_the_timeout()
  local timed: Child.Result
  local ticks = ticking(function()
    local h <close> = assert(Child.start(lua(sleep(100000))))
    timed = assert(h:wait(Clock.ms(200)))
  end)
  assert(timed.timed_out and timed.signal == sys.SIGTERM, tostring(timed.signal))
  assert(ticks >= 2, "the other task ticked " .. ticks .. " times")
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
      local by = Clock.monotonic_ns() + Clock.seconds(30)
      while not Fs.exists(report) and Clock.monotonic_ns() < by do
        assert(Poll.delay(Clock.ms(5)))
      end
      local started = Clock.monotonic_ns()
      waiter:cancel()
      runner:cancel()
      assert(waiter:join(Clock.seconds(5)))
      assert(runner:join(Clock.seconds(5)))
      took = Clock.monotonic_ns() - started
      running = assert(h:try_wait()).finished == false
      local pid = assert(math.tointeger(tonumber((assert(Fs.read(report))))))
      assert(sys.kill(pid, 0) == false, "the run left its child running")
      assert(Fs.remove(report))
    end)
    assert(waited == Poll.CANCELLED, waited)
    assert(ran == Poll.CANCELLED, ran)
    assert(running, "the cancelled wait ended its child")
    assert(took < Clock.seconds(5), "the cancelled waits took " .. took // Clock.ms(1) .. " ms")
  end
end

--- A child that holds SIGTERM, and so outlasts it, once it has said
--- its pid in `report`.
local function holding_term(report: string): string
  return 'local Fs = require("cosmic.fs") local sys = require("cosmic.sys") ' ..
    'local _guard = assert(require("cosmic.child").guard()) ' ..
    'assert(Fs.write(' .. string.format("%q", report) .. ', tostring(sys.getpid()))) ' ..
    'while true do ' .. sleep(1000) .. 'end'
end

--- The pid a child wrote to `report`, once it has, which is taken away.
local function reported_pid(report: string): integer
  local by = Clock.monotonic_ns() + Clock.seconds(30)
  while not Fs.exists(report) and Clock.monotonic_ns() < by do assert(Poll.delay(Clock.ms(5))) end
  local pid = assert(math.tointeger(tonumber((assert(Fs.read(report))))))
  assert(Fs.remove(report))
  return pid
end

--- A cancelled task's run ends a child that outlasts SIGTERM through
--- the run: the other tasks run through the grace it gives the child
--- and the wait for its SIGKILL. A kill still ends a task whose cleanup
--- so waits, its handle's close ending the child.
local function test_a_cancelled_run_ends_its_child_through_the_run(tmp: string)
  local report = tmp .. "/pid"
  for _, module in ipairs(both()) do
    local ran, waited: string, string
    local during = 0
    local run_pid, killed_pid: integer, integer
    local killed_answer: string
    Poll.run(function()
      local ticks, done = 0, false
      local ticker = Poll.spawn(function()
        while not done do
          assert(Poll.delay(Clock.ms(5)))
          ticks = ticks + 1
        end
      end)
      local runner = Poll.spawn(function()
        local r, why = module.run(lua(holding_term(report)))
        assert(r == nil)
        ran = why
      end)
      run_pid = reported_pid(report)
      local before = ticks
      runner:cancel()
      assert(runner:join(Clock.seconds(5)))
      during = ticks - before
      local victim = Poll.spawn(function()
        local h <close> = assert(module.start(lua(holding_term(report))))
        local r, why = h:wait()
        assert(r == nil)
        waited = why
        local _, _ = h:close()
      end)
      killed_pid = reported_pid(report)
      victim:cancel()
      assert(Poll.delay(Clock.ms(50)))
      victim:kill()
      local _, why = victim:join()
      killed_answer = why
      done = true
      assert(ticker:join())
    end)
    assert(ran == Poll.CANCELLED, ran)
    assert(during >= 10, "the other task ticked " .. during .. " times while the run ended its child")
    assert(sys.kill(run_pid, 0) == false, "the run left its child running")
    assert(waited == Poll.CANCELLED, waited)
    assert(killed_answer == Poll.CANCELLED, killed_answer)
    assert(sys.kill(killed_pid, 0) == false, "the killed task left its child running")
  end
end

--- A child that holds SIGTERM is ended by the SIGKILL that follows the
--- grace period, whether a timed wait or a close ends it: the Result
--- says it timed out and the child is gone. The upper bounds are loose:
--- they catch an end far past the grace and the reap, not a slow host.
local function test_a_child_that_holds_sigterm_is_ended_within_the_deadline(tmp: string)
  local report = tmp .. "/held"
  for _, module in ipairs(both()) do
    local h = assert(module.start(lua(holding_term(report))))
    local by = Clock.monotonic_ns() + Clock.seconds(30)
    while not Fs.exists(report) and Clock.monotonic_ns() < by do Clock.sleep_ns(Clock.ms(5)) end
    local pid = assert(math.tointeger(tonumber((assert(Fs.read(report))))))
    assert(Fs.remove(report))
    local started = Clock.monotonic_ns()
    local r = assert(h:wait(Clock.ms(100)))
    local took = Clock.monotonic_ns() - started
    assert(r.timed_out and not r.ok and r.signal == sys.SIGKILL, tostring(r.signal))
    assert(took >= Clock.ms(300) and took < Clock.seconds(8), "ended after " .. took // Clock.ms(1) .. " ms")
    assert(sys.kill(pid, 0) == false, "the child outlived its wait")
    local closing = assert(module.start(lua(holding_term(report))))
    by = Clock.monotonic_ns() + Clock.seconds(30)
    while not Fs.exists(report) and Clock.monotonic_ns() < by do Clock.sleep_ns(Clock.ms(5)) end
    local closing_pid = assert(math.tointeger(tonumber((assert(Fs.read(report))))))
    assert(Fs.remove(report))
    started = Clock.monotonic_ns()
    assert(closing:close())
    took = Clock.monotonic_ns() - started
    assert(took < Clock.seconds(8), "closed after " .. took // Clock.ms(1) .. " ms")
    assert(sys.kill(closing_pid, 0) == false, "the child outlived its close")
  end
end

--- A raise in the ending of a run -- here the run's own poll, which
--- fails once the child has said its pid, first in the run's wait and
--- then in the ending its handle's close makes -- leaves no process
--- behind: the child holds SIGTERM, so only the SIGKILL the ending falls
--- back on ends it, before any collection of the handle.
local function test_a_raise_while_ending_a_run_still_kills_the_child(tmp: string)
  local report = tmp .. "/raised"
  local poll = sys.poll
  local raised = false
  sys.poll = function(fds: {integer}, events: {integer}, ms: integer): {integer} | nil, string, integer
    if Fs.exists(report) then
      raised = true
      error("poll refused", 0)
    end
    -- Short slices, so a poll begun before the report looks again soon.
    if ms < 0 or ms > 10 then ms = 10 end
    return poll(fds, events, ms)
  end
  -- The timeout only bounds a run that never raises: one that fired
  -- first would end the child before it holds SIGTERM, which fails the
  -- assertions below.
  local argv, options = lua(holding_term(report), { timeout_ns = Clock.seconds(8) })
  local ok, trouble: boolean, any = pcall(Child.run, argv, options)
  sys.poll = poll
  assert(raised and not ok and tostring(trouble):find("poll refused", 1, true) ~= nil,
    tostring(trouble))
  local pid = assert(math.tointeger(tonumber((assert(Fs.read(report))))))
  assert(sys.kill(pid, 0) == false, "the child outlived the raise")
end

--- The signals this process catches, as Linux's /proc says; nil
--- elsewhere.
local function caught_signals(): string | nil
  local status, _ = Fs.read("/proc/self/status")
  if status == nil then return nil end
  return status:match("SigCgt:%s*(%x+)")
end

--- A task killed in its run's cleanup -- cancelled, then killed while
--- the run ends a child that outlasts SIGTERM -- still ends the child,
--- and gives back the signals the run's guard held.
local function test_a_run_killed_in_its_cleanup_ends_its_child_and_guard(tmp: string)
  local report = tmp .. "/pid"
  local before = caught_signals()
  local pid: integer
  local answer: string
  Poll.run(function()
    local victim = Poll.spawn(function()
      local _, _ = Child.run(lua(holding_term(report)))
    end)
    pid = reported_pid(report)
    victim:cancel()
    assert(Poll.delay(Clock.ms(50)))
    victim:kill()
    local _, why = victim:join()
    answer = why
  end)
  assert(answer == Poll.CANCELLED, answer)
  assert(sys.kill(pid, 0) == false, "the killed run left its child running")
  local after = caught_signals()
  assert(after == before, "caught " .. tostring(before) .. " before the run, " ..
      tostring(after) .. " after")
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
    assert(ticks >= 2, "the other task ticked " .. ticks .. " times")
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
    assert(Poll.delay(Clock.ms(20)))
    waiter:cancel()
    assert(waiter:join(Clock.seconds(5)))
  end)
  assert(first == 1, "the slow child ended first")
  assert(cancelled == Poll.CANCELLED, cancelled)
  assert(ticks >= 2, "the other task ticked " .. ticks .. " times")
end

--- A signal a guard catches ends a run waiting in a task at once, as it
--- does out of one: the run answers "cancelled by signal N" and leaves
--- the signal to the guard open around it. The guards live in a nested
--- cosmic, where the signal is sent; a task there ticks meanwhile.
local function test_a_signal_ends_a_run_in_a_task(tmp: string)
  local report = tmp .. "/report"
  local started = this_program.program({ "-e", [[
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local outer = assert(Child.guard())
local answer = ""
local ticks = 0
local took = 0
Poll.run(function()
  local runner = Poll.spawn(function()
    local sleeper = this_program.program({ "-e", 'require("cosmic.clock").sleep_ns(require("cosmic.clock").seconds(100000))' })
    local r, why = Child.run(sleeper.argv, sleeper.options)
    answer = tostring(r) .. " " .. why
  end)
  local ticker = Poll.spawn(function()
    while answer == "" do
      assert(Poll.delay(Clock.ms(5)))
      ticks = ticks + 1
    end
  end)
  assert(Poll.delay(Clock.ms(200)))
  local sent = Clock.monotonic_ns()
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  assert(runner:join(Clock.seconds(30)))
  took = Clock.monotonic_ns() - sent
  assert(ticker:join())
end)
local kept = assert(outer:release())
assert(Fs.write(..., answer .. "|" .. tostring(kept) .. "|" ..
  tostring(ticks >= 2) .. "|" .. tostring(took < Clock.seconds(5))))
]], report }, { stderr = "capture", timeout_ns = Clock.seconds(60) })
  local r = assert(Child.run(started.argv, started.options))
  assert(r.ok, "code=" .. tostring(r.code) .. " signal=" .. tostring(r.signal) ..
      " " .. tostring(r.stderr))
  local term = tostring(sys.SIGTERM)
  local got = Fs.read(report)
  assert(got == "nil child: cancelled by signal " .. term .. "|" .. term .. "|true|true", tostring(got))
end

--- A stdin stream's write waiting in a task for room fails once another
--- task closes the stream, and writes nothing to the descriptor that
--- takes its number next.
local function test_a_write_whose_stream_closes_meanwhile_writes_nothing_else(tmp: string)
  local victim = tmp .. "/victim"
  local wrote, why: boolean, string
  Poll.run(function()
    -- The child outlives the write, and its handle's close ends it: one
    -- that exited first would fail the write with EPIPE instead.
    local h <close> = assert(Child.start(lua(sleep(100000), { stdin = "stream" })))
    local stream = assert(h.stdin_stream)
    local writer = Poll.spawn(function()
      wrote, why = stream:write(string.rep("x", 1 << 20))
    end)
    assert(Poll.delay(Clock.ms(50)))
    assert(stream:close())
    local fd = assert(Fs.open_write(victim))
    assert(writer:join(Clock.seconds(5)))
    assert(Fs.close(fd))
  end)
  assert(not wrote and why == "child: the writer is closed", tostring(why))
  assert(assert(Fs.read(victim)) == "", "the write went on into another file")
end

--- Waits in a task until `h`'s child has exited, without claiming its
--- status: on its exit watch, or, for a child with none (a Linux without
--- pidfd_open, or Darwin's kqueue refusing a child that has already
--- exited, ESRCH), until /proc shows it a zombie, where there is a /proc.
local function exited_unreaped(h: Child.Handle)
  if h._exit_fd >= 0 then
    -- TODO: on Darwin the watch may be readable a moment before waitpid
    -- can reap the child (core/syscalls.c's `exit_watch` TODO), and a
    -- `try_wait` then finds it running; once that is settled, this wait
    -- is exact there too.
    assert(Poll.readable(h._exit_fd, Clock.seconds(8)))
    return
  end
  local stat_path = "/proc/" .. tostring(h.pid) .. "/stat"
  local by = Clock.monotonic_ns() + Clock.seconds(8)
  while true do
    local stat, _ = Fs.read(stat_path)
    if stat == nil or stat:match("^%d+ %b() Z") ~= nil then return end
    assert(Clock.monotonic_ns() < by, "the child did not exit")
    assert(Poll.delay(Clock.ms(10)))
  end
end

--- Two tasks settling one child at once answer the same Result: whether
--- both ask `try_wait`, or one waits while the other closes.
local function test_two_tasks_settle_one_child_once()
  local answers: {Child.Result} = {}
  local closed: boolean
  Poll.run(function()
    local h <close> = assert(Child.start(lua("return 3")))
    assert(assert(h:wait(Clock.seconds(30))).code == 3)
    local again <close> = assert(Child.start(lua("return 4")))
    -- Exited, its status unclaimed: so both `try_wait`s find it finished.
    exited_unreaped(again)
    local tasks: {Poll.Task} = {}
    for i = 1, 2 do
      tasks[i] = Poll.spawn(function()
        local t = assert(again:try_wait())
        assert(t.finished)
        answers[i] = t.result
      end)
    end
    for _, task in ipairs(tasks) do assert(task:join()) end
    local third <close> = assert(Child.start(lua(sleep(100))))
    local waiter = Poll.spawn(function() answers[3] = assert(third:wait()) end)
    local closer = Poll.spawn(function() closed = third:close() end)
    assert(waiter:join())
    assert(closer:join())
    answers[4] = assert(third:wait())
  end)
  assert(rawequal(answers[1], answers[2]) and answers[1].code == 4, "try_wait settled twice")
  assert(closed, "the close failed")
  assert(rawequal(answers[3], answers[4]), "a wait and a close settled twice")
end
