#!/usr/bin/env cosmic
local sandbox = require("cosmic.sandbox")
local plan = require("cosmic.sandbox.plan")
local landlock = require("cosmic.sandbox.landlock")
local pledge = require("cosmic.sandbox.pledge")
local unveil = require("cosmic.sandbox.unveil")
local sys = require("cosmic.sys")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(sandbox.apply) == "function", "apply should be a function")
  assert(type(sandbox.availability) == "function", "availability should be a function")
  assert(type(sandbox.is_available) == "function", "is_available should be a function")
  assert(type(sandbox.validate) == "function", "validate should be a function")
  assert(type(sandbox.merge) == "function", "merge should be a function")
  assert(not check.is_exposed(sandbox, "plan_landlock"),
    "plan_landlock left the public surface (#989: cosmic.sandbox.plan)")
  assert(not check.is_exposed(sandbox, "available"),
    "the deprecated available alias is gone (#989); availability() is the name")
end

-- availability() must agree with the mechanism shards it fronts, and
-- is_available() is their conjunction.
local function test_availability_agrees_with_mechanisms()
  local avail = sandbox.availability()
  assert(type(avail.fs.available) == "boolean",
    "availability().fs.available should be boolean")
  assert(type(avail.sys.available) == "boolean",
    "availability().sys.available should be boolean")
  check.equal(avail.sys.available, pledge.available(),
    "sys must mirror pledge.available()")
  check.equal(avail.sys.mechanism, "pledge", "sys mechanism must be pledge")
  if sys.host_os() == "linux" then
    check.equal(avail.fs.available, landlock.available(),
      "fs must mirror landlock on Linux")
    check.equal(avail.fs.mechanism, "landlock", "fs mechanism must be landlock on Linux")
  else
    check.equal(avail.fs.available, unveil.available(),
      "fs must mirror unveil off Linux")
    check.equal(avail.fs.mechanism, "unveil", "fs mechanism must be unveil off Linux")
  end
  check.equal(sandbox.is_available(), avail.fs.available and avail.sys.available,
    "is_available is the per-section conjunction")
end

-- Structural validation happens before any enforcement, so rejected
-- policies are safe to exercise in-process: nothing may be applied.
local function test_validation_rejects_before_enforcing()
  local err = check.refuses(sandbox.apply, nil)
  assert(err:find("fs and/or sys", 1, true),
    "nil policy must be rejected: " .. err)

  err = check.refuses(sandbox.apply, {})
  assert(err:find("fs and/or sys", 1, true),
    "empty policy must be rejected: " .. err)

  err = check.refuses(sandbox.apply, {fs = {deny = {"/proc"}}})
  assert(err:find("deny", 1, true),
    "fs.deny must be rejected with a migration message: " .. err)

  err = check.refuses(sandbox.apply, {fs = {ro = "x"}})
  assert(err:find("fs.ro", 1, true),
    "non-list fs group must be rejected: " .. err)

  -- Using `exec` instead of `exec_promises` must be rejected: silently
  -- accepting it would validate the policy and then run exec'd
  -- children with NO promises — a silent widening, in the one module
  -- whose headline is fail-closed.
  err = check.refuses(sandbox.apply, {sys = {promises = "stdio", exec = "stdio"}})
  assert(err:find("exec_promises", 1, true),
    "sys.exec must be rejected with a migration message: " .. err)

  -- A groupless fs section is ambiguous (deny-all or forgot-the-key?)
  -- and must be spelled explicitly: fs = { ro = {} } to deny, or no
  -- fs at all.
  err = check.refuses(sandbox.apply, {fs = {}})
  assert(err:find("no groups", 1, true),
    "groupless fs must be rejected: " .. err)

  -- strict and best_effort contradict: strict already refuses any gap,
  -- so best_effort's "skip instead of failing" would never trigger.
  err = check.refuses(sandbox.apply,
    {fs = {ro = {"/tmp"}}, strict = true, best_effort = true})
  assert(err:find("strict", 1, true) and err:find("best_effort", 1, true),
    "strict + best_effort must be rejected: " .. err)

  -- strict and allow_unenforced contradict for the same reason:
  -- tolerating an all-skipped result is meaningless once strict
  -- already refuses any single skipped section.
  err = check.refuses(sandbox.apply,
    {fs = {ro = {"/tmp"}}, strict = true, allow_unenforced = true})
  assert(err:find("strict", 1, true) and err:find("allow_unenforced", 1, true),
    "strict + allow_unenforced must be rejected: " .. err)

  -- allow_unenforced only ever has something to tolerate when
  -- best_effort produced a "skipped" section in the first place.
  err = check.refuses(sandbox.apply, {fs = {ro = {"/tmp"}}, allow_unenforced = true})
  assert(err:find("allow_unenforced", 1, true) and err:find("best_effort", 1, true),
    "allow_unenforced without best_effort must be rejected: " .. err)

  -- validate() is the same checker without enforcement, for callers
  -- (Box) that carry a policy across a process boundary.
  local vok, verr = sandbox.validate({sys = {promises = "stdio bogus_promise"}})
  assert(not vok and verr:find("bogus_promise", 1, true),
    "validate must reject what apply rejects: " .. tostring(verr))
  assert(sandbox.validate({fs = {ro = {"/tmp"}}}),
    "validate must accept a valid policy")

  err = check.refuses(sandbox.apply, {sys = {promises = "stdio bogus_promise"}})
  assert(err:find("bogus_promise", 1, true),
    "unknown promise must be rejected by name: " .. err)

  -- The rejection above must have enforced nothing: this process can
  -- still read its own test tmpdir.
  local probe = fs.join(tmpdir, "validation_probe")
  assert(fs.write(probe, "ok"))
  local f = io.open(probe, "r")
  assert(f, "validation failures must not half-apply a sandbox")
  f:close()
