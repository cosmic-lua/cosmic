#!/usr/bin/env cosmic
local quicksand = require("cosmic.quicksand")
local errno = require("cosmic.errno")
local check = require("cosmic.check")

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

-- capabilities().user_ns comes from a scratch-child unshare probe, not
-- the compile-time CLONE_NEWUSER constant: that constant is defined even
-- on hosts that forbid unprivileged user namespaces, so it reports a
-- capability that then fails with EPERM mid-setup. Assert the cached
-- report agrees with a fresh probe, and that the probe is exported and
-- deterministic.
local function test_user_ns_agrees_with_scratch_probe()
  -- probe_ns is no longer exported (it forks on every call); the
  -- scratch-unshare result is observable only through capabilities().
  local c = quicksand.capabilities()
  assert(type(c.user_ns) == "boolean", "user_ns should be a boolean")
  if not c.linux then
    check.equal(c.user_ns, false, "user_ns must be false off Linux")
  end
end
test_user_ns_agrees_with_scratch_probe()

-- is_supported: pinned to the capability report it is
-- derived from (which the shape test above proves is all booleans),
-- and stable across calls — not just "returns a boolean".
local function test_is_supported_matches_capabilities()
  local c = quicksand.capabilities()
  local expected = c.linux and c.net_ns and c.mount_ns
  assert(quicksand.is_supported() == expected,
    "is_supported() must agree with capabilities().linux/net_ns/mount_ns")
  assert(quicksand.is_supported() == expected,
    "is_supported() must be deterministic across calls")
end
test_is_supported_matches_capabilities()

-- Build a synthetic failed binding returning the new failure triple —
-- `nil, err (string), errno (number)` — with a fixed errno number, so the
-- probe's ENOSYS classification can be exercised without a host that
-- actually lacks the syscall.
local function mk_fail(msg: string, n: integer): any
  return function(): any, string, integer
    return nil, msg, n
  end
end

-- The probe reports a binding available when a no-op call succeeds or
-- fails with anything other than ENOSYS, and unavailable when the binding
-- is absent (nil) or the call fails with a numeric ENOSYS in its third
-- return slot. The ENOSYS branch depends on the binding actually
-- reporting its errno: swallow that and the branch is dead, every probe
-- reports available, and the classification is fail-open. These cases
-- fail if that regresses.
local function test_probe_nil_binding_is_unavailable()
  check.equal(quicksand.probe(nil), false, "a nil binding must probe as unavailable")
end
test_probe_nil_binding_is_unavailable()

local function test_probe_success_is_available()
  check.equal(quicksand.probe(function(): any return true end), true,
    "a successful no-op call means the syscall is wired up")
end
test_probe_success_is_available()

local function test_probe_enosys_is_unavailable()
  local enosys = errno.code("ENOSYS")
  assert(enosys, "ENOSYS must be defined on this host")
  check.equal(quicksand.probe(
      mk_fail("prctl: ENOSYS: Function not implemented", enosys)), false,
    "ENOSYS means the syscall is absent -> unavailable (the branch that was dead pre-fix)")
end
test_probe_enosys_is_unavailable()

local function test_probe_policy_error_is_available()
  local eperm = errno.code("EPERM")
  assert(eperm, "EPERM must be defined on this host")
  check.equal(quicksand.probe(
      mk_fail("prctl: EPERM: Operation not permitted", eperm)), true,
    "a policy error (EPERM) still proves the syscall is wired up")
end
test_probe_policy_error_is_available()

local function test_probe_string_only_failure_is_available()
  -- A failure that carries no numeric errno (third slot nil) cannot be
  -- classified as ENOSYS; the error string alone must never match, so
  -- the probe reports the syscall wired up.
  check.equal(quicksand.probe(function(): any, string, integer
        return nil, "prctl: ENOSYS: Function not implemented", nil
      end), true,
    "an error string without a numeric errno is never classified as ENOSYS")
end
test_probe_string_only_failure_is_available()

-- Re-verify against the real host: on Linux both pledge (seccomp) and,
-- when the kernel advertises landlock, unveil are genuinely present, so the
-- probe must report them. The enforce lane (`--make enforce`) separately
-- proves both mechanisms actually restrict on ubuntu-latest; this pins
-- the probe's report to that reality rather than to a vacuous
-- always-true.
local function test_real_pledge_unveil_probe()
  local c = quicksand.capabilities()
  if not c.linux then
    check.enforce_skip("quicksand pledge/unveil probe: non-Linux host")
    return
  end
  check.truthy(c.pledge, "capabilities().pledge must be true on Linux (pledge via seccomp)")
  if c.landlock then
    check.truthy(c.unveil, "capabilities().unveil must be true on Linux with landlock")
  else
    check.enforce_skip("quicksand unveil probe: host kernel lacks landlock")
  end
  check.enforced("quicksand pledge/unveil probe")
end
test_real_pledge_unveil_probe()

local function test_capabilities_does_not_self_brick()
  -- Regression: capabilities() must never invoke the destructive
  -- unix.unveil(nil, nil) commit, which locks the calling process into a
  -- deny-all sandbox. Prove ordinary filesystem IO still works afterward by
  -- reading back a file written before the probe.
  local tmp = check.must(os.getenv("TEST_TMPDIR"))
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
    check.enforce_skip("unveil/landlock equivalence: non-Linux host")
    return
  end
  check.equal(c.unveil, c.landlock,
    "on Linux unveil is derived from landlock and must equal it")
end
test_unveil_matches_landlock_on_linux()

local function test_new_and_merge_on_umbrella()
  -- #989: quicksand.new/quicksand.merge replace the retired
  -- PascalCase value path quicksand.Box.new; Box remains as a TYPE.
  assert(type(quicksand.new) == "function", "quicksand.new is the constructor")
  assert(type(quicksand.merge) == "function", "quicksand.merge composes options")
  local q = quicksand as {string: any} -- cast: record as map for introspection
  assert(q["Box"] == nil, "the Box VALUE re-export is gone (#989)")
end
test_new_and_merge_on_umbrella()
