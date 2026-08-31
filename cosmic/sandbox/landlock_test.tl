#!/usr/bin/env cosmic
local landlock = require("cosmic.sandbox.landlock")
local fs = require("cosmic.fs")
local child = require("cosmic.child")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(landlock.restrict) == "function", "restrict should be a function")
  assert(type(landlock.abi) == "function", "abi should be a function")
  assert(type(landlock.available) == "function", "available should be a function")
  assert(type(landlock.READ) == "number", "READ should be a number constant")
  assert(type(landlock.EXEC) == "number", "EXEC should be a number constant")
  assert(type(landlock.RW) == "number", "RW should be a number constant")
  assert(type(landlock.ALL) == "number", "ALL should be a number constant")
  -- The ABI 5-9 additions: device ioctl, domain scoping, and the
  -- restrict_self all-threads flag, all reachable as module constants
  -- the same way the ABI 1-4 rights are.
  assert(type(landlock.IOCTL_DEV) == "number", "IOCTL_DEV should be a number constant")
  assert(type(landlock.SCOPE_SIGNAL) == "number", "SCOPE_SIGNAL should be a number constant")
  assert(type(landlock.SCOPE_ABSTRACT_UNIX_SOCKET) == "number",
    "SCOPE_ABSTRACT_UNIX_SOCKET should be a number constant")
  assert(type(landlock.SCOPE_ALL) == "number", "SCOPE_ALL should be a number constant")
  assert(type(landlock.TSYNC) == "number", "TSYNC should be a number constant")
  assert(type(landlock.RESOLVE_UNIX) == "number", "RESOLVE_UNIX should be a number constant")
end

local function test_access_mask_composition()
  -- READ must include READ_FILE and READ_DIR; the underlying module
  -- already composes them, but verify the relationship holds.
  assert((landlock.READ & landlock.READ_FILE) == landlock.READ_FILE,
    "READ should include READ_FILE")
  assert((landlock.READ & landlock.READ_DIR) == landlock.READ_DIR,
    "READ should include READ_DIR")
  assert((landlock.RW & landlock.READ) == landlock.READ,
    "RW should include READ")
  assert((landlock.ALL & landlock.RW) == landlock.RW,
    "ALL should include RW")
  -- Every right `ALL` HANDLES and a write needs, `RW` must GRANT.
  -- Truncate is the one that got away: it became a separate right in
  -- ABI 3, `ALL` picked it up as handled, and `RW` did not -- so a
  -- granted directory could create a file and never rewrite one.
  -- Rewriting is what a build does on its second run.
  assert((landlock.RW & landlock.TRUNCATE) == landlock.TRUNCATE,
    "RW must include TRUNCATE, or rw means write-once")
  -- REFER is the same shape one ABI earlier: handled by ALL, and
  -- without it in the grant, rename(2) between two directories of a
  -- granted rw tree fails EXDEV — rw would mean create-but-never-move,
  -- and git (whose object store finalizes by cross-directory rename)
  -- cannot run in a fenced rw tree.
  assert((landlock.RW & landlock.REFER) == landlock.REFER,
    "RW must include REFER, or rw means never-move")
  -- RW is read + write only: it must NOT silently grant execute, or a
  -- box's rw path (e.g. /tmp) would become write+exec (a sandbox
  -- weakening the caller never asked for).
  assert((landlock.RW & landlock.EXEC) == 0,
    "RW must not include EXEC")
  assert((landlock.RW & landlock.WRITE_FILE) == landlock.WRITE_FILE,
    "RW should include WRITE_FILE")
  -- IOCTL_DEV rides WRITE like TRUNCATE/REFER: an rw grant on a device
  -- node must include the right to drive it (R2), not just open it.
  assert((landlock.RW & landlock.IOCTL_DEV) == landlock.IOCTL_DEV,
    "RW must include IOCTL_DEV, or rw on a device node means open-only")
  assert((landlock.ALL & landlock.IOCTL_DEV) == landlock.IOCTL_DEV,
    "ALL should include IOCTL_DEV")
  -- RESOLVE_UNIX follows the identical pattern one ABI further.
  assert((landlock.RW & landlock.RESOLVE_UNIX) == landlock.RESOLVE_UNIX,
    "RW must include RESOLVE_UNIX")
  assert((landlock.ALL & landlock.RESOLVE_UNIX) == landlock.RESOLVE_UNIX,
    "ALL should include RESOLVE_UNIX")
  -- Both scope categories compose into SCOPE_ALL, mirroring NET_ALL.
  assert((landlock.SCOPE_ALL & landlock.SCOPE_SIGNAL) == landlock.SCOPE_SIGNAL,
    "SCOPE_ALL should include SCOPE_SIGNAL")
  assert((landlock.SCOPE_ALL & landlock.SCOPE_ABSTRACT_UNIX_SOCKET)
    == landlock.SCOPE_ABSTRACT_UNIX_SOCKET,
    "SCOPE_ALL should include SCOPE_ABSTRACT_UNIX_SOCKET")
