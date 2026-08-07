#!/usr/bin/env cosmic
local sandbox = require("cosmic.sandbox")
local landlock = require("cosmic.landlock")
local pledge = require("cosmic.pledge")
local unveil = require("cosmic.unveil")
local sys = require("cosmic.sys")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(sandbox.apply) == "function", "apply should be a function")
  assert(type(sandbox.available) == "function", "available should be a function")
  assert(type(sandbox.validate) == "function", "validate should be a function")
  assert(type(sandbox.plan_landlock) == "function", "plan_landlock should be a function")
end
test_module_exports()

-- available() must agree with the mechanism modules it fronts.
local function test_available_agrees_with_mechanisms()
  local avail = sandbox.available()
  assert(type(avail.fs) == "boolean", "available().fs should be boolean")
  assert(type(avail.sys) == "boolean", "available().sys should be boolean")
  check.equal(avail.sys, pledge.available(), "sys must mirror pledge.available()")
  if sys.host_os() == "linux" then
    check.equal(avail.fs, landlock.available(), "fs must mirror landlock on Linux")
  else
    check.equal(avail.fs, unveil.available(), "fs must mirror unveil off Linux")
  end
end
test_available_agrees_with_mechanisms()

-- Structural validation happens before any enforcement, so rejected
-- policies are safe to exercise in-process: nothing may be applied.
local function test_validation_rejects_before_enforcing()
  -- cast: deliberate invalid input
  local apply_any = sandbox.apply as function(any): boolean, string

  local ok, err = apply_any(nil)
  assert(not ok and err:find("fs and/or sys", 1, true),
    "nil policy must be rejected: " .. tostring(err))

  ok, err = apply_any({})
  assert(not ok and err:find("fs and/or sys", 1, true),
    "empty policy must be rejected: " .. tostring(err))

  ok, err = apply_any({fs = {deny = {"/proc"}}})
  assert(not ok and err:find("deny", 1, true),
    "fs.deny must be rejected with a migration message: " .. tostring(err))

  ok, err = apply_any({fs = {ro = "x"}})
  assert(not ok and err:find("fs.ro", 1, true),
    "non-list fs group must be rejected: " .. tostring(err))

  -- A groupless fs section is ambiguous (deny-all or forgot-the-key?)
  -- and must be spelled explicitly: fs = { ro = {} } to deny, or no
  -- fs at all.
  ok, err = apply_any({fs = {}})
  assert(not ok and err:find("no groups", 1, true),
    "groupless fs must be rejected: " .. tostring(err))

  -- validate() is the same checker without enforcement, for callers
  -- (Box) that carry a policy across a process boundary.
  local vok, verr = sandbox.validate({sys = {promises = "stdio bogus_promise"}})
  assert(not vok and verr:find("bogus_promise", 1, true),
    "validate must reject what apply rejects: " .. tostring(verr))
  assert(sandbox.validate({fs = {ro = {"/tmp"}}}),
    "validate must accept a valid policy")

  ok, err = apply_any({sys = {promises = "stdio bogus_promise"}})
  assert(not ok and err:find("bogus_promise", 1, true),
    "unknown promise must be rejected by name: " .. tostring(err))

  -- The rejection above must have enforced nothing: this process can
  -- still read its own test tmpdir.
  local probe = fs.join(tmpdir, "validation_probe")
  assert(fs.write(probe, "ok"))
  local f = io.open(probe, "r")
  assert(f, "validation failures must not half-apply a sandbox")
  f:close()
end
test_validation_rejects_before_enforcing()