end

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
  local err = check.refuses(sandbox.apply, {sys = {promises = all .. " not_a_promise"}})
  assert(err:find("not_a_promise", 1, true),
    "only the bogus token may be rejected, got: " .. err)
end

-- Fail-closed + best_effort, exercisable in-process only on hosts
-- missing a mechanism (the check precedes any syscall).
local function test_fail_closed_when_unavailable()
  local avail = sandbox.availability()
  local apply_any = sandbox.apply
  if avail.fs.available and avail.sys.available then
    check.enforce_skip("sandbox fully available on this host; fail-closed path not exercisable")
    return
  end
  if not avail.fs.available then
    local ok, err = apply_any({fs = {ro = {"/tmp"}}})
    assert(not ok and err:find("unsupported", 1, true),
      "fs section must fail closed: " .. tostring(err))
    -- A combined policy fails closed before ANY section applies, even
    -- ones this host could enforce.
    local ok2, err2 = apply_any({fs = {ro = {"/tmp"}}, sys = {promises = "stdio"}})
    assert(not ok2 and err2:find("unsupported", 1, true),
      "combined policy must fail closed on the missing section: " .. tostring(err2))
    -- best_effort skips the unenforceable section, and with nothing
    -- else requested apply refuses outright rather than returning a
    -- report nobody asked to trust as success (the footgun this
    -- change closes) — unless allow_unenforced says otherwise.
    local ok3, err3 = apply_any({fs = {ro = {"/tmp"}}, best_effort = true})
    assert(not ok3 and err3:find("nothing enforced", 1, true),
      "an all-skipped best_effort apply must refuse by default: " .. tostring(err3))
    local enforced = check.must(sandbox.apply({fs = {ro = {"/tmp"}},
          best_effort = true, allow_unenforced = true}))
    check.equal(enforced.fs.state, "skipped", "the report must show fs was skipped")
  end
  if not avail.sys.available then
    local ok, err = apply_any({sys = {promises = "stdio"}})
    assert(not ok and err:find("unsupported", 1, true),
      "sys section must fail closed: " .. tostring(err))
  end
end

-- The full/degraded/strict reporting exercised here depends on THIS
-- kernel's Landlock ABI (full on ABI >= 3, degraded below it, and
-- strict's pre-check reads the same ABI) -- facts this sandbox's own
-- host cannot promise either way. Monkeypatching the landlock shard's
-- available()/abi()/restrict() (the same module table cosmic.sandbox
-- already required, since require() caches it) exercises every branch
-- deterministically on any host, Landlock or not, rather than skipping
-- the report-building logic itself wherever the live kernel disagrees.
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

