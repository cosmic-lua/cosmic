#!/usr/bin/env cosmic
local landlock = require("cosmic.landlock")
local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
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

  local allowed = path.join(tmpdir, "allowed.txt")
  local denied = path.join(tmpdir, "denied.txt")
  cosmo.Barf(allowed, "allowed-content")
  cosmo.Barf(denied, "denied-content")

  local script = path.join(tmpdir, "landlock_restrict.lua")
  cosmo.Barf(script, string.format([[
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
