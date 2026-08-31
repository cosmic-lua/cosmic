#!/usr/bin/env cosmic
local landlock = require("cosmic.sandbox.landlock")
local plan = require("cosmic.sandbox.plan")
local sandbox = require("cosmic.sandbox")
local net = require("cosmic.net")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- ABI 4 (Linux 6.7+) is the hard gate for the whole net section; below
-- it (or off Linux) there is nothing to enforce, ever, the same "skip
-- on the probed ABI" convention landlock_test.tl already uses for the
-- REFER/TRUNCATE ABI gates.
local function net_abi_ok(): boolean
  return landlock.available() and (landlock.abi() or 0) >= 4
end

local function test_module_exports()
  assert(type(landlock.NET_BIND_TCP) == "number", "NET_BIND_TCP should be a number")
  assert(type(landlock.NET_CONNECT_TCP) == "number", "NET_CONNECT_TCP should be a number")
  assert(type(landlock.NET_ALL) == "number", "NET_ALL should be a number")
  assert((landlock.NET_ALL & landlock.NET_BIND_TCP) == landlock.NET_BIND_TCP,
    "NET_ALL should include NET_BIND_TCP")
  assert((landlock.NET_ALL & landlock.NET_CONNECT_TCP) == landlock.NET_CONNECT_TCP,
    "NET_ALL should include NET_CONNECT_TCP")
  assert(type(plan.for_landlock_net) == "function", "for_landlock_net should be a function")
  assert(type(plan.validate_net) == "function", "validate_net should be a function")
end

-- The net -> landlock mapping, pure and inspectable, mirroring
-- test_plan_landlock_mapping's fs coverage.
local function find_net_rule(rules: {landlock.NetRule}, port: integer): landlock.NetRule | nil
  for _, r in ipairs(rules) do
    if r.port == port then return r end
  end
  return nil
end