local function test_apply_reports_full_landlock_enforcement()
  if sys.host_os() ~= "linux" then
    check.enforce_skip("landlock is the Linux-only fs mechanism")
    return
  end
  with_mock_landlock({
      available = function(): boolean return true end,
      restrict = function(_opts: landlock.RestrictOptions): landlock.Enforcement | nil, string
        return {abi = 3, handled = landlock.ALL, stripped = 0}
      end,
    }, function(): boolean
      local report = check.must(sandbox.apply({fs = {ro = {"/tmp"}}}))
      check.equal(report.fs.state, "full", "abi 3, nothing stripped -> full")
      check.equal(report.fs.mechanism, "landlock", "mechanism must name landlock")
      check.equal(report.fs.abi, 3, "abi must carry through from Enforcement")
      check.equal(report.fs.missing, "", "missing must be empty when full")
      return true
    end)
end

local function test_apply_reports_degraded_landlock_enforcement()
  if sys.host_os() ~= "linux" then
    check.enforce_skip("landlock is the Linux-only fs mechanism")
    return
  end
  with_mock_landlock({
      available = function(): boolean return true end,
      restrict = function(_opts: landlock.RestrictOptions): landlock.Enforcement | nil, string
        return {abi = 2, handled = landlock.ALL & ~ landlock.TRUNCATE,
          stripped = landlock.TRUNCATE}
      end,
    }, function(): boolean
      local report = check.must(sandbox.apply({fs = {ro = {"/tmp"}}}))
      -- The old two-boolean Availability read this exact shape (a
      -- landlock restrict that succeeded but stripped rights) as plain
      -- `true` -- the same value a fully-capable kernel gets. This is
      -- the epic's defect 4, and the assertion below is the fix.
      check.equal(report.fs.state, "degraded",
        "a landlock restrict that stripped rights must report degraded, not full")
      assert(report.fs.missing:find("TRUNCATE", 1, true),
        "missing must name what this kernel's ABI stripped: " .. report.fs.missing)
      return true
    end)
end

-- strict must refuse a would-be-degraded restrict BEFORE calling it --
-- enforcement is irreversible, so there is no applying it and then
-- refusing. restrict() erroring if strict calls it anyway is the
-- guard: it proves the refusal happens strictly before enforcement.
local function test_strict_refuses_a_would_be_degraded_restrict_before_applying()
  if sys.host_os() ~= "linux" then
    check.enforce_skip("landlock is the Linux-only fs mechanism")
    return
  end
  with_mock_landlock({
      available = function(): boolean return true end,
      abi = function(): integer | nil, string return 2 end,
      restrict = function(_opts: landlock.RestrictOptions): landlock.Enforcement | nil, string
        error("strict must refuse before restrict() is ever called")
      end,
    }, function(): boolean
      local ok, err = sandbox.apply({fs = {ro = {"/tmp"}}, strict = true})
      assert(not ok and err:find("degraded", 1, true),
        "strict must refuse a would-be-degraded fs section: " .. tostring(err))
      return true
    end)
end

-- The fs -> landlock mapping, pure and inspectable (ported from the
-- deleted box/fs vocabulary this facade replaces).
local function find_rule(rules: {landlock.Rule}, path: string): landlock.Rule
  for _, r in ipairs(rules) do
    if r.path == path then return r end
  end
  return nil
end

