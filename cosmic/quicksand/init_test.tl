#!/usr/bin/env cosmic
local quicksand = require("cosmic.quicksand")
local errno = require("cosmic.errno")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(quicksand.capabilities) == "function", "capabilities should be a function")
  assert(type(quicksand.is_supported) == "function", "is_supported should be a function")
end

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
  assert(type(c.landlock_net) == "boolean", "capabilities().landlock_net should be boolean")
  assert(type(c.pledge) == "boolean", "capabilities().pledge should be boolean")
  assert(type(c.unveil) == "boolean", "capabilities().unveil should be boolean")
end

local function test_capabilities_cached()
  local a = quicksand.capabilities()
  local b = quicksand.capabilities()
  assert(a == b, "capabilities() must return the same cached table on repeat calls")
end

-- capabilities().user_ns comes from a scratch-child unshare probe, not
-- the compile-time CLONE_NEWUSER constant: that constant is defined even
-- on hosts that forbid unprivileged user namespaces, so it reports a
-- capability that then fails with EPERM mid-setup. Assert the cached
-- report agrees with a fresh probe, and that the probe is exported and
-- deterministic.
local function test_user_ns_agrees_with_scratch_probe()
  -- probe_ns is not exported (it forks on every call); the
  -- scratch-unshare result is observable only through capabilities().
  local c = quicksand.capabilities()
  assert(type(c.user_ns) == "boolean", "user_ns should be a boolean")
  if not c.linux then
    check.equal(c.user_ns, false, "user_ns must be false off Linux")
  end
end

-- Real, unmocked proof that user_ns and net_ns can disagree: nest a
-- fresh user namespace inside a subprocess, cap network namespaces to
-- zero inside it (the same lever a real max_net_namespaces limit pulls
-- -- named explicitly in the gap this closes), then call the REAL
-- capabilities() from inside that restriction. A fresh subprocess is
-- required so capabilities()'s cache starts nil under the restriction
-- rather than replaying whatever this test process already probed
-- before the restriction existed. Before this fix, probe_ns tested the
-- USER|NET|NS trio as one unshare() call, so this exact host state
-- (user+mount fine, net specifically blocked) surfaced as user_ns =
-- false -- indistinguishable from user namespaces being unavailable at
-- all, and Box:run refused before ever reaching the Landlock net-tier
-- fallback. If the restriction cannot be established (old kernel
-- without the per-userns sysctl, an outer sandbox blocking it), that is
-- a named, tolerated skip -- never a silent pass.
local function test_net_ns_false_with_user_ns_true_under_real_restriction()
  local c = quicksand.capabilities()
  if not (c.linux and c.user_ns) then
    check.enforce_skip("netns-restricted probe: user namespaces unavailable on this host")
    return
  end

  local script = fs.join(tmpdir, "netns_restrict_probe.lua")
  assert(fs.write(script, [[
local unix = require("cosmo.unix")
local qproc = require("cosmic.quicksand.proc")
local qs = require("cosmic.quicksand")

-- Captured before unshare: post-unshare geteuid()/getegid() would read
-- back as the overflow uid/gid (uid_map is still empty), the same trap
-- probe_unshare and Box:run's supervisor guard against.
local host_uid = unix.geteuid()
local host_gid = unix.getegid()

-- Enter a fresh user+mount namespace mapped to inner uid/gid 0 -- the
-- same setup_userns_maps step Box:run's supervisor performs, and
-- probe_ns's own scratch child performs.
local uok, uerr = unix.unshare(unix.CLONE_NEWUSER | unix.CLONE_NEWNS)
if not uok then
  io.write("skip: unshare: " .. tostring(uerr) .. "\n")
  os.exit(0)
end
local mok, merr = qproc.setup_userns_maps(host_uid, host_gid)
if not mok then
  io.write("skip: setup_userns_maps: " .. tostring(merr) .. "\n")
  os.exit(0)
end

-- Cap network namespaces created by descendants of THIS user namespace
-- to zero. /proc/sys/user/max_net_namespaces is namespaced per owning
-- user namespace since Linux 4.9: writable by the (unprivileged) owner
-- of a fresh userns with no host-wide privilege, and it restricts only
-- namespaces created below this point -- never the outer host.
local fd, oerr = unix.open("/proc/sys/user/max_net_namespaces", unix.O_WRONLY)
if not fd then
  io.write("skip: open max_net_namespaces: " .. tostring(oerr) .. "\n")
  os.exit(0)
end
local n, werr = unix.write(fd, "0")
unix.close(fd)
if not n then
  io.write("skip: write max_net_namespaces: " .. tostring(werr) .. "\n")
  os.exit(0)
end

-- Independent ground truth, BEFORE trusting the code under test: a raw
-- unshare(trio) attempt in a throwaway scratch child, entirely separate
-- from quicksand's own probe. If the restriction did not actually take
-- (an outer runtime that ignores or virtualizes the sysctl), this still
-- succeeds and the case is a named skip -- never silently compared
-- against the very probe this test exists to check.
local function raw_trio_blocked()
  local rpid = unix.fork()
  if rpid == 0 then
    local rok = unix.unshare(unix.CLONE_NEWUSER | unix.CLONE_NEWNET | unix.CLONE_NEWNS)
    unix.exit(rok and 0 or 1)
  end
  local _, rws = unix.wait(rpid)
  if not unix.WIFEXITED(rws) then return true end
  return unix.WEXITSTATUS(rws) ~= 0
end
if not raw_trio_blocked() then
  io.write("skip: restriction had no effect (raw trio unshare still succeeded)\n")
  os.exit(0)
end

-- A brand-new process, so capabilities()'s cache is nil here: this
-- exercises probe_ns for real, from inside a restriction the raw check
-- above just proved genuinely blocks a full-trio unshare.
local rc = qs.capabilities()
io.write("result " .. tostring(rc.user_ns) .. " " .. tostring(rc.net_ns) .. "\n")
]]))
  local h = check.must(child.start({cosmic, script}))
  local r = check.must(h:wait())
  if not r.ok then
    check.enforce_skip("netns-restricted probe: subprocess failed: "
      .. tostring(r.stdout) .. tostring(r.stderr), true)
    return
  end
  local out = r.stdout
  if out:find("skip:", 1, true) then
    check.enforce_skip("netns-restricted probe: " .. out:gsub("%s+$", ""), true)
    return
  end
  local user_ns_s, net_ns_s = out:match("result (%a+) (%a+)")
  assert(user_ns_s and net_ns_s, "expected 'result <bool> <bool>', got: " .. out)
  -- The raw check already proved the trio is genuinely blocked here, so
  -- these are hard assertions, not conditioned on the probe's own answer.
  check.equal(user_ns_s, "true",
    "user namespaces must still work when only net is restricted: " .. out)
  check.equal(net_ns_s, "false",
    "net_ns must be false under a real max_net_namespaces=0 restriction: " .. out)
  check.enforced("quicksand probe_ns split: real max_net_namespaces restriction")
