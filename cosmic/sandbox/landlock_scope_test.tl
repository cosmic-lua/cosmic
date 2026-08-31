#!/usr/bin/env cosmic
local landlock = require("cosmic.sandbox.landlock")
local plan = require("cosmic.sandbox.plan")
local sandbox = require("cosmic.sandbox")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- ABI 6 (Linux 6.12+) is the hard gate for the whole scope section; below
-- it (or off Linux) there is nothing to enforce, ever, the same
-- "skip on the probed ABI" convention landlock_test.tl/landlock_net_test.tl
-- already use for their own ABI gates.
local function scope_abi_ok(): boolean
  return landlock.available() and (landlock.abi() or 0) >= 6
end

local function ioctl_dev_abi_ok(): boolean
  return landlock.available() and (landlock.abi() or 0) >= 5
end

local function test_module_exports()
  assert(type(plan.for_landlock_scope) == "function",
    "for_landlock_scope should be a function")
  assert(type(plan.validate_scope) == "function", "validate_scope should be a function")
end

-- The scope -> landlock mapping, pure and inspectable, mirroring
-- test_plan_net_mapping's coverage in landlock_net_test.tl.
local function test_plan_scope_mapping()
  -- Absent scope (nil) plans to no scoped bits: nothing to enforce, the
  -- same as an absent section at the facade.
  local opts = plan.for_landlock_scope(nil)
  check.equal(opts.scoped, 0, "nil scope -> scoped 0")
  check.equal(opts.handled, 0, "scope-only plan must not claim any fs bits")
  check.equal(#opts.rules, 0, "scope-only plan must add no fs rules")

  opts = plan.for_landlock_scope({signal = true})
  check.equal(opts.scoped, landlock.SCOPE_SIGNAL, "signal = true claims SCOPE_SIGNAL only")

  opts = plan.for_landlock_scope({abstract_unix = true})
  check.equal(opts.scoped, landlock.SCOPE_ABSTRACT_UNIX_SOCKET,
    "abstract_unix = true claims SCOPE_ABSTRACT_UNIX_SOCKET only")

  opts = plan.for_landlock_scope({signal = true, abstract_unix = true})
  check.equal(opts.scoped, landlock.SCOPE_ALL, "both keys claim both bits")

  -- A key explicitly set to false claims nothing, same as absent.
  opts = plan.for_landlock_scope({signal = false, abstract_unix = true})
  check.equal(opts.scoped, landlock.SCOPE_ABSTRACT_UNIX_SOCKET,
    "signal = false must not claim SCOPE_SIGNAL")
end

-- Structural validation happens before any enforcement, so rejected
-- policies are safe to exercise in-process: nothing may be applied.
local function test_validate_scope_rejects_before_enforcing()
  local err = check.refuses(sandbox.apply, {scope = {}})
  assert(err:find("no keys", 1, true), "keyless scope must be rejected: " .. err)

  err = check.refuses(sandbox.apply, {scope = {signal = "yes"}})
  assert(err:find("scope.signal", 1, true), "non-boolean scope key must be rejected: " .. err)

  assert(sandbox.validate({scope = {signal = true}}), "a valid scope policy must validate")
  assert(sandbox.validate({scope = {abstract_unix = true}}),
    "a valid scope policy must validate")
  assert(sandbox.validate({scope = {signal = false, abstract_unix = true}}),
    "an explicit false key still counts as present")

  -- The rejection above must have enforced nothing: apply() checks
  -- structure before any syscall, so this process is still unrestricted.
  local probe = fs.join(tmpdir, "scope_validation_probe")
  assert(fs.write(probe, "ok"))
  local f = io.open(probe, "r")
  assert(f, "validation failures must not half-apply a sandbox")
  f:close()
end

-- Monkeypatching the landlock shard (the same technique
-- landlock_net_test.tl uses) exercises the ABI < 6 fail-closed/skip path
-- deterministically: a live host is always either ABI >= 6 (this CI
-- lane) or lacks landlock outright, never usefully "ABI 5".
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

local function test_scope_fails_closed_below_abi_6()
  with_mock_landlock({
      available = function(): boolean return true end,
      abi = function(): integer | nil, string return 5 end,
    }, function(): boolean
      local ok, err = sandbox.apply({scope = {signal = true}})
      assert(not ok and err:find("ABI", 1, true),
        "scope below ABI 6 must fail closed: " .. tostring(err))

      local report = check.must(sandbox.apply({scope = {signal = true},
            best_effort = true, allow_unenforced = true}))
      check.equal(report.scope.state, "skipped", "best_effort must report scope as skipped")
      assert(report.scope.missing:find("ABI", 1, true),
        "missing must name the ABI gap: " .. report.scope.missing)
      return true
    end)
end

-- test_scope_fails_closed_below_abi_6 proves the FACADE gate
-- (sandbox.apply's scope_ok check, which calls landlock.abi()/available()
-- through this module's table and so sees the mock above). restrict()
-- has its OWN ABI-6 gate on the same scoped request for a caller that
-- reaches landlock.restrict() directly, bypassing the facade entirely —
-- that gate needs its own proof, mirroring
-- test_restrict_own_abi_gate_below_abi_4 in landlock_net_test.tl.
local function test_restrict_own_abi_gate_below_abi_6()
  with_mock_landlock({
      available = function(): boolean return true end,
      abi = function(): integer | nil, string return 5 end,
    }, function(): boolean
      local ok, err = landlock.restrict({
          handled = 0,
          scoped = landlock.SCOPE_SIGNAL,
        })
      assert(not ok and err:find("ABI", 1, true),
        "restrict() must gate its own scope request below ABI 6: " .. tostring(err))
      return true
    end)
end

-- Live: a domain confining signals may still signal ITSELF and its own
-- future children, but not a peer that forked before the domain
-- existed — Landlock domains apply to the calling thread and its
-- FUTURE children only, so a pre-existing peer is simply outside it.
-- Enforcement is irreversible, so both the restrict and the probe run
-- in a subprocess; the peer is spawned before that subprocess restricts
-- itself.
local function test_scope_signal_refuses_outside_domain()
  if not scope_abi_ok() then
    check.enforce_skip("landlock scope needs ABI >= 6 (this kernel is ABI "
      .. tostring(landlock.abi() or 0) .. ")")
    return
  end

  local peer_script = fs.join(tmpdir, "sandbox_scope_peer.lua")
  assert(fs.write(peer_script, [[
require("cosmic.time").sleep_ms(4000)
]]))

  local script = fs.join(tmpdir, "sandbox_scope_signal.lua")
  assert(fs.write(script, string.format([[
local child = require("cosmic.child")
local sandbox = require("cosmic.sandbox")
local peer = child.start({%q, %q})
if not peer then
  io.write("peer-spawn-failed\n")
  os.exit(0)
end
local ok, err = sandbox.apply({ scope = { signal = true } })
if not ok then
  io.write("sandbox-blocked: " .. tostring(err) .. "\n")
  os.exit(0)
end
-- Signal 0 sends nothing; it only exercises the kernel's permission
-- check, the standard way to probe "may I signal this pid" for real.
local kok, kerr = peer:stop(0)
if kok then
  io.write("signal-leaked\n")
else
  io.write("signal-blocked: " .. tostring(kerr) .. "\n")
end
os.exit(0)
]], cosmic, peer_script)))

  local h = check.must(child.start({cosmic, script}))
  local r = check.must(h:wait())
  if r.signal ~= nil then
    check.enforce_skip("sandbox scope subprocess killed by signal " .. tostring(r.signal)
      .. " (outer sandbox)", true)
    return
  end
  local s = r.stdout or ""
  if s:find("sandbox-blocked:", 1, true) or s:find("peer-spawn-failed", 1, true) then
    check.enforce_skip("sandbox scope setup blocked: " .. s, true)
    return
  end
  assert(s:find("signal-blocked:", 1, true),
    "scope = {signal = true} must deny a signal to an outside-domain peer: " .. s)
  assert(s:find("EPERM", 1, true),
    "the blocked signal must fail with EPERM specifically: " .. s)
  check.enforced("landlock scope signal")
end

-- Live: an rw grant on a tty/dev fixture (a pty's subordinate node) must
-- keep ioctl-based operations like isatty(3) working inside the granted
-- tree once ABI >= 5 makes landlock enforce IOCTL_DEV — the regression
-- this pins is IOCTL_DEV missing from the rw composite, which would
-- silently turn every device node in an rw tree open-only. Enforcement
-- is irreversible, so it runs in a subprocess.
local function test_ioctl_dev_rw_grant_keeps_isatty_working()
  if not ioctl_dev_abi_ok() then
    check.enforce_skip("landlock ioctl-dev needs ABI >= 5 (this kernel is ABI "
      .. tostring(landlock.abi() or 0) .. ")")
    return
  end

  local script = fs.join(tmpdir, "sandbox_ioctl_dev.lua")
  assert(fs.write(script, [[
local tty = require("cosmic.tty")
local fd = require("cosmic.fd")
local sandbox = require("cosmic.sandbox")
local pty, err = tty.open_pty()
if not pty then
  io.write("openpty-failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
fd.wrap(pty.subordinate):close()
local ok, aerr = sandbox.apply({ fs = { rw = { pty.name } } })
if not ok then
  io.write("sandbox-blocked: " .. tostring(aerr) .. "\n")
  os.exit(0)
end
local h, operr = fd.open(pty.name, fd.O_RDWR)
if not h then
  io.write("open-blocked: " .. tostring(operr) .. "\n")
  os.exit(0)
end
io.write(tty.is_tty(h:fd()) and "isatty-ok\n" or "isatty-fail\n")
]]))

  local h = check.must(child.start({cosmic, script}))
  local r = check.must(h:wait())
  if r.signal ~= nil then
    check.enforce_skip("sandbox ioctl-dev subprocess killed by signal " .. tostring(r.signal)
      .. " (outer sandbox)", true)
    return
  end
  local s = r.stdout or ""
  if s:find("sandbox-blocked:", 1, true) or s:find("openpty-failed:", 1, true) then
    check.enforce_skip("sandbox ioctl-dev setup blocked: " .. s, true)
    return
  end
  assert(not s:find("open-blocked", 1, true),
    "rw grant must allow opening the granted tty node: " .. s)
  assert(s:find("isatty-ok", 1, true),
    "rw grant must keep isatty working via IOCTL_DEV: " .. s)
  check.enforced("landlock ioctl-dev rw grant")
end