local function test_plan_landlock_mapping()
  local plan_any = plan.for_landlock

  -- ro means READ and nothing else: a directory of untrusted input
  -- must not become executable because its grant said "read-only".
  local opts = plan_any({ro = {"/srv/uploads"}})
  local r = find_rule(opts.rules, "/srv/uploads")
  assert(r, "expected /srv/uploads rule")
  check.equal(r.access, landlock.READ, "ro -> READ only")
  assert((r.access & landlock.EXEC) == 0,
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

-- The no_new_privs tuning flag must reach the planned RestrictOptions;
-- handled is no longer a facade/plan concern (R3) so the plan always
-- requests the full landlock.ALL mask.
local function test_plan_tuning_flags()
  local opts_default = plan.for_landlock({ro = {"/usr"}})
  check.equal(opts_default.no_new_privs, true, "no_new_privs defaults on")
  check.equal(opts_default.handled, landlock.ALL, "handled is always ALL from the plan")

  local tuned = plan.for_landlock({ro = {"/usr"}}, false)
  check.equal(tuned.no_new_privs, false, "no_new_privs=false must reach the plan")
  check.equal(tuned.handled, landlock.ALL, "handled stays ALL regardless of no_new_privs")
end

-- fs.optional rides each planned rule: the skip happens at open time
-- inside landlock.restrict (never a pre-check, which would race), so
-- the plan's only job is to stamp the flag through.
local function test_plan_stamps_optional_onto_rules()
  local opts = plan.for_landlock({ro = {"/a"}, rw = {"/b"}, optional = true})
  for _, r in ipairs(opts.rules) do
    assert(r.optional == true, r.path .. " should carry optional")
  end
  opts = plan.for_landlock({ro = {"/a"}})
  for _, r in ipairs(opts.rules) do
    assert(not r.optional, r.path .. " should not carry optional")
  end
end

-- exec_promises is named to avoid reading as a path list beside
-- fs.exec; the validator checks its tokens like promises.
local function test_exec_promises_validated()
  local vok, verr = sandbox.validate(
    {sys = {promises = "stdio", exec_promises = "stdio bogus_tok"}})
  assert(not vok and verr:find("bogus_tok", 1, true),
    "exec_promises tokens must be validated: " .. tostring(verr))
  assert(sandbox.validate({sys = {promises = "stdio", exec_promises = "stdio"}}),
    "valid exec_promises must pass")
end

-- fs.optional tolerates missing paths at rule-open time instead of
-- failing the whole policy; visible through merge + validate (the
-- open-time skip is exercised by the landlock tests where this host
-- enforces).
local function test_merge_composes_policies()
  local merged = sandbox.merge(
    {fs = {ro = {"/etc"}, exec = {"/usr"}}, best_effort = true},
    {fs = {ro = {"/etc", "/srv"}, optional = true}, sys = {promises = "stdio"}})
  assert(merged.fs, "merged policy carries fs")
  check.equal(#merged.fs.ro, 2, "ro lists concat and dedupe")
  check.equal(merged.fs.ro[1], "/etc", "order is first-seen")
  check.equal(merged.fs.ro[2], "/srv", "later list appends")
  check.equal(#merged.fs.exec, 1, "unmerged groups survive")
  check.equal(merged.fs.optional, true, "optional is set by the later policy")
  check.equal(merged.best_effort, true, "scalars persist from the earlier policy")
  assert(merged.sys and merged.sys.promises == "stdio", "sys merges in")
  assert(sandbox.validate(merged), "the merged policy validates")

  -- allow_unenforced and strict are scalars like best_effort: the
  -- later policy's value wins when set, an unset one leaves the
  -- earlier value alone.
  local later = sandbox.merge(
    {fs = {ro = {"/etc"}}, allow_unenforced = true, best_effort = true},
    {fs = {ro = {"/srv"}}})
  check.equal(later.allow_unenforced, true,
    "allow_unenforced persists when the later policy leaves it unset")
  local overridden = sandbox.merge(
    {fs = {ro = {"/etc"}}, strict = true},
    {fs = {ro = {"/srv"}}, strict = false})
  check.equal(overridden.strict, false,
    "a later explicit strict = false must override an earlier true")
end

-- Live enforcement of a combined policy, in a subprocess (applying is
-- irreversible). Success also evidences the fs-before-sys ordering:
-- were pledge applied first, its filter would block the landlock
-- syscalls and apply would fail.
local function test_apply_enforces_fs_and_sys()
  local avail = sandbox.availability()
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

-- A bogus promise next to a valid fs section must reject before the
-- fs section enforces: the subprocess proves it can still read
-- everything afterwards.
local function test_invalid_sys_leaves_fs_unapplied()
  local avail = sandbox.availability()
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