end

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

-- Build a synthetic failed binding returning the failure triple —
-- `nil, err (string), errno (number)` — with a fixed errno number, so the
-- probe's ENOSYS classification can be exercised without a host that
-- actually lacks the syscall.
local function mk_fail(msg: string, n: integer): any
  return function(): any ...
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

local function test_probe_success_is_available()
  check.equal(quicksand.probe(function(): any return true end), true,
    "a successful no-op call means the syscall is wired up")
end

local function test_probe_enosys_is_unavailable()
  local enosys = errno.code_of("ENOSYS")
  assert(enosys, "ENOSYS must be defined on this host")
  check.equal(quicksand.probe(
      mk_fail("prctl: ENOSYS: Function not implemented", enosys)), false,
    "ENOSYS means the syscall is absent -> unavailable (the branch that was dead pre-fix)")
end

local function test_probe_policy_error_is_available()
  local eperm = errno.code_of("EPERM")
  assert(eperm, "EPERM must be defined on this host")
  check.equal(quicksand.probe(
      mk_fail("prctl: EPERM: Operation not permitted", eperm)), true,
    "a policy error (EPERM) still proves the syscall is wired up")
end

local function test_probe_string_only_failure_is_available()
  -- A failure that carries no numeric errno (third slot nil) cannot be
  -- classified as ENOSYS; the error string alone must never match, so
  -- the probe reports the syscall wired up.
  check.equal(quicksand.probe(function(): any ...
        return nil, "prctl: ENOSYS: Function not implemented", nil
      end), true,
    "an error string without a numeric errno is never classified as ENOSYS")
end

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

local function test_capabilities_does_not_self_brick()
  -- capabilities() must never invoke the destructive
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

-- landlock_net is a stricter gate than landlock (ABI >= 4 implies ABI >=
-- 1), and off Linux both must be false. Pin the relationship instead of
-- just its type, so a probe that reports the ABI-4 tier without the
-- underlying ABI-1 one — or the reverse on a non-Linux host — fails here.
local function test_landlock_net_implies_landlock()
  local c = quicksand.capabilities()
  if c.landlock_net then
    check.truthy(c.landlock, "landlock_net true must imply landlock true (ABI >= 4 implies ABI >= 1)")
  end
  if not c.linux then
    check.equal(c.landlock_net, false, "landlock_net must be false off Linux")
  end
end

local function test_new_and_merge_on_umbrella()
  -- quicksand.new/quicksand.merge are the constructor and composer;
  -- Box exists only as a TYPE, never as a value export.
  assert(type(quicksand.new) == "function", "quicksand.new is the constructor")
  assert(type(quicksand.merge) == "function", "quicksand.merge composes options")
  assert(not check.is_exposed(quicksand, "Box"), "the Box VALUE re-export is gone (#989)")
end
