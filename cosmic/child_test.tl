--- The cases of cosmic.child that start nothing of this program: a
--- bare name not found, options and streams refused before a start,
--- and the signal guard. Those that start a child, which is this
--- program again, are in cosmic/child_lua_test.tl and cosmic/child_tool_test.tl.
---
--- The `/bin/sh` a refusal case here names is never started: its
--- option is refused before a start, and a sandboxed worker has no sh
--- to find, so a refusal that regressed fails the case either way.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local sys = require("cosmic.sys")

--- A bare name is not looked for on PATH, and the failure says so and
--- names what finds it; a path that is not there gets no such hint.
local function test_a_bare_name_not_found_points_at_proc_find(tmp: string)
  local _, trouble = Child.run({ "cosmic-no-such-program" }, { cwd = tmp })
  assert(trouble:find("with no PATH search; " ..
    "Proc.find(\"cosmic-no-such-program\") answers", 1, true) ~= nil, trouble)
  local _, pathed = Child.run({ tmp .. "/cosmic-no-such-program" })
  assert(pathed:find("Proc.find(", 1, true) == nil, pathed)
  -- A missing directory, or a script whose interpreter is missing, fails
  -- with the same ENOENT; the name is not what is missing there.
  local _, no_dir = Child.run({ "ls" }, { cwd = tmp .. "/not-here" })
  assert(no_dir:find("Proc.find(", 1, true) == nil, no_dir)
  assert(Fs.write(tmp .. "/script", "#!/cosmic/no/such/interpreter\n"))
  assert(sys.chmod(tmp .. "/script", 0x1c0))
  local _, script = Child.run({ "script" }, { cwd = tmp })
  assert(script ~= "" and script:find("Proc.find(", 1, true) == nil, script)
  local _, empty = Child.run({ "" }, { cwd = tmp })
  assert(empty:find("Proc.find(", 1, true) == nil, empty)
end

--- A refused option is blamed on the line that passed it, not on a line
--- of cosmic.child: the checks under `validate` raise at their caller's
--- caller's caller.
local function test_a_refused_option_names_the_caller_s_line()
  for _, opts in ipairs({
    { stdout = "bad" } as Child.Options,
    { cwd = "/tmp\0bad" } as Child.Options,
    { timeout_ms = -1 } as Child.Options,
  }) do
    local ok, why: boolean, any = pcall(function()
      local _, _ = Child.run({ "/bin/sh" }, opts)
    end)
    assert(not ok and tostring(why):find("child_test:", 1, true) ~= nil, tostring(why))
  end
end

local function test_run_refuses_a_stream()
  for _, opts in ipairs({
    { stdin = "stream" }, { stdout = "stream" }, { stderr = "stream" },
  } as {Child.Options}) do
    local ok, message = pcall(Child.run, { "/bin/sh", "-c", "exit 0" }, opts)
    assert(not ok and tostring(message):find("Child.start", 1, true), tostring(message))
  end
  assert(not pcall(Child.start, { "/bin/sh" }, { stdin = "stream", input = "x" } as Child.Options))
end

local function test_options_are_validated()
  assert(not pcall(Child.start, { "/bin/sh" }, { stdin = "capture" } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { stdout = "stdout" } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { stdin = "null", input = "x" } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { fds = { [2] = 1 } } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { fds = { [256] = 1 } } as Child.Options))
  assert(not pcall(Child.start, { "/bin/sh" }, { capture_limit = 0 } as Child.Options))
end

--- Guards nest, and each closes once: a guard opened inside another
--- is taken, and every guard closed, the next one taken afresh.
local function test_guards_nest_and_each_closes_once()
  local outer = assert(Child.guard())
  local inner = assert(Child.guard())
  assert(inner:cancelled() == 0)
  assert(inner:close())
  assert(inner:close())
  assert(outer:cancelled() == 0)
  assert(outer:close())
  assert(outer:close())
  assert(outer:cancelled() == 0)
  local again = assert(Child.guard())
  assert(again:close())
end

--- What an inner guard sees and takes, the outer still sees and takes;
--- the inner's close, with the outer open, delivers nothing; and a
--- guard opened after the signal sees none of it. The signals are this
--- process's own, and every guard is released, so none is delivered
--- again.
local function test_an_outer_guard_sees_what_an_inner_one_took()
  local outer = assert(Child.guard())
  local inner = assert(Child.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  assert(inner:take() == sys.SIGTERM)
  assert(inner:take() == 0)
  assert(inner:close())
  assert(inner:cancelled() == sys.SIGTERM)
  local late = assert(Child.guard())
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
  local outer = assert(Child.guard())
  local inner = assert(Child.guard())
  local got: {string} = {}
  Poll.run(function()
    local function waiter(g: Child.Guard, name: string): Poll.Task
      return Poll.spawn(function()
        local signal, why = g:wait(5000)
        got[#got + 1] = name .. "=" .. tostring(signal) .. why
      end)
    end
    local a = waiter(outer, "outer")
    local b = waiter(inner, "inner")
    assert(Poll.delay(10))
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    assert(a:join())
    assert(b:join())
    local signal, why = inner:wait(10)
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
  local outer = assert(Child.guard())
  local inner = assert(Child.guard())
  local got: {string} = {}
  Poll.run(function()
    local on_inner = Poll.spawn(function()
      local signal, why = inner:wait(5000)
      got[#got + 1] = "inner=" .. tostring(signal) .. " " .. why
    end)
    local on_outer = Poll.spawn(function()
      local signal, why = outer:wait(100)
      got[#got + 1] = "outer=" .. tostring(signal) .. " " .. why
    end)
    assert(Poll.delay(10))
    assert(inner:close())
    assert(on_inner:join())
    assert(on_outer:join())
  end)
  assert(table.concat(got, ",") == "inner=0 the guard is closed,outer=0 " .. Poll.TIMEOUT,
    table.concat(got, ","))
  assert(outer:release() == 0)
end

local function test_guard_release_with_nothing_caught_answers_zero()
  local guard = assert(Child.guard())
  local caught, trouble = guard:release()
  assert(caught == 0 and trouble == "", tostring(caught) .. " " .. trouble)
  assert(guard:release() == 0)
  assert(guard:close())
  local again = assert(Child.guard())
  assert(again:close())
end
