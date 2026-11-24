--- The cases of cosmic.child that start nothing of this program: a
--- bare name not found, and options and streams refused before a
--- start. Those that start a child, which is this
--- program again, are in cosmic/child_lua_test.tl and cosmic/child_tool_test.tl.
---
--- The `/bin/sh` a refusal case here names is never started: its
--- option is refused before a start, and a sandboxed worker has no sh
--- to find, so a refusal that regressed fails the case either way.

local Array = require("cosmic.array")
local Test = require("cosmic.test")
local Child = require("cosmic.child")
local TypeWatch = require("build.type_watch")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

--- A bare name is not looked for on PATH, and the failure says so and
--- names what finds it; a path that is not there gets no such hint.
local function test_a_bare_name_not_found_points_at_proc_find(tmp: string)
  local _, trouble = Child.run({ "cosmic-no-such-program" }, { timeout_ns = Child.FOREVER, cwd = tmp })
  assert(assert(trouble).message:sub(1, 13) == "child: start:", trouble)
  assert(assert(trouble).message:find("with no PATH search; " ..
      "Proc.find(\"cosmic-no-such-program\") answers", 1, true) ~= nil, trouble)
  local _, pathed = Child.run({ tmp .. "/cosmic-no-such-program" }, { timeout_ns = Child.FOREVER })
  assert(assert(pathed).message:find("Proc.find(", 1, true) == nil, pathed)
  -- A missing directory, or a script whose interpreter is missing, fails
  -- with the same ENOENT; the name is not what is missing there.
  local _, no_dir = Child.run({ "ls" }, { timeout_ns = Child.FOREVER, cwd = tmp .. "/not-here" })
  assert(assert(no_dir).message:find("Proc.find(", 1, true) == nil, no_dir)
  assert(Fs.write(tmp .. "/script", "#!/cosmic/no/such/interpreter\n"))
  assert(sys.chmod(tmp .. "/script", 0x1c0))
  local _, script = Child.run({ "script" }, { timeout_ns = Child.FOREVER, cwd = tmp })
  assert(script ~= nil and script.message ~= "" and script.message:find("Proc.find(", 1, true) == nil, script)
  local _, empty = Child.run({ "" }, { timeout_ns = Child.FOREVER, cwd = tmp })
  assert(assert(empty).message:find("Proc.find(", 1, true) == nil, empty)
end