local function test_plan_net_mapping()
  -- Absent net (nil) plans to no handled bits and no rules: nothing to
  -- enforce, the same as an absent section at the facade.
  local opts = plan.for_landlock_net(nil)
  check.equal(opts.handled_net, 0, "nil net -> handled_net 0")
  check.equal(#opts.net_rules, 0, "nil net -> no rules")

  -- A present-but-empty group still claims its bit: landlock will
  -- handle (and thus deny every port under) that category.
  opts = plan.for_landlock_net({connect_tcp = {}})
  check.equal(opts.handled_net, landlock.NET_CONNECT_TCP,
    "present-empty connect_tcp claims the bit")
  check.equal(#opts.net_rules, 0, "empty group plans no rules (denies all ports)")

  -- An absent group leaves its bit unclaimed: bind stays unrestricted.
  opts = plan.for_landlock_net({connect_tcp = {80}})
  assert((opts.handled_net & landlock.NET_BIND_TCP) == 0,
    "absent bind_tcp must not be handled")
  local r = find_net_rule(opts.net_rules, 80)
  assert(r, "expected a port 80 rule")
  check.equal(r.access, landlock.NET_CONNECT_TCP, "connect_tcp -> NET_CONNECT_TCP only")

  opts = plan.for_landlock_net({bind_tcp = {1234}})
  check.equal(opts.handled_net, landlock.NET_BIND_TCP, "bind_tcp claims NET_BIND_TCP")
  r = find_net_rule(opts.net_rules, 1234)
  assert(r, "expected a port 1234 rule")
  check.equal(r.access, landlock.NET_BIND_TCP, "bind_tcp -> NET_BIND_TCP only")

  -- A port listed in both groups gets the union of their access, same
  -- as a path listed in several fs groups.
  opts = plan.for_landlock_net({connect_tcp = {5000}, bind_tcp = {5000}})
  check.equal(opts.handled_net, landlock.NET_ALL, "both groups claim both bits")
  r = find_net_rule(opts.net_rules, 5000)
  assert(r, "expected a port 5000 rule")
  check.equal(r.access, landlock.NET_ALL, "overlapping port ORs access")
  check.equal(#opts.net_rules, 1, "overlapping port dedupes into one rule")

  -- handled (fs) stays 0 and rules stays empty: a net-only plan must
  -- not also deny every path when applied.
  check.equal(opts.handled, 0, "net-only plan must not claim any fs bits")
  check.equal(#opts.rules, 0, "net-only plan must add no fs rules")
end

-- Structural validation happens before any enforcement, so rejected
-- policies are safe to exercise in-process: nothing may be applied.
local function test_validate_net_rejects_before_enforcing()
  local err = check.refuses(sandbox.apply, {net = {}})
  assert(err:find("no groups", 1, true), "groupless net must be rejected: " .. err)

  err = check.refuses(sandbox.apply, {net = {connect_tcp = "x"}})
  assert(err:find("net.connect_tcp", 1, true), "non-list net group must be rejected: " .. err)

  -- Out-of-range and non-integer ports are named by index and value,
  -- so a caller can find the bad entry without re-deriving which key
  -- failed.
  err = check.refuses(sandbox.apply, {net = {connect_tcp = {70000}}})
  assert(err:find("net.connect_tcp[1]", 1, true) and err:find("70000", 1, true),
    "out-of-range port must name index and value: " .. err)

  err = check.refuses(sandbox.apply, {net = {bind_tcp = {-1}}})
  assert(err:find("net.bind_tcp[1]", 1, true) and err:find("-1", 1, true),
    "negative port must name index and value: " .. err)

  err = check.refuses(sandbox.apply, {net = {connect_tcp = {8080, "bad"}}})
  assert(err:find("net.connect_tcp[2]", 1, true) and err:find("bad", 1, true),
    "non-integer port must name index and value: " .. err)

  assert(sandbox.validate({net = {connect_tcp = {80}}}), "a valid net policy must validate")
  assert(sandbox.validate({net = {connect_tcp = {}, bind_tcp = {}}}),
    "present-empty groups deny everything but still validate")

  -- The rejection above must have enforced nothing: this process is
  -- still on the network unrestricted.
  local probe = check.must(net.listen_tcp("127.0.0.1", 0))
  check.must(probe:close())
end

-- Monkeypatching the landlock shard (the same technique init_test.tl
-- uses for fs) exercises the ABI < 4 fail-closed/skip path
-- deterministically: a live host is always either ABI >= 4 (this CI
-- lane) or lacks landlock outright, never usefully "ABI 3", so this is
-- the only way to prove the gate without an old kernel.
local function with_mock_landlock(mocks: {string: function}, body: function(): boolean)
  local saved: {string: function} = {}
  for name, fn in pairs(mocks) do
    saved[name] = (landlock as {string: function})[name]; -- cast: record to map probe
    (landlock as {string: function})[name] = fn -- cast: record to map probe
  end
  local ok, err = pcall(body)
  for name, fn in pairs(saved) do
    (landlock as {string: function})[name] = fn -- cast: record to map probe
  end
  if not ok then error(err, 0) end
end

local function test_net_fails_closed_below_abi_4()
  with_mock_landlock({
      available = function(): boolean return true end,
      abi = function(): integer | nil, string return 3 end,
    }, function(): boolean
      local ok, err = sandbox.apply({net = {connect_tcp = {80}}})
      assert(not ok and err:find("ABI", 1, true),
        "net below ABI 4 must fail closed: " .. tostring(err))

      local report = check.must(sandbox.apply({net = {connect_tcp = {80}},
            best_effort = true, allow_unenforced = true}))
      check.equal(report.net.state, "skipped", "best_effort must report net as skipped")
      assert(report.net.missing:find("ABI", 1, true),
        "missing must name the ABI gap: " .. report.net.missing)
      return true
    end)
end

-- test_net_fails_closed_below_abi_4 proves the FACADE gate
-- (sandbox.apply's net_ok check in init.tl, which calls landlock.abi()
-- and landlock.available() through this module's table and so sees the
-- mock above). restrict() has its OWN ABI-4 gate on the same net
-- request (landlock.tl's "abi_version < NET_ABI" check) for a caller
-- that reaches landlock.restrict() directly, bypassing the facade
-- entirely — that gate needs its own proof, or removing it regresses
-- silently past both the facade test and everything else in this
-- suite (confirmed by mutating it: nothing failed).
--
-- Mocking landlock.available/landlock.abi reaches restrict()'s own
-- checks because restrict() reads them back through the module table
-- (M.available()/M.abi()), not local upvalues — see the M
-- forward-declaration in landlock.tl. With both mocked, the ABI check
-- below returns before restrict() ever calls a real landlock syscall,
-- so this needs no real kernel support and runs in-process safely (no
-- risk of actually restricting this test process).
local function test_restrict_own_abi_gate_below_abi_4()
  with_mock_landlock({
      available = function(): boolean return true end,
      abi = function(): integer | nil, string return 3 end,
    }, function(): boolean
      local ok, err = landlock.restrict({
          handled = 0,
          handled_net = landlock.NET_CONNECT_TCP,
          net_rules = {{port = 80, access = landlock.NET_CONNECT_TCP}},
        })
      assert(not ok and err:find("ABI", 1, true),
        "restrict() must gate its own net request below ABI 4: " .. tostring(err))
      return true
    end)
end

-- Live: bind two loopback listeners, grant connect_tcp to only one.
-- Enforcement is irreversible, so it applies in a subprocess.
local function test_connect_tcp_allows_granted_port_denies_other()
  if not net_abi_ok() then
    check.enforce_skip("landlock net needs ABI >= 4 (this kernel is ABI "
      .. tostring(landlock.abi() or 0) .. ")")
    return
  end

  local srv_allowed = check.must(net.listen_tcp("127.0.0.1", 0))
  local port_allowed = check.must(srv_allowed:local_endpoint()).port
  local srv_denied = check.must(net.listen_tcp("127.0.0.1", 0))
  local port_denied = check.must(srv_denied:local_endpoint()).port

  local script = fs.join(tmpdir, "sandbox_net_connect.lua")
  assert(fs.write(script, string.format([[
local sandbox = require("cosmic.sandbox")
local net = require("cosmic.net")
local ok, err = sandbox.apply({ net = { connect_tcp = { %d } } })
if not ok then
  io.write("sandbox-blocked: " .. tostring(err) .. "\n")
  os.exit(0)
end
local c1 = net.dial("127.0.0.1", %d)
io.write(c1 and "allowed-ok\n" or "allowed-fail\n")
local c2 = net.dial("127.0.0.1", %d)
io.write(c2 and "denied-leaked\n" or "denied-blocked\n")
]], port_allowed, port_allowed, port_denied)))

  local h = check.must(child.start({cosmic, script}))
  local r = check.must(h:wait())
  check.must(srv_allowed:close())
  check.must(srv_denied:close())
  if r.signal ~= nil then
    check.enforce_skip("sandbox net subprocess killed by signal " .. tostring(r.signal)
      .. " (outer sandbox)", true)
    return
  end
  local s = r.stdout or ""
  if s:find("sandbox-blocked:", 1, true) then
    check.enforce_skip("sandbox.apply net blocked by an outer sandbox: " .. s, true)
    return
  end
  assert(s:find("allowed-ok", 1, true), "granted port should connect: " .. s)
  assert(s:find("denied-blocked", 1, true), "ungranted port must be denied: " .. s)
  check.enforced("landlock net connect_tcp")
end

-- Live: bind_tcp = {} claims the whole category and grants no port, so
-- even a fresh OS-assigned bind must be denied. Subprocess, same reason.
local function test_bind_tcp_empty_denies_fresh_bind()
  if not net_abi_ok() then
    check.enforce_skip("landlock net needs ABI >= 4 (this kernel is ABI "
      .. tostring(landlock.abi() or 0) .. ")")
    return
  end

  local script = fs.join(tmpdir, "sandbox_net_bind.lua")
  assert(fs.write(script, [[
local sandbox = require("cosmic.sandbox")
local net = require("cosmic.net")
local ok, err = sandbox.apply({ net = { bind_tcp = {} } })
if not ok then
  io.write("sandbox-blocked: " .. tostring(err) .. "\n")
  os.exit(0)
end
local srv, berr = net.listen_tcp("127.0.0.1", 0)
io.write(srv and "bind-leaked\n" or ("bind-blocked: " .. tostring(berr) .. "\n"))
]]))

  local h = check.must(child.start({cosmic, script}))
  local r = check.must(h:wait())
  if r.signal ~= nil then
    check.enforce_skip("sandbox net subprocess killed by signal " .. tostring(r.signal)
      .. " (outer sandbox)", true)
    return
  end
  local s = r.stdout or ""
  if s:find("sandbox-blocked:", 1, true) then
    check.enforce_skip("sandbox.apply net blocked by an outer sandbox: " .. s, true)
    return
  end
  assert(s:find("bind-blocked", 1, true), "bind_tcp = {} must deny a fresh bind: " .. s)
  check.enforced("landlock net bind_tcp")
end
