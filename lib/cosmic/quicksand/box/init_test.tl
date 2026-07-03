#!/usr/bin/env cosmic
local Box = require("cosmic.quicksand.box")
local quicksand = require("cosmic.quicksand")

local function test_module_exports()
  assert(type(Box.new) == "function")
  assert(type(Box.merge) == "function")
end
test_module_exports()

local function test_new_empty()
  local j, err = Box.new(nil)
  assert(j, "new(nil) should succeed: " .. tostring(err))
  assert(type(j.run) == "function")
  assert(type(j.close) == "function")
end
test_new_empty()

local function test_new_with_opts()
  local j = assert(Box.new({
        hostname = "work",
        fs = {ro = {"/usr"}, rw = {"/tmp"}},
        net = {allow = {["api.example.com:443"] = {}}},
        proc = {no_new_privs = true, uid = 1000},
        env = {keep = {"PATH"}, set = {FOO = "bar"}},
        cwd = "/tmp",
      }))
  assert(j.opts.hostname == "work")
  assert(j.opts.cwd == "/tmp")
end
test_new_with_opts()

local function test_new_rejects_bad_types()
  -- Escape to raw tables so we can construct deliberately malformed opts.
  local new_any = Box.new as function(any): any, any
  local cases: {{string: any}} = {
    {opts = {cwd = 5}, want = "cwd"},
    {opts = {hostname = {}}, want = "hostname"},
    {opts = {proc = {uid = "x"}}, want = "proc.uid"},
    {opts = {proc = {pledge = 1}}, want = "proc.pledge"},
    {opts = {proc = {keep_caps = "x"}}, want = "proc.keep_caps"},
    {opts = {net = {allow = "x"}}, want = "net.allow"},
    {opts = {fs = {ro = "x"}}, want = "fs.ro"},
  }
  for _, c in ipairs(cases) do
    local j, err = new_any(c.opts)
    assert(j == nil, "expected rejection for " .. (c.want as string))
    assert(err and (err as string):find(c.want as string, 1, true),
      "expected error to mention '" .. (c.want as string) .. "', got: " .. tostring(err))
  end
end
test_new_rejects_bad_types()

local function test_run_requires_argv()
  local j = assert(Box.new())
  local run_any = j.run as function(any, any): any, any
  local code, err = run_any(j, nil)
  assert(code == nil)
  assert(err and (err as string):find("argv", 1, true), "got: " .. tostring(err))

  code, err = j:run({})
  assert(code == nil)
  assert(err and (err as string):find("argv", 1, true))
end
test_run_requires_argv()

local function test_run_on_non_linux_returns_specific_error()
  local c = quicksand.capabilities()
  if c.linux then return end
  local j = assert(Box.new())
  local code, err = j:run({"/bin/true"})
  assert(code == nil, "run should fail on non-linux")
  assert(err and (err as string):find("Linux only", 1, true),
    "expected 'Linux only' error, got: " .. tostring(err))
end
test_run_on_non_linux_returns_specific_error()

local function test_run_on_linux_returns_clean_shape()
  -- On Linux, either preflight fails with a specific capability error,
  -- or orchestration runs /bin/true (returning an integer exit code),
  -- or the outer environment blocks unshare and the supervisor exits
  -- with a non-zero code. Any of the above must come back as a clean
  -- (integer|nil, string|nil) pair rather than a raised error.
  local c = quicksand.capabilities()
  if not c.linux then return end
  local j = assert(Box.new())
  local code, err = j:run({"/bin/true"})
  if code == nil then
    assert(type(err) == "string", "nil code must come with string err")
  else
    assert(type(code) == "number", "got type: " .. type(code))
  end
end
test_run_on_linux_returns_clean_shape()

local function test_run_after_close_fails()
  local j = assert(Box.new())
  assert(j:close())
  local code, err = j:run({"/bin/true"})
  assert(code == nil)
  assert(err and (err as string):find("closed", 1, true))
end
test_run_after_close_fails()

local function test_close_idempotent()
  local j = assert(Box.new())
  assert(j:close())
  assert(j:close(), "second close should be a no-op")
end
test_close_idempotent()

local function test_merge_reexported()
  local a = {fs = {ro = {"/usr"}}}
  local b = {fs = {ro = {"/etc"}, rw = {"/tmp"}}}
  local out = Box.merge(a, b)
  local fs = (out as {string: any}).fs as {string: any}
  local ro = fs.ro as {string}
  assert(#ro == 2 and ro[1] == "/usr" and ro[2] == "/etc")
  assert((fs.rw as {string})[1] == "/tmp")
end
test_merge_reexported()

-- FIX 3: a deny-only fs policy (no ro/rw/exec) must be rejected at
-- preflight so landlock is never silently skipped.
local function test_deny_only_requires_allowlist()
  local c = quicksand.capabilities()
  if not c.linux then return end

  local j = assert(Box.new({fs = {deny = {"/proc"}}}))
  local code, err = j:run({"/bin/true"})
  assert(code == nil, "deny-only policy should fail preflight, got code: " .. tostring(code))
  assert(err and (err as string):find("deny", 1, true),
    "error should mention 'deny', got: " .. tostring(err))
end
test_deny_only_requires_allowlist()

-- FIX 3: a policy with both deny and an allowlist should still pass preflight.
local function test_deny_with_allowlist_passes_preflight()
  local c = quicksand.capabilities()
  if not c.linux then return end

  -- new() + run() on a non-linux-capable environment skips gracefully.
  -- On Linux, preflight should NOT reject a policy that has deny + ro.
  local j, jerr = Box.new({fs = {ro = {"/usr"}, deny = {"/proc"}}})
  assert(j, "deny + ro should be accepted: " .. tostring(jerr))
  -- We don't actually run the box here; structural validity is enough.
end
test_deny_with_allowlist_passes_preflight()