--- A start in a directory that is not there names it, whatever the
--- program; one that is there, or a file in its place, is not blamed.
local function test_a_missing_cwd_is_named(tmp: string)
  local missing = tmp .. "/not-here"
  for _, argv in ipairs({ { "ls" }, { tmp .. "/never-started" } }) do
    local started, trouble = Child.start(argv, { timeout_ns = Child.FOREVER, cwd = missing })
    assert(started == nil and trouble.message:sub(1, 13) == "child: start:", trouble)
    assert(trouble.message:find(": cwd \"" .. missing .. "\" does not exist", 1, true) ~= nil, trouble)
  end
  local _, beneath = Child.run({ "ls" }, { timeout_ns = Child.FOREVER, cwd = missing .. "/deeper" })
  assert(assert(beneath).message:find("cwd \"" .. missing .. "/deeper\" does not exist", 1, true) ~= nil, beneath)
  local _, there = Child.run({ tmp .. "/never-started" }, { timeout_ns = Child.FOREVER, cwd = tmp })
  assert(assert(there).message:find("cwd", 1, true) == nil, there)
  assert(Fs.write(tmp .. "/file", ""))
  local _, a_file = Child.run({ tmp .. "/never-started" }, { timeout_ns = Child.FOREVER, cwd = tmp .. "/file" })
  assert(assert(a_file).message:find("does not exist", 1, true) == nil, a_file)
  local _, under_a_file = Child.run({ "ls" }, { timeout_ns = Child.FOREVER, cwd = tmp .. "/file/x" })
  assert(assert(under_a_file).message:find("cwd \"" .. tmp .. "/file/x\" does not exist", 1, true) ~= nil,
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
  local child: Child.Handle? = nil
  local trouble = ""
  local ok, raised = pcall(function()
    local started, why = Child.start({ tmp .. "/never-started" }, { timeout_ns = Child.FOREVER, fds = { [255] = null } })
    child, trouble = started, tostring(why)
  end)
  assert(sys.setrlimit(sys.RLIMIT_NOFILE, limits.soft, limits.hard))
  sys.close(null)
  assert(ok, tostring(raised))
  assert(child == nil, "started past the limit")
  assert(trouble:find("handed descriptor 255", 1, true) ~= nil and
      trouble:find("RLIMIT_NOFILE's soft limit of 256", 1, true) ~= nil, trouble)
end

--- A refused option is blamed on the line that passed it, not on a line
--- of cosmic.child: the checks under `validate` raise at their caller's
--- caller's caller.
local function test_a_refused_option_names_the_caller_s_line()
  for _, opts in ipairs({
      { cwd = "/tmp\0bad" } as Child.Options, -- checked: cast_refused
      { cwd = "" } as Child.Options, -- checked: cast_refused
      { timeout_ns = -2 } as Child.Options, -- checked: cast_refused
      { cwd = "/" } as Child.Options, -- checked: cast_refused
  }) do
    local ok, why: boolean, any = pcall(function()
      local _, _ = Child.run({ "/bin/sh" }, opts)
    end)
    assert(not ok and tostring(why):find("child_test:", 1, true) ~= nil, tostring(why))
    assert(tostring(why):find(": child: ", 1, true) ~= nil, "names the module: " .. tostring(why))
  end
end

--- The enums of the stream options are named through the module, so a
--- caller can type a variable that holds one.
local function test_the_stream_enums_are_named_through_the_module()
  local stdin: integer | Child.Stdin = "null"
  local stdout: integer | Child.Stdout = "stream"
  local stderr: integer | Child.Stderr = "capture"
  local opts: Child.Options = { timeout_ns = Child.FOREVER, stdin = stdin, stdout = stdout, stderr = stderr }
  assert(opts.stdin == "null" and opts.stdout == "stream" and opts.stderr == "capture")
end

--- A raise names its module and says why: an empty argv, a wait for no
--- handle, an option of no valid value, and no time limit stated.
local function test_a_raise_names_the_module()
  local raising: {function()} = {
    function() local _, _ = Child.start({}, { timeout_ns = Child.FOREVER }) end,
    function() local _, _ = Child.run({}, { timeout_ns = Child.FOREVER }) end,
    function() local _, _ = Child.wait_any({}) end,
    function()
      local _, _ = Child.start({ "/bin/sh" }, { timeout_ns = Child.FOREVER, capture_limit = 0 })
    end,
    function()
      local _, _ = Child.start({ "/bin/sh" }, { timeout_ns = Child.FOREVER, env = { [""] = "x" } })
    end,
    function()
      local _, _ = Child.start({ "/bin/sh" }, { timeout_ns = Child.FOREVER, fds = { [2] = 1 } })
    end,
    function() local _, _ = Child.run({ "/bin/sh" }, { timeout_ns = Child.FOREVER, cwd = "" }) end,
    function() local _, _ = Child.start({ "/bin/sh" }, { cwd = "/" } as Child.Options) end, -- checked: cast_refused
    function() local _, _ = Child.run({ "/bin/sh" }, { cwd = "/" } as Child.Options) end, -- checked: cast_refused
  }
  local says = { "argv is empty", "argv is empty", "no handles to wait for", "capture_limit is out of range",
    "environment name is empty", "fds keys are child descriptors",
    "cwd is empty; leave it nil to start in this process's directory",
    "opts.timeout_ns is required", "opts.timeout_ns is required" }
  for i, call in ipairs(raising) do
    local ok, why: boolean, any = pcall(call)
    -- `says` holds one line for each call of `raising`.
    local expected = Array.at(says, i)
    assert(not ok and tostring(why):find(": child: " .. expected, 1, true) ~= nil,
      expected .. ": " .. tostring(why))
  end
end

--- A Lua caller that gives no options at all is refused with a raise
--- that names the module. A checked run (`cosmic test --check-types`)
--- refuses the call at the declared parameter first, and fails the test
--- that makes it, so the test skips there.
local function test_a_start_with_no_options_raises()
  if TypeWatch.checked() then
    Test.skip("a checked run refuses a nil `opts` at Child.start's declared parameter first")
  end
  local ok, why: boolean, any = pcall(function()
    local _, _ = Child.start({ "/bin/sh" }, nil as Child.Options) -- checked: cast_refused
  end)
  assert(not ok and tostring(why):find(": child: opts is required", 1, true) ~= nil, tostring(why))
end

local function test_run_refuses_a_stream()
  local streamed: {Child.Options} = {
    { timeout_ns = Child.FOREVER, stdin = "stream" }, { timeout_ns = Child.FOREVER, stdout = "stream" },
    { timeout_ns = Child.FOREVER, stderr = "stream" },
  }
  for _, opts in ipairs(streamed) do
    Test.raises(function() local _, _ = Child.run({ "/bin/sh", "-c", "exit 0" }, opts) end, "Child.start")
  end
  Test.raises(function()
    local _, _ = Child.start({ "/bin/sh" }, { timeout_ns = Child.FOREVER, stdin = "stream", input = "x" })
  end)
end

local function test_options_are_validated()
  Test.raises(function()
    local _, _ = Child.start({ "/bin/sh" }, { timeout_ns = Child.FOREVER, stdin = "null", input = "x" })
  end)
  Test.raises(function()
    local _, _ = Child.start({ "/bin/sh" }, { timeout_ns = Child.FOREVER, fds = { [2] = 1 } })
  end)
  Test.raises(function()
    local _, _ = Child.start({ "/bin/sh" }, { timeout_ns = Child.FOREVER, fds = { [256] = 1 } })
  end)
  Test.raises(function()
    local _, _ = Child.start({ "/bin/sh" }, { timeout_ns = Child.FOREVER, capture_limit = 0 })
  end)
end

--- Bad IDs and namespace combinations are rejected before opening any
--- child pipes or attempting an executable.
local function test_credentials_reject_invalid_ids_and_namespace_options()
  local bad: {Child.Credentials} = {
    {}, { user = 1 }, { group = 1 }, { user = 0, group = 1 },
    { user = 1, group = 0 }, { user = -1, group = 1 },
    { user = 4294967295, group = 1 }, { user = 1, group = 4294967295 },
  }
  for _, credentials in ipairs(bad) do
    Test.raises(function()
      local _, _ = Child.start({ "/never-started" }, { timeout_ns = Child.FOREVER, credentials = credentials })
    end, "credentials need integer user and group")
  end
  for _, sandbox in ipairs({ -- checked: cast_refused
      { unveil = { reads = {} } }, { offline = true }, { user = 1 }, { group = 1 }, -- checked: literal_needs_type
  } as {Child.Sandbox}) do
    local ok, why = pcall(function()
      local _, _ = Child.start({ "/never-started" },
        { timeout_ns = Child.FOREVER, credentials = { user = 1, group = 1 }, sandbox = sandbox })
    end)
    assert(not ok and tostring(why):find("credentials exclude sandbox", 1, true) ~= nil, tostring(why))
  end
  local ok, why = pcall(function()
    local _, _ = Child.start({ "/never-started" },
      { timeout_ns = Child.FOREVER, credentials = { user = 1, group = 1 }, policy = {} })
  end)
  assert(not ok and tostring(why):find("policy and credentials exclude each other", 1, true) ~= nil,
    tostring(why))
end
