--- The cases of cosmic.child that start nothing of this program: a
--- bare name not found, options and streams refused before a start,
--- and the signal guard. Those that start a child, which is this
--- program again, are in cosmic/child_tool_test.tl.
---
--- The `/bin/sh` a refusal case here names is never started: its
--- option is refused before a start, and a sandboxed worker has no sh
--- to find, so a refusal that regressed fails the case either way.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
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

local function test_guard_is_one_at_a_time_and_closes_once()
  local guard = assert(Child.guard())
  local second, trouble = Child.guard()
  assert(second == nil and trouble ~= "")
  local r, run_trouble = Child.run({ "/bin/sh", "-c", "exit 0" })
  assert(r == nil and run_trouble:find("signal guard: ", 1, true), run_trouble)
  assert(guard:cancelled() == 0)
  assert(guard:close())
  assert(guard:close())
  assert(guard:cancelled() == 0)
  local again = assert(Child.guard())
  assert(again:close())
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
