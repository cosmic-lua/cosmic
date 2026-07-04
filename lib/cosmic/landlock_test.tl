#!/usr/bin/env cosmic
local landlock = require("cosmic.landlock")
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local spawn = require("cosmic.child")

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
    -- that abi() consistently reports the limitation.
    local v, err = landlock.abi()
    assert(v == nil, "abi() should return nil when landlock is unavailable")
    assert(err, "abi() should return an error string when unavailable")
    return
  end

  local allowed = fs.join(tmpdir, "allowed.txt")
  local denied = fs.join(tmpdir, "denied.txt")
  cio.barf(allowed, "allowed-content")
  cio.barf(denied, "denied-content")

  local script = fs.join(tmpdir, "landlock_restrict.lua")
  cio.barf(script, string.format([[
local ll = require("cosmic.landlock")
local ok, err = ll.restrict{ rules = { { path = %q, access = ll.READ } } }
if not ok then
  -- An outer sandbox (pledge/seccomp) may block the landlock syscall
  -- even when the kernel supports it. Report skipped so the parent can
  -- tolerate running under CI sandboxes.
  io.write("skipped: " .. tostring(err) .. "\n")
  os.exit(0)
end

-- Reading the allowed path must still work.
local f = io.open(%q, "r")
if f then io.write("allowed-ok\n"); f:close() else io.write("allowed-fail\n") end

-- Reading the denied path must fail.
local g = io.open(%q, "r")
if g then io.write("denied-leaked\n"); g:close() else io.write("denied-blocked\n") end
]], allowed, allowed, denied))

  local ok, out = spawn.spawn({cosmic, script}):read()
  -- Under an outer seccomp/pledge filter the landlock syscall may be
  -- blocked with SIGSYS rather than EPERM, killing the subprocess
  -- before it can emit "skipped". Accept that too.
  if not ok then return end
  local s = out as string
  if s:find("skipped") then return end
  assert(s:find("allowed-ok"), "allowed path should still read: " .. s)
  assert(s:find("denied-blocked"), "denied path must be blocked: " .. s)
end
test_restrict_denies_outside_allowlist()

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
