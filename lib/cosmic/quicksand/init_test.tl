#!/usr/bin/env cosmic
local quicksand = require("cosmic.quicksand")
local errno = require("cosmic.errno")
local a = require("cosmic.assert")

local function test_module_exports()
  assert(type(quicksand.capabilities) == "function", "capabilities should be a function")
  assert(type(quicksand.is_supported) == "function", "is_supported should be a function")
end
test_module_exports()

local function test_capabilities_shape()
  local c = quicksand.capabilities()
  assert(type(c) == "table", "capabilities() should return a table")
  assert(type(c.linux) == "boolean", "capabilities().linux should be boolean")
  assert(type(c.user_ns) == "boolean", "capabilities().user_ns should be boolean")
  assert(type(c.mount_ns) == "boolean", "capabilities().mount_ns should be boolean")
  assert(type(c.net_ns) == "boolean", "capabilities().net_ns should be boolean")
  assert(type(c.uts_ns) == "boolean", "capabilities().uts_ns should be boolean")
  assert(type(c.pid_ns) == "boolean", "capabilities().pid_ns should be boolean")
  assert(type(c.pivot_root) == "boolean", "capabilities().pivot_root should be boolean")
  assert(type(c.cap_net_admin) == "boolean", "capabilities().cap_net_admin should be boolean")
  assert(type(c.landlock) == "boolean", "capabilities().landlock should be boolean")
  assert(type(c.pledge) == "boolean", "capabilities().pledge should be boolean")
  assert(type(c.unveil) == "boolean", "capabilities().unveil should be boolean")
end
test_capabilities_shape()

local function test_capabilities_cached()
  local a = quicksand.capabilities()
  local b = quicksand.capabilities()
  assert(a == b, "capabilities() must return the same cached table on repeat calls")
end
test_capabilities_cached()

local function test_is_supported_returns_boolean()
  local v = quicksand.is_supported()
  assert(type(v) == "boolean", "is_supported() should return a boolean, got " .. type(v))
end
test_is_supported_returns_boolean()

local function test_is_supported_matches_capabilities()
  local c = quicksand.capabilities()
  local expected = c.linux and c.net_ns and c.mount_ns
  assert(quicksand.is_supported() == expected,
    "is_supported() must agree with capabilities().linux/net_ns/mount_ns")
end
test_is_supported_matches_capabilities()

-- Build a synthetic Errno-shaped value carrying a fixed errno number, so
-- the probe's ENOSYS classification can be exercised without a host that
-- actually lacks the syscall.
local function mk_err(n: integer): any
  return {errno = function(_: any): integer return n end}
end

-- The probe reports a binding available when a no-op call succeeds or
-- fails with anything other than ENOSYS, and unavailable when the binding
-- is absent (nil) or the call returns ENOSYS. This is the classification
-- that was fail-open before the Phase 0 Errno-return fix (audit §2.3): the
-- error used to be swallowed, so the ENOSYS branch was dead and every
-- probe reported available. These cases fail if that regresses.
local function test_probe_nil_binding_is_unavailable()
  a.eq(quicksand.probe(nil), false, "a nil binding must probe as unavailable")
end
test_probe_nil_binding_is_unavailable()

local function test_probe_success_is_available()
  a.eq(quicksand.probe(function(): any return true end), true,
    "a successful no-op call means the syscall is wired up")
end
test_probe_success_is_available()

local function test_probe_enosys_is_unavailable()
  local enosys = errno.code("ENOSYS")
  assert(enosys, "ENOSYS must be defined on this host")
  a.eq(quicksand.probe(function(): any, any return nil, mk_err(enosys) end), false,
    "ENOSYS means the syscall is absent -> unavailable (the branch that was dead pre-fix)")
end
test_probe_enosys_is_unavailable()

local function test_probe_policy_error_is_available()
  local eperm = errno.code("EPERM")
  assert(eperm, "EPERM must be defined on this host")
  a.eq(quicksand.probe(function(): any, any return nil, mk_err(eperm) end), true,
    "a policy error (EPERM) still proves the syscall is wired up")
end
test_probe_policy_error_is_available()

-- Re-verify against the real host: on Linux both pledge (seccomp) and,
-- when the kernel advertises landlock, unveil are genuinely present, so the
-- probe must report them. The enforce lane (bin/make enforce) separately
-- proves both mechanisms actually restrict on ubuntu-latest; this pins the
-- probe's report to that reality instead of the old vacuous always-true.
local function test_real_pledge_unveil_probe()
  local c = quicksand.capabilities()
  if not c.linux then
    a.skip("quicksand pledge/unveil probe: non-Linux host")
    return
  end
  a.ok(c.pledge, "capabilities().pledge must be true on Linux (pledge via seccomp)")
  if c.landlock then
    a.ok(c.unveil, "capabilities().unveil must be true on Linux with landlock")
  else
    a.skip("quicksand unveil probe: host kernel lacks landlock")
  end
  a.enforced("quicksand pledge/unveil probe")
end
test_real_pledge_unveil_probe()

local function test_capabilities_does_not_self_brick()
  -- Regression: capabilities() must never invoke the destructive
  -- unix.unveil(nil, nil) commit, which locks the calling process into a
  -- deny-all sandbox. Prove ordinary filesystem IO still works afterward by
  -- reading back a file written before the probe.
  local tmp = os.getenv("TEST_TMPDIR") as string
  local path = tmp .. "/unveil_probe_check"
  local w = io.open(path, "w")
  assert(w, "should create probe check file")
  w:write("ok")
  w:close()

  quicksand.capabilities()

  local f = io.open(path, "r")
  assert(f ~= nil, "capabilities() must not sandbox the calling process")
  if f then f:close() end
end
test_capabilities_does_not_self_brick()

local function test_unveil_matches_landlock_on_linux()
  -- On Linux, cosmo implements unveil via Landlock, so the derived unveil
  -- capability must equal the landlock one (no independent, destructive probe).
  local c = quicksand.capabilities()
  if not c.linux then
    a.skip("unveil/landlock equivalence: non-Linux host")
    return
  end
  a.eq(c.unveil, c.landlock,
    "on Linux unveil is derived from landlock and must equal it")
end
test_unveil_matches_landlock_on_linux()

local function test_box_reexported()
  local J = quicksand.Box as {string: any}
  assert(J, "Box should be re-exported from cosmic.quicksand")
  assert(type(J.new) == "function")
  assert(type(J.merge) == "function")
end
test_box_reexported()