-- Every Promise enum value must be accepted by the validator (the
-- runtime PROMISES mirror and the enum must not drift apart), and the
-- validator must reject what the libc rejects.
local function test_promise_list_matches_validator()
  assert(#pledge.PROMISES > 0, "PROMISES must be non-empty")
  local all = table.concat(pledge.PROMISES as {string}, " ") -- cast: enum to strings
  -- Validation of a known-good promise string reaches the availability
  -- gate, never the "unknown promise" branch: prove it by pairing the
  -- valid string with an impossible fs section... on hosts where fs is
  -- unavailable the error names fs, not the promises. Where everything
  -- is available, validate indirectly via the subprocess tests below —
  -- here just assert the validator accepts each token by rejecting a
  -- string that appends one bogus token.
  -- cast: deliberate invalid input
  local apply_any = sandbox.apply as function(any): boolean, string
  local _, err = apply_any({sys = {promises = all .. " not_a_promise"}})
  assert(err and err:find("not_a_promise", 1, true),
    "only the bogus token may be rejected, got: " .. tostring(err))
end
test_promise_list_matches_validator()

-- Fail-closed + best_effort, exercisable in-process only on hosts
-- missing a mechanism (the check precedes any syscall).
local function test_fail_closed_when_unavailable()
  local avail = sandbox.available()
  local apply_any = sandbox.apply
  if avail.fs and avail.sys then
    check.enforce_skip("sandbox fully available on this host; fail-closed path not exercisable")
    return
  end
  if not avail.fs then
    local ok, err = apply_any({fs = {ro = {"/tmp"}}})
    assert(not ok and err:find("unsupported", 1, true),
      "fs section must fail closed: " .. tostring(err))
    -- A combined policy fails closed before ANY section applies, even
    -- ones this host could enforce.
    local ok2, err2 = apply_any({fs = {ro = {"/tmp"}}, sys = {promises = "stdio"}})
    assert(not ok2 and err2:find("unsupported", 1, true),
      "combined policy must fail closed on the missing section: " .. tostring(err2))
    -- best_effort skips the unenforceable section — and the returned
    -- report SAYS so, instead of a bare success.
    local enforced = check.must(
      sandbox.apply({fs = {ro = {"/tmp"}}, best_effort = true}))
    check.equal(enforced.fs, false, "the report must show fs was skipped")
  end
  if not avail.sys then
    local ok, err = apply_any({sys = {promises = "stdio"}})
    assert(not ok and err:find("unsupported", 1, true),
      "sys section must fail closed: " .. tostring(err))
  end
end
test_fail_closed_when_unavailable()

-- The fs -> landlock mapping, pure and inspectable (ported from the
-- deleted box/fs vocabulary this facade replaces).
local function find_rule(rules: {any}, path: string): {string: any}
  for _, r in ipairs(rules) do
    local rr = r as {string: any} -- cast: from any
    if rr.path == path then return rr end
  end
  return nil
end

local function test_plan_landlock_mapping()
  local plan_any = sandbox.plan_landlock

  -- ro means READ and nothing else: a directory of untrusted input
  -- must not become executable because its grant said "read-only".
  local opts = plan_any({ro = {"/srv/uploads"}})
  local r = find_rule(opts.rules, "/srv/uploads")
  assert(r, "expected /srv/uploads rule")
  check.equal(r.access, landlock.READ, "ro -> READ only")
  assert((r.access as integer & landlock.EXEC) == 0, -- cast: from any
    "ro must not grant EXEC")

  -- exec is the group that runs things: READ|EXEC.
  opts = plan_any({exec = {"/usr"}})
  r = find_rule(opts.rules, "/usr")
  assert(r, "expected /usr rule")
  check.equal(r.access, landlock.READ | landlock.EXEC, "exec -> READ|EXEC")

  opts = plan_any({rw = {"/tmp"}})
  r = find_rule(opts.rules, "/tmp")
  assert(r, "expected /tmp rule")
  check.equal(r.access, landlock.RW, "rw -> RW (no exec)")
  assert((landlock.RW & landlock.EXEC) == 0, "RW must not include EXEC")

  -- A path in several groups gets the union of their masks.
  opts = plan_any({exec = {"/shared"}, rw = {"/shared"}})
  r = find_rule(opts.rules, "/shared")
  assert(r, "expected /shared rule")
  check.equal(r.access, (landlock.READ | landlock.EXEC) | landlock.RW,
    "overlapping groups OR their masks")

  -- Empty policy plans to zero rules (deny-all when applied), full
  -- handled mask, and no_new_privs so it works unprivileged.
  opts = plan_any(nil)
  check.equal(#opts.rules, 0, "nil fs -> no rules")
  check.equal(opts.handled, landlock.ALL, "handled is ALL")
  check.equal(opts.no_new_privs, true, "no_new_privs defaults on")

  -- Rule order follows declaration order.
  opts = plan_any({ro = {"/a", "/b", "/c"}})
  local rules = opts.rules
  check.equal(rules[1].path, "/a")
  check.equal(rules[2].path, "/b")
  check.equal(rules[3].path, "/c")
end
test_plan_landlock_mapping()

-- plan_landlock's second parameter (keep_coverage) must be part of its
-- declared type, not just its implementation: the SandboxModule record
-- previously omitted it, so a typed caller passing it would fail to
-- type-check even though the runtime function accepted it.
local function test_plan_landlock_keep_coverage_param()
  local opts_default = sandbox.plan_landlock({ro = {"/usr"}})
  check.equal(opts_default.keep_coverage, false, "keep_coverage defaults false")

  local opts_kept = sandbox.plan_landlock({ro = {"/usr"}}, true)
  check.equal(opts_kept.keep_coverage, true, "keep_coverage=true must reach RestrictOptions")
end
test_plan_landlock_keep_coverage_param()

-- Live enforcement of a combined policy, in a subprocess (applying is
-- irreversible). Success also evidences the fs-before-sys ordering:
-- were pledge applied first, its filter would block the landlock
-- syscalls and apply would fail.
local function test_apply_enforces_fs_and_sys()
  local avail = sandbox.available()
  if not (avail.fs and avail.sys) then
    check.enforce_skip("sandbox fs+sys unavailable on this host")
    return
  end

  local allowed_dir = fs.join(tmpdir, "sbx")
  assert(fs.make_dirs(allowed_dir))
  local allowed = fs.join(allowed_dir, "ok.txt")
  local denied = fs.join(tmpdir, "outside.txt")
  assert(fs.write(allowed, "allowed-content"))
  assert(fs.write(denied, "denied-content"))

  local script = fs.join(tmpdir, "sandbox_apply.lua")
  assert(fs.write(script, string.format([[
local sandbox = require("cosmic.sandbox")
local ok, err = sandbox.apply({
  fs = { ro = { %q } },
  sys = { promises = "stdio rpath" },
})
if not ok then
  io.write("sandbox-blocked: " .. tostring(err) .. "\n")
  os.exit(0)
end
local f = io.open(%q, "r")
if f then io.write("allowed-ok\n"); f:close() else io.write("allowed-fail\n") end
local g = io.open(%q, "r")
if g then io.write("denied-leaked\n"); g:close() else io.write("denied-blocked\n") end
]], allowed_dir, allowed, denied)))

  local h = check.must(child.start({cosmic, script}))
  local r = check.must(h:wait())
  if r.signal ~= nil then
    check.enforce_skip("sandbox subprocess killed by signal " .. tostring(r.signal)
      .. " (outer sandbox)", true)
    return
  end
  local s = r.stdout or ""
  if s:find("sandbox-blocked:", 1, true) then
    -- available() said yes yet apply failed: an outer sandbox
    -- pre-empted it. Strict: a hard failure on the enforce lane.
    check.enforce_skip("sandbox.apply blocked by an outer sandbox: " .. s, true)
    return
  end
  assert(s:find("allowed-ok", 1, true), "allowed path should read: " .. s)
  assert(s:find("denied-blocked", 1, true),
    "path outside the allowlist must be blocked: " .. s)
  check.enforced("sandbox fs+sys")
end
test_apply_enforces_fs_and_sys()

-- A bogus promise next to a valid fs section must reject before the
-- fs section enforces: the subprocess proves it can still read
-- everything afterwards.
local function test_invalid_sys_leaves_fs_unapplied()
  local avail = sandbox.available()
  if not avail.fs then
    check.enforce_skip("sandbox fs unavailable on this host")
    return
  end

  local dir = fs.join(tmpdir, "novalid")
  assert(fs.make_dirs(dir))
  local outside = fs.join(tmpdir, "still_readable.txt")
  assert(fs.write(outside, "yes"))

  local script = fs.join(tmpdir, "sandbox_validate.lua")
  assert(fs.write(script, string.format([[
local sandbox = require("cosmic.sandbox")
local ok, err = sandbox.apply({
  fs = { ro = { %q } },
  sys = { promises = "stdio bogus_promise" },
})
if ok or not tostring(err):find("bogus_promise", 1, true) then
  io.write("bad-verdict: " .. tostring(ok) .. " " .. tostring(err) .. "\n")
  os.exit(0)
end
local f = io.open(%q, "r")
if f then io.write("unapplied-ok\n"); f:close() else io.write("half-applied\n") end
]], dir, outside)))

  local h = check.must(child.start({cosmic, script}))
  local r = check.must(h:wait())
  if r.signal ~= nil then return end
  local s = r.stdout or ""
  assert(s:find("unapplied-ok", 1, true),
    "a rejected policy must enforce nothing: " .. s)
end
test_invalid_sys_leaves_fs_unapplied()