end

local function test_available_returns_boolean()
  local v = landlock.available()
  assert(type(v) == "boolean", "available() should return a boolean, got " .. type(v))
end

-- Applied landlock can't be undone, so run restrict() in a subprocess.
local function test_restrict_denies_outside_allowlist()
  if not landlock.available() then
    -- Kernel lacks landlock; skip the live enforcement check but assert
    -- that abi() consistently reports the limitation. A genuine platform
    -- gap: soft skip even on the enforce lane (an old kernel can't be
    -- made to enforce).
    local v, err = landlock.abi()
    assert(v == nil, "abi() should return nil when landlock is unavailable")
    assert(err, "abi() should return an error string when unavailable")
    check.enforce_skip("landlock unavailable (kernel lacks landlock)")
    return
  end

  -- Allowlist a *directory* subtree, not a bare file: ll.READ bundles
  -- READ_DIR, and landlock returns EINVAL if a directory-only right is
  -- added on a regular file. So the allowed path is a directory and the
  -- denied file is a sibling left outside it (both exist, so the denial is
  -- a real landlock effect rather than a missing path).
  local allowed_dir = fs.join(tmpdir, "allowed")
  assert(fs.make_dirs(allowed_dir))
  local allowed = fs.join(allowed_dir, "ok.txt")
  local denied = fs.join(tmpdir, "denied.txt")
  assert(fs.write(allowed, "allowed-content"))
  assert(fs.write(denied, "denied-content"))

  local script = fs.join(tmpdir, "landlock_restrict.lua")
  assert(fs.write(script, string.format([[
local ll = require("cosmic.sandbox.landlock")
local ok, err = ll.restrict{ rules = { { path = %q, access = ll.READ } } }
if not ok then
  -- An outer sandbox (pledge/seccomp) may block the landlock syscall
  -- even when the kernel supports it. Report skipped so the parent can
  -- tolerate running under CI sandboxes.
  io.write("skipped: " .. tostring(err) .. "\n")
  os.exit(0)
end

-- Reading a file inside the allowed directory must still work.
local f = io.open(%q, "r")
if f then io.write("allowed-ok\n"); f:close() else io.write("allowed-fail\n") end

-- Reading the sibling outside the allowed directory must fail.
local g = io.open(%q, "r")
if g then io.write("denied-leaked\n"); g:close() else io.write("denied-blocked\n") end
]], allowed_dir, allowed, denied)))

  -- landlock probed available here, so any failure to enforce below means
  -- an outer sandbox is blocking an otherwise-supported mechanism — a
  -- strict skip that the enforce lane (COSMIC_ENFORCE=1, no outer sandbox)
  -- turns into a hard failure.
  local h = check.must(child.start({cosmic, script}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  -- Under an outer seccomp/pledge filter the landlock syscall may be
  -- blocked with SIGSYS rather than EPERM, killing the subprocess
  -- before it can emit "skipped".
  if not ok then
    check.enforce_skip("landlock restrict blocked (subprocess died before enforcing)", true)
    return
  end
  local s = out
  if s:find("skipped") then
    check.enforce_skip("landlock restrict blocked: " .. s, true)
    return
  end
  -- Plain-text find: "-" is a Lua pattern metacharacter, so a pattern
  -- search for "allowed-ok" would not match the literal marker.
  assert(s:find("allowed-ok", 1, true), "allowed path should still read: " .. s)
  assert(s:find("denied-blocked", 1, true), "denied path must be blocked: " .. s)
  check.enforced("landlock")
end

-- A rule whose path is a regular file must work with the composite
-- READ mask: READ bundles READ_DIR, and the kernel EINVALs a
-- directory-only right attached to a non-directory — restrict() must
-- mask file rules down to the file-applicable bits (as the C unveil
-- path does) instead of failing opaquely. Enforcement is irreversible,
-- so the live check runs in a subprocess.
local function test_restrict_single_file_rule()
  if not landlock.available() then
    check.enforce_skip("landlock unavailable (kernel lacks landlock)")
    return
  end

  local dir = fs.join(tmpdir, "filerule")
  assert(fs.make_dirs(dir))
  local target = fs.join(dir, "target.txt")
  local sibling = fs.join(dir, "sibling.txt")
  assert(fs.write(target, "target-content"))
  assert(fs.write(sibling, "sibling-content"))

  local script = fs.join(tmpdir, "landlock_filerule.lua")
  assert(fs.write(script, string.format([[
local ll = require("cosmic.sandbox.landlock")
local ok, err = ll.restrict{ rules = { { path = %q, access = ll.READ } } }
if not ok then
  io.write("restrict-failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
local f = io.open(%q, "r")
if f then io.write("file-ok\n"); f:close() else io.write("file-fail\n") end
local g = io.open(%q, "r")
if g then io.write("sibling-leaked\n"); g:close() else io.write("sibling-blocked\n") end
]], target, target, sibling)))

  local h = check.must(child.start({cosmic, script}))
  local __r2 = check.must(h:wait())
  local ok, out = __r2.ok, __r2.stdout
  if not ok then
    check.enforce_skip("landlock restrict blocked (subprocess died before enforcing)", true)
    return
  end
  local s = out
  -- Plain-text find: "-" is a Lua pattern quantifier, so a pattern
  -- search for "restrict-failed" would never match the literal marker.
  if s:find("restrict-failed", 1, true) then
    -- The EINVAL this test pins came from add_rule; that regression is
    -- a hard failure. Anything else (create_ruleset / restrict_self
    -- blocked by an outer sandbox) is a strict skip.
    assert(not s:find("add_rule(", 1, true),
      "single-file READ rule must not fail in add_rule: " .. s)
    check.enforce_skip("landlock restrict blocked: " .. s, true)
    return
  end
  assert(s:find("file-ok", 1, true), "single-file rule should read: " .. s)
  assert(s:find("sibling-blocked", 1, true),
    "sibling outside the rule must be blocked: " .. s)
  check.enforced("landlock single-file rule")
end

-- The rule-loop error path runs before any enforcement, so it is safe
-- in-process. This exercises the O_PATH open of each rule path (the
-- vendored Lua predecessor crashed here on a nil unix.O_PATH instead
-- of returning an error).
local function test_restrict_bad_rule_path_returns_error()

  -- Under `optional`, an absent path and a dangling symlink are skipped
  -- at open time (ENOENT) and the rest of the policy still enforces —
  -- the pre-check this replaces would have raced, and passed the
  -- dangling link only to die at the open anyway. Non-optional absence
  -- still fails loudly (the test above).
  local function test_optional_absent_rules_are_skipped()
    if not landlock.available() then
      check.enforce_skip("landlock unavailable (kernel lacks landlock)")
      return
    end
    local allowed_dir = fs.join(tmpdir, "opt-allowed")
    assert(fs.make_dirs(allowed_dir))
    local allowed = fs.join(allowed_dir, "ok.txt")
    assert(fs.write(allowed, "content"))
    local absent = fs.join(tmpdir, "opt-no-such-path")
    local dangling = fs.join(tmpdir, "opt-dangling")
    assert(fs.symlink(fs.join(tmpdir, "opt-gone-target"), dangling))

    local script = fs.join(tmpdir, "landlock_optional.lua")
    assert(fs.write(script, string.format([[
local landlock = require("cosmic.sandbox.landlock")
local ok, err = landlock.restrict {
  rules = {
    {path = %q, access = landlock.READ, optional = true},
    {path = %q, access = landlock.READ, optional = true},
    {path = %q, access = landlock.READ, optional = true},
  },
}
if not ok then io.write("skipped: ", tostring(err), "\n") os.exit(0) end
local f = io.open(%q, "r")
if f then io.write("allowed-ok\n"); f:close() else io.write("allowed-broken\n") end
]], allowed_dir, absent, dangling, allowed)))

    local h = check.must(child.start({cosmic, script}))
    local __r = check.must(h:wait())
    if not __r.ok then
      check.enforce_skip("landlock restrict blocked (subprocess died before enforcing)", true)
      return
    end
    local s = __r.stdout
    if s:find("skipped", 1, true) then
      check.enforce_skip("landlock restrict blocked: " .. s, true)
      return
    end
    assert(s:find("allowed-ok", 1, true),
      "optional absent rules must be skipped, not fatal: " .. s)
    check.enforced("landlock")
  end
  test_optional_absent_rules_are_skipped()
  if not landlock.available() then return end
  local ok, err = landlock.restrict {
    rules = {{path = fs.join(tmpdir, "no-such-dir-xyz"),
        access = landlock.READ}},
  }
  assert(not ok, "restrict with a missing rule path must fail")
  assert(type(err) == "string" and err:find("open(", 1, true),
    "error should identify the failing open: " .. tostring(err))
end

-- An rw grant must admit moving an entry between two directories of
-- its own tree: REFER rides in WRITE (like TRUNCATE), or rename(2)
-- inside a granted tree fails EXDEV — which is how git-under-the-fence
-- surfaced it, every push finalizing objects by cross-directory
-- rename. The move OUT of the rw tree into a read-only one must still
-- be denied: REFER composes per-tree, it does not leak across grants.
local function test_rw_grant_allows_rename_within_its_tree()
  if not landlock.available() then
    check.enforce_skip("landlock unavailable (kernel lacks landlock)")
    return
  end
  local v = landlock.abi()
  if v ~= nil and v < 2 then
    -- ABI 1 has no REFER: the kernel denies cross-directory moves
    -- outright and no grant can allow them.
    check.enforce_skip("landlock ABI < 2 cannot grant REFER")
    return
  end
  local rw_dir = fs.join(tmpdir, "refer-rw")
  local ro_dir = fs.join(tmpdir, "refer-ro")
  assert(fs.make_dirs(fs.join(rw_dir, "a")))
  assert(fs.make_dirs(fs.join(rw_dir, "b")))
  assert(fs.make_dirs(ro_dir))
  assert(fs.write(fs.join(rw_dir, "a", "obj.txt"), "payload"))
  assert(fs.write(fs.join(rw_dir, "a", "leak.txt"), "payload"))

  -- os.rename, deliberately: it is raw rename(2), where fs.move would
  -- fall back to copy+unlink on EXDEV and mask the very denial this
  -- test measures.
  local script = fs.join(tmpdir, "landlock_refer.lua")
  assert(fs.write(script, string.format([[
local ll = require("cosmic.sandbox.landlock")
local ok, err = ll.restrict{ rules = {
  { path = %q, access = ll.RW },
  { path = %q, access = ll.READ },
} }
if not ok then
  io.write("skipped: " .. tostring(err) .. "\n")
  os.exit(0)
end
local moved = os.rename(%q, %q)
io.write(moved and "within-ok\n" or "within-denied\n")
local leaked = os.rename(%q, %q)
io.write(leaked and "across-leaked\n" or "across-blocked\n")
]], rw_dir, ro_dir,
        fs.join(rw_dir, "a", "obj.txt"), fs.join(rw_dir, "b", "obj.txt"),
        fs.join(rw_dir, "a", "leak.txt"), fs.join(ro_dir, "leak.txt"))))

  local h = check.must(child.start({cosmic, script}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  if not ok then
    check.enforce_skip("landlock restrict blocked (subprocess died before enforcing)", true)
    return
  end
  if out:find("skipped", 1, true) then
    check.enforce_skip("landlock restrict blocked: " .. out, true)
    return
  end
  assert(out:find("within-ok", 1, true),
    "rename within the rw tree must succeed: " .. out)
  assert(out:find("across-blocked", 1, true),
    "rename into a read-only tree must stay denied: " .. out)
  check.enforced("landlock rw rename")
end

-- Options.handled narrows which access categories the ruleset
-- controls; a rule's access must be intersected against the ACTUAL
-- handled set, not just the ABI mask, or a rule requesting more than
-- `handled` grants exceeds handled_access_fs and landlock_add_rule(2)
-- returns EINVAL. Enforcement is irreversible, so the live check runs
-- in a subprocess.
local function test_narrowed_handled_intersects_rule_access()
  if not landlock.available() then
    check.enforce_skip("landlock unavailable (kernel lacks landlock)")
    return
  end
  local dir = fs.join(tmpdir, "narrowed-handled")
  assert(fs.make_dirs(dir))

  local script = fs.join(tmpdir, "landlock_narrowed_handled.lua")
  assert(fs.write(script, string.format([[
local ll = require("cosmic.sandbox.landlock")
local ok, err = ll.restrict{
  handled = ll.READ,
  rules = { { path = %q, access = ll.RW } },
}
if not ok then
  io.write("restrict-failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
io.write("restrict-ok\n")
]], dir)))

  local h = check.must(child.start({cosmic, script}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  if not ok then
    check.enforce_skip("landlock restrict blocked (subprocess died before enforcing)", true)
    return
  end
  if out:find("restrict-failed", 1, true) then
    -- The EINVAL this test pins came from add_rule when a rule's
    -- access exceeded a narrowed handled set; that regression is a
    -- hard failure. Anything else (create_ruleset / restrict_self
    -- blocked by an outer sandbox) is a strict skip.
    assert(not out:find("add_rule(", 1, true),
      "a rule wider than a narrowed handled must not EINVAL: " .. out)
    check.enforce_skip("landlock restrict blocked: " .. out, true)
    return
  end
  assert(out:find("restrict-ok", 1, true),
    "restrict must succeed when a rule's access exceeds handled: " .. out)
  check.enforced("landlock handled/rule-access intersection")
end

-- restrict() reports what it enforced -- abi, the actual handled mask,
-- and any rights this kernel's ABI stripped from a full request -- so
-- a caller (cosmic.sandbox) can tell "fully enforced" from "degraded"
-- instead of a bare boolean. Enforcement is irreversible, so the live
-- check runs in a subprocess.
local function test_restrict_reports_what_it_enforced()
  if not landlock.available() then
    check.enforce_skip("landlock unavailable (kernel lacks landlock)")
    return
  end
  local dir = fs.join(tmpdir, "enforcement-report")
  assert(fs.make_dirs(dir))

  local script = fs.join(tmpdir, "landlock_enforcement.lua")
  assert(fs.write(script, string.format([[
local ll = require("cosmic.sandbox.landlock")
local enf, err = ll.restrict{ rules = { { path = %q, access = ll.READ } } }
if not enf then
  io.write("skipped: " .. tostring(err) .. "\n")
  os.exit(0)
end
io.write("abi=" .. tostring(enf.abi) .. "\n")
io.write("handled=" .. tostring(enf.handled) .. "\n")
io.write("stripped=" .. tostring(enf.stripped) .. "\n")
]], dir)))

  local h = check.must(child.start({cosmic, script}))
  local __r = check.must(h:wait())
  if not __r.ok then
    check.enforce_skip("landlock restrict blocked (subprocess died before enforcing)", true)
    return
  end
  local s = __r.stdout
  if s:find("skipped", 1, true) then
    check.enforce_skip("landlock restrict blocked: " .. s, true)
    return
  end
  local abi_v = tonumber(s:match("abi=(%-?%d+)"))
  local handled_v = tonumber(s:match("handled=(%-?%d+)"))
  local stripped_v = tonumber(s:match("stripped=(%-?%d+)"))
  assert(abi_v and abi_v >= 1, "abi must be >= 1 when landlock is available: " .. s)
  assert((handled_v & landlock.READ) == landlock.READ,
    "a full-ALL request must still hand back READ in handled: " .. s)
  -- What a full `ALL` request must lose on THIS kernel's ABI: every rung
  -- below the ABI that introduced it, mirroring abi_mask exactly (REFER
  -- at 2, TRUNCATE at 3, IOCTL_DEV at 5, RESOLVE_UNIX at 9) so this
  -- assertion tracks the ladder instead of assuming "abi >= 3 strips
  -- nothing" — true only while TRUNCATE was the newest rung.
  local want_stripped = 0
  if abi_v < 2 then want_stripped = want_stripped | landlock.REFER end
  if abi_v < 3 then want_stripped = want_stripped | landlock.TRUNCATE end
  if abi_v < 5 then want_stripped = want_stripped | landlock.IOCTL_DEV end
  if abi_v < 9 then want_stripped = want_stripped | landlock.RESOLVE_UNIX end
  check.equal(stripped_v, want_stripped,
    "stripped must match exactly what this kernel's ABI cannot handle yet: " .. s)
  check.enforced("landlock enforcement report")
end

-- Landlock ABI knowledge lives in exactly one place: this module's own
-- bare probe of the kernel's ABI syscall. A second bare call site
-- appearing anywhere else under cosmic/ is a duplicate probe reappearing
-- (how the tree ended up with three copies in the first place); this
-- guard fails the moment one does. The needle is built from parts so
-- this guard's own source does not trip itself.
local function test_only_landlock_tl_probes_the_bare_abi_call()
  local needle = "unix." .. "landlock_create_ruleset" .. "()"
  local found = check.must(fs.find("cosmic", {glob = "*.tl", recursive = true}))
  local sites: {string} = {}
  for _, path in ipairs(found) do
    local text = check.must(fs.read(path))
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      if line:find(needle, 1, true) then
        sites[#sites + 1] = path
      end
    end
  end
  assert(#sites == 1,
    "expected exactly one bare Landlock ABI probe call site, found:\n  " ..
    table.concat(sites, "\n  "))
  assert(sites[1] == "cosmic/sandbox/landlock.tl",
    "the one bare call site must be cosmic/sandbox/landlock.tl, got: " .. sites[1])
end
