#!/usr/bin/env cosmic
local Box = require("cosmic.quicksand.box")
local check = require("cosmic.check")
local quicksand = require("cosmic.quicksand")
local deep = require("cosmic.deep")
local types = require("cosmic.quicksand.types")

local function test_module_exports()
  assert(type(Box.new) == "function")
  assert(type(Box.merge) == "function")
end

local function test_new_empty()
  local j = check.must(Box.new(nil))
  assert(type(j.run) == "function")
  assert(type(j.close) == "function")
end

local function test_new_with_opts()
  local j = check.must(Box.new({
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

-- Raw tables, so the cases can carry the deliberately malformed opts the
-- declared BoxOptions forbids; check.refuses makes the call past that
-- signature and hands the refusal back typed.
local record Case
  opts: {string: any}
  want: string
end

local function test_new_rejects_bad_types()
  local cases: {Case} = {
    {opts = {cwd = 5}, want = "cwd"},
    {opts = {hostname = {}}, want = "hostname"},
    {opts = {proc = {uid = "x"}}, want = "proc.uid"},
    {opts = {proc = {pledge = 1}}, want = "proc.pledge"},
    {opts = {proc = {keep_caps = "x"}}, want = "proc.keep_caps"},
    {opts = {net = {allow = "x"}}, want = "net.allow"},
    {opts = {fs = {ro = "x"}}, want = "fs.ro"},
  }
  for _, c in ipairs(cases) do
    local err = check.refuses(Box.new, c.opts)
    assert(err:find(c.want, 1, true),
      "expected error to mention '" .. c.want .. "', got: " .. err)
  end
end

local function test_run_requires_argv()
  local j = check.must(Box.new())
  local err = check.refuses(j.run, j, nil)
  assert(err:find("argv", 1, true), "got: " .. err)

  local code, err2 = j:run({})
  assert(code == nil)
  assert(err2 and err2:find("argv", 1, true), "got: " .. tostring(err2))
end

local function test_run_on_non_linux_returns_specific_error()
  local c = quicksand.capabilities()
  if c.linux then return end
  local j = check.must(Box.new())
  local code, err = j:run({"/bin/true"})
  assert(code == nil, "run should fail on non-linux")
  assert(err and err:find("Linux only", 1, true),
    "expected 'Linux only' error, got: " .. tostring(err))
end

local function test_run_on_linux_returns_clean_shape()
  -- On Linux, either preflight fails with a specific capability error,
  -- or orchestration runs /bin/true (returning an integer exit code),
  -- or the outer environment blocks unshare and the supervisor exits
  -- with a non-zero code. Any of the above must come back as a clean
  -- (integer|nil, string|nil) pair rather than a raised error.
  local c = quicksand.capabilities()
  if not c.linux then return end
  local j = check.must(Box.new())
  local code, err = j:run({"/bin/true"})
  if code == nil then
    assert(type(err) == "string", "nil code must come with string err")
  else
    assert(type(code) == "number", "got type: " .. type(code))
  end
end

local function test_run_after_close_fails()
  local j = check.must(Box.new())
  assert(j:close())
  local code, err = j:run({"/bin/true"})
  assert(code == nil)
  assert(err and err:find("closed", 1, true))
end

local function test_close_idempotent()
  local j = check.must(Box.new())
  assert(j:close())
  assert(j:close(), "second close should be a no-op")
end

local function test_merge_reexported()
  local a = {fs = {ro = {"/usr"}}}
  local b = {fs = {ro = {"/etc"}, rw = {"/tmp"}}}
  local out = Box.merge(a, b)
  local ro = out.fs.ro
  assert(#ro == 2 and ro[1] == "/usr" and ro[2] == "/etc")
  assert(out.fs.rw[1] == "/tmp")
end

-- The decoy fs.deny knob is gone: the fs policy is an allowlist, so a
-- deny list never did anything. Passing one must fail loudly at new()
-- (not be silently ignored) so old policies get a migration message.
local function test_fs_deny_rejected_at_new()
  local err = check.refuses(Box.new, {fs = {deny = {"/proc"}}})
  assert(err:find("deny", 1, true),
    "error should name the removed deny knob: " .. err)
  -- ...even next to a valid allowlist.
  local err2 = check.refuses(Box.new, {fs = {ro = {"/usr"}, deny = {"/proc"}}})
  assert(err2:find("deny", 1, true),
    "deny next to an allowlist is still rejected: " .. err2)
end

-- Monkeypatching quicksand.capabilities (the same technique
-- landlock_net_test.tl uses on cosmic.sandbox.landlock) exercises
-- preflight's net-tier logic deterministically without depending on a
-- specific kernel to match each case: user_ns/net_ns/landlock_net are
-- whatever this host reports them as, and reliably steering any one of
-- them independently (net_ns false while user_ns stays true is real --
-- see cosmic.quicksand.init_test's live max_net_namespaces test -- but
-- getting a CI host into that state on demand is not) would need a
-- kernel-level fixture this suite doesn't have. run() always forks
-- before it unshares (see box/run.tl), so calling it directly here —
-- as test_run_on_linux_returns_clean_shape already does — never
-- touches this process's own namespaces.
local function with_mock_capabilities(overrides: {string: any}, body: function(): boolean)
  local mocked: types.Capabilities = deep.copy(quicksand.capabilities())
  for k, v in pairs(overrides) do
    (mocked as {string: any})[k] = v -- cast: probe module surface to swap a member its declared type owns
  end
  check.swap_members(quicksand, {
      capabilities = function(): types.Capabilities return mocked end,
    }, body)
end

-- Non-goal: a host with neither tier refuses a net policy outright,
-- naming both gaps — the "as it does today" refusal this item must not
-- weaken.
local function test_net_refuses_with_neither_tier()
  if not quicksand.capabilities().linux then return end
  local j = check.must(Box.new({net = {allow = {}}}))
  with_mock_capabilities({
      linux = true, user_ns = true, net_ns = false, landlock_net = false,
    }, function(): boolean
      local code, err = j:run({"/bin/true"})
      assert(code == nil, "must refuse when neither net tier is available")
      assert(err and err:find("network namespaces unavailable", 1, true)
        and err:find("landlock net tier unavailable", 1, true),
        "error should name both gaps: " .. tostring(err))
      return true
    end)
end

-- The Landlock net tier alone must not trip the netns-specific refusal:
-- preflight lets the box proceed past that check. Whatever happens
-- next (a real unshare can still fail on a host without genuine
-- user_ns support) is a different, real error — never this one.
local function test_net_proceeds_with_landlock_net_only()
  if not quicksand.capabilities().linux then return end
  local j = check.must(Box.new({net = {allow = {}}}))
  with_mock_capabilities({
      linux = true, user_ns = true, net_ns = false, landlock_net = true,
    }, function(): boolean
      local code, err = j:run({"/bin/true"})
      if code == nil then
        assert(not err:find("network namespaces unavailable", 1, true),
          "landlock_net = true must not hit the netns refusal: " .. tostring(err))
      end
      return true
    end)
end

-- net_tier() reports "none" for a Box with no net policy at all — there
-- is nothing to name a tier for, regardless of host capabilities.
local function test_net_tier_none_without_net_policy()
  local j = check.must(Box.new({}))
  assert(j:net_tier() == "none",
    "no net policy should report tier 'none', got: " .. j:net_tier())
end

-- Isolation tier: net_ns available, Landlock net tier not — net_tier()
-- must say "netns" alone.
local function test_net_tier_netns_when_available()
  if not quicksand.capabilities().linux then return end
  local j = check.must(Box.new({net = {allow = {["example.com:443"] = {}}}}))
  with_mock_capabilities({
      linux = true, user_ns = true, net_ns = true, landlock_net = false,
    }, function(): boolean
      assert(j:net_tier() == "netns",
        "expected tier 'netns', got: " .. j:net_tier())
      return true
    end)
end

-- Backstop tier: net_ns unavailable, Landlock net tier available —
-- net_tier() must say "landlock" alone. Mirrors the mechanism
-- run_test.tl's test_landlock_net_backstop_when_net_ns_unavailable
-- exercises end to end (a real proxy-port-only connection); this pins
-- the reporting side of that same scenario without paying for a fork.
local function test_net_tier_landlock_only_when_net_ns_unavailable()
  if not quicksand.capabilities().linux then return end
  local j = check.must(Box.new({net = {allow = {["example.com:443"] = {}}}}))
  with_mock_capabilities({
      linux = true, user_ns = true, net_ns = false, landlock_net = true,
    }, function(): boolean
      assert(j:net_tier() == "landlock",
        "expected tier 'landlock', got: " .. j:net_tier())
      return true
    end)
end

-- Defense in depth: both tiers available — net_tier() must say both are
-- active, not just one (this is the case NetOptions' doc comment calls
-- out: "Both apply together when available").
local function test_net_tier_both_when_defense_in_depth()
  if not quicksand.capabilities().linux then return end
  local j = check.must(Box.new({net = {allow = {["example.com:443"] = {}}}}))
  with_mock_capabilities({
      linux = true, user_ns = true, net_ns = true, landlock_net = true,
    }, function(): boolean
      assert(j:net_tier() == "netns+landlock",
        "expected tier 'netns+landlock', got: " .. j:net_tier())
      return true
    end)
end

-- The Landlock backstop only ever fires alongside the allowlist proxy
-- (workload_setup only applies it when a proxy_port exists, which only
-- happens when net.allow is set): a net section present but with no
-- `allow` must not falsely report "landlock" just because the ABI
-- supports it.
local function test_net_tier_landlock_requires_allow()
  if not quicksand.capabilities().linux then return end
  local j = check.must(Box.new({net = {}}))
  with_mock_capabilities({
      linux = true, user_ns = true, net_ns = false, landlock_net = true,
    }, function(): boolean
      assert(j:net_tier() == "none",
        "net section without allow must not report 'landlock', got: " .. j:net_tier())
      return true
    end)
end
