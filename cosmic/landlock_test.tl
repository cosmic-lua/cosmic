#!/usr/bin/env cosmic
local landlock = require("cosmic.landlock")
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
end
test_module_exports()

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
  -- RW is read + write only: it must NOT silently grant execute, or a
  -- box's rw path (e.g. /tmp) would become write+exec (a sandbox
  -- weakening the caller never asked for).
  assert((landlock.RW & landlock.EXEC) == 0,
    "RW must not include EXEC")
  assert((landlock.RW & landlock.WRITE_FILE) == landlock.WRITE_FILE,
    "RW should include WRITE_FILE")
end
test_access_mask_composition()

local function test_available_returns_boolean()
  local v = landlock.available()
  assert(type(v) == "boolean", "available() should return a boolean, got " .. type(v))
end
test_available_returns_boolean()

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
  fs.make_dirs(allowed_dir)
  local allowed = fs.join(allowed_dir, "ok.txt")
  local denied = fs.join(tmpdir, "denied.txt")
  fs.write(allowed, "allowed-content")
  fs.write(denied, "denied-content")

  local script = fs.join(tmpdir, "landlock_restrict.lua")
  fs.write(script, string.format([[
local ll = require("cosmic.landlock")
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
]], allowed_dir, allowed, denied))

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
test_restrict_denies_outside_allowlist()

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
  fs.make_dirs(dir)
  local target = fs.join(dir, "target.txt")
  local sibling = fs.join(dir, "sibling.txt")
  fs.write(target, "target-content")
  fs.write(sibling, "sibling-content")

  local script = fs.join(tmpdir, "landlock_filerule.lua")
  fs.write(script, string.format([[
local ll = require("cosmic.landlock")
local ok, err = ll.restrict{ rules = { { path = %q, access = ll.READ } } }
if not ok then
  io.write("restrict-failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
local f = io.open(%q, "r")
if f then io.write("file-ok\n"); f:close() else io.write("file-fail\n") end
local g = io.open(%q, "r")
if g then io.write("sibling-leaked\n"); g:close() else io.write("sibling-blocked\n") end
]], target, target, sibling))

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
test_restrict_single_file_rule()

-- The rule-loop error path runs before any enforcement, so it is safe
-- in-process. This exercises the O_PATH open of each rule path (the
-- vendored Lua predecessor crashed here on a nil unix.O_PATH instead
-- of returning an error).
local function test_restrict_bad_rule_path_returns_error()
  if not landlock.available() then return end
  local ok, err = landlock.restrict {
    rules = {{path = fs.join(tmpdir, "no-such-dir-xyz"),
        access = landlock.READ}},
  }
  assert(not ok, "restrict with a missing rule path must fail")
  assert(type(err) == "string" and err:find("open(", 1, true),
    "error should identify the failing open: " .. tostring(err))
end
test_restrict_bad_rule_path_returns_error()
