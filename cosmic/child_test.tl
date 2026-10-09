--- The cases of cosmic.child that start nothing of this program: a
--- bare name not found, and options and streams refused before a
--- start. Those that start a child, which is this
--- program again, are in cosmic/child_lua_test.tl and cosmic/child_tool_test.tl.
---
--- The `/bin/sh` a refusal case here names is never started: its
--- option is refused before a start, and a sandboxed worker has no sh
--- to find, so a refusal that regressed fails the case either way.

local Test = require("cosmic.test")
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

--- A bare name is not looked for on PATH, and the failure says so and
--- names what finds it; a path that is not there gets no such hint.
local function test_a_bare_name_not_found_points_at_proc_find(tmp: string)
  local _, trouble = Child.run({ "cosmic-no-such-program" }, { cwd = tmp })
  assert(trouble:sub(1, 13) == "child: start:", trouble)
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

--- A start in a directory that is not there names it, whatever the
--- program; one that is there, or a file in its place, is not blamed.
local function test_a_missing_cwd_is_named(tmp: string)
  local missing = tmp .. "/not-here"
  for _, argv in ipairs({ { "ls" }, { tmp .. "/never-started" } }) do
    local started, trouble = Child.start(argv, { cwd = missing })
    assert(started == nil and trouble:sub(1, 13) == "child: start:", trouble)
    assert(trouble:find(": cwd \"" .. missing .. "\" does not exist", 1, true) ~= nil, trouble)
  end
  local _, beneath = Child.run({ "ls" }, { cwd = missing .. "/deeper" })
  assert(beneath:find("cwd \"" .. missing .. "/deeper\" does not exist", 1, true) ~= nil, beneath)
  local _, there = Child.run({ tmp .. "/never-started" }, { cwd = tmp })
  assert(there:find("cwd", 1, true) == nil, there)
  assert(Fs.write(tmp .. "/file", ""))
  local _, a_file = Child.run({ tmp .. "/never-started" }, { cwd = tmp .. "/file" })
  assert(a_file:find("does not exist", 1, true) == nil, a_file)
  local _, under_a_file = Child.run({ "ls" }, { cwd = tmp .. "/file/x" })
  assert(under_a_file:find("cwd \"" .. tmp .. "/file/x\" does not exist", 1, true) ~= nil,
    under_a_file)
end

--- A start refused for want of descriptors above the highest it hands
--- the child -- a soft RLIMIT_NOFILE just past it -- says so, naming
--- the limit, rather than a bare EINVAL.
local function test_a_start_past_the_descriptor_limit_names_it(tmp: string)
  local limits = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  if limits.hard < 256 then
    Test.skip("the descriptor limit leaves no 255 to hand on")
    return
  end
  local null = assert(sys.open("/dev/null", sys.O_RDONLY))
  assert(sys.setrlimit(sys.RLIMIT_NOFILE, 256, limits.hard))
  local ok, child, trouble = pcall(Child.start, { tmp .. "/never-started" }, { fds = { [255] = null } })
  assert(sys.setrlimit(sys.RLIMIT_NOFILE, limits.soft, limits.hard))
  sys.close(null)
  assert(ok, tostring(child))
  assert(child == nil, "started past the limit")
  assert(trouble:find("handed descriptor 255", 1, true) ~= nil and
      trouble:find("RLIMIT_NOFILE's soft limit of 256", 1, true) ~= nil, trouble)
end

--- A refused option is blamed on the line that passed it, not on a line
--- of cosmic.child: the checks under `validate` raise at their caller's
--- caller's caller.
local function test_a_refused_option_names_the_caller_s_line()
  for _, opts in ipairs({
      { stdout = "bad" } as Child.Options,
      { cwd = "/tmp\0bad" } as Child.Options,
      { cwd = "" } as Child.Options,
      { timeout_ns = -1 } as Child.Options,
  }) do
    local ok, why: boolean, any = pcall(function()
      local _, _ = Child.run({ "/bin/sh" }, opts)
    end)
    assert(not ok and tostring(why):find("child_test:", 1, true) ~= nil, tostring(why))
    assert(tostring(why):find(": child: ", 1, true) ~= nil, "names the module: " .. tostring(why))
  end
end

--- A raise names its module and says why: an empty argv, a wait for no
--- handle, and an option of no valid value.
local function test_a_raise_names_the_module()
  local raising: {function()} = {
    function() local _, _ = Child.start({}) end,
    function() local _, _ = Child.run({}) end,
    function() local _, _ = Child.wait_any({}) end,
    function() local _, _ = Child.start({ "/bin/sh" }, { capture_limit = 0 } as Child.Options) end,
    function()
      local _, _ = Child.start({ "/bin/sh" }, { env = { [""] = "x" } } as Child.Options)
    end,
    function() local _, _ = Child.start({ "/bin/sh" }, { fds = { [2] = 1 } } as Child.Options) end,
    function() local _, _ = Child.run({ "/bin/sh" }, { cwd = "" }) end,
  }
  local says = { "argv is empty", "argv is empty", "no handles to wait for", "capture_limit is out of range",
    "environment name is empty", "fds keys are child descriptors",
    "cwd is empty; leave it nil to start in this process's directory" }
  for i, call in ipairs(raising) do
    local ok, why: boolean, any = pcall(call)
    assert(not ok and tostring(why):find(": child: " .. says[i], 1, true) ~= nil,
      says[i] .. ": " .. tostring(why))
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

--- Bad IDs and namespace combinations are rejected before opening any
--- child pipes or attempting an executable.
local function test_credentials_reject_invalid_ids_and_namespace_options()
  local bad: {Child.Credentials} = {
    {}, { user = 1 }, { group = 1 }, { user = 0, group = 1 },
    { user = 1, group = 0 }, { user = -1, group = 1 },
    { user = 4294967295, group = 1 }, { user = 1, group = 4294967295 },
    { user = 1.5, group = 1 } as Child.Credentials,
  }
  for _, credentials in ipairs(bad) do
    local ok, why = pcall(Child.start, { "/never-started" }, { credentials = credentials })
    assert(not ok and tostring(why):find("credentials need integer user and group", 1, true), tostring(why))
  end
  for _, sandbox in ipairs({
      { unveil = { reads = {} } }, { offline = true }, { user = 1 }, { group = 1 },
  } as {Child.Sandbox}) do
    local ok, why = pcall(Child.start, { "/never-started" },
      { credentials = { user = 1, group = 1 }, sandbox = sandbox })
    assert(not ok and tostring(why):find("credentials exclude sandbox", 1, true), tostring(why))
  end
  local ok, why = pcall(Child.start, { "/never-started" },
    { credentials = { user = 1, group = 1 }, policy = {} })
  assert(not ok and tostring(why):find("policy and credentials exclude each other", 1, true),
    tostring(why))
end
