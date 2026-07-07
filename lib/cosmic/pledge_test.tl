#!/usr/bin/env cosmic
local pledge = require("cosmic.pledge")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local check = require("cosmic.check")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(pledge.apply) == "function", "apply should be a function")
  assert(type(pledge.available) == "function", "available should be a function")
end
test_module_exports()

local function test_available_returns_boolean()
  local v = pledge.available()
  assert(type(v) == "boolean", "available() should return a boolean, got " .. type(v))
end
test_available_returns_boolean()

-- Fail-closed contract: on a host where pledge cannot be enforced,
-- apply() must say so instead of reporting a sandbox that does not
-- exist — unless the caller opts into best_effort explicitly. The
-- unsupported branch never reaches the syscall, so this is safe
-- in-process; on supported hosts (Linux, OpenBSD) it cannot be
-- exercised and enforcement is proven by the subprocess tests below.
local function test_fail_closed_when_unavailable()
  if pledge.available() then
    check.skip("pledge available on this host; fail-closed path not exercisable")
    return
  end
  local ok, err = pledge.apply("stdio")
  assert(not ok, "apply must fail when pledge is unsupported")
  assert(type(err) == "string" and err:find("unsupported"),
    "error should say unsupported: " .. tostring(err))
  local ok2, err2 = pledge.apply("stdio", {best_effort = true})
  assert(ok2 and err2 == nil,
    "best_effort must turn unsupported into a successful no-op")
end
test_fail_closed_when_unavailable()

local function test_stdio_allows_write()
  local script = fs.join(tmpdir, "pledge_stdio.lua")
  fs.write(script, [[
local pledge = require("cosmic.pledge")
if not pledge.available() then
  io.write("skipped: pledge unsupported on this host\n")
  os.exit(0)
end
local ok, err = pledge.apply("stdio")
if not ok then
  io.stderr:write("pledge failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
io.write("pledged\n")
]])
  local h = spawn.spawn({cosmic, script})
  local __r1 = (h as spawn.Handle):wait() as spawn.Result
  local ok, out = __r1.ok, __r1.stdout
  local s = (out or "") as string
  if s:find("skipped") then
    check.skip("pledge unsupported on this host: " .. s)
    return
  end
  assert(ok, "pledge stdio should allow io.write: " .. tostring(out))
  assert(s:find("pledged"), "should print after pledge: " .. tostring(out))
end
test_stdio_allows_write()

local function test_restricts_filesystem()
  -- Status is written to stdout (not stderr) so the parent can read it via
  -- handle:read(); on Linux a pledge violation raises SIGSYS and kills the
  -- process, so a leak/skip cannot be signalled through the exit code alone.
  local script = fs.join(tmpdir, "pledge_no_fs.lua")
  fs.write(script, [[
local pledge = require("cosmic.pledge")
if not pledge.available() then
  io.write("unsupported: pledge unsupported on this host\n")
  os.exit(0)
end
local ok, err = pledge.apply("stdio")
if not ok then
  io.write("skipped: pledge apply failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
local f = io.open("/dev/null", "r")
if f then
  f:close()
  io.write("leaked\n")
  os.exit(0)
end
io.write("restricted\n")
]])
  local h = spawn.spawn({cosmic, script})
  local __r2 = (h as spawn.Handle):wait() as spawn.Result
  local ok, out = __r2.ok, __r2.stdout
  local s = (out or "") as string
  if s:find("unsupported") then
    -- A genuine platform gap reported by the fail-closed probe: soft skip.
    check.skip("pledge unsupported on this host: " .. s)
    return
  end
  if s:find("skipped") then
    -- available() was true yet apply failed: an outer sandbox pre-empted
    -- an otherwise-supported mechanism. Strict: a hard failure on the
    -- enforce lane.
    check.skip("pledge apply failed: " .. s, true)
    return
  end
  assert(not s:find("leaked"), "pledge must block filesystem open: " .. s)
  if ok then
    -- EPERM mode: the blocked open returned nil, script printed restricted.
    assert(s:find("restricted"), "pledged process should report restriction: " .. s)
  end
  -- Otherwise the process was killed (SIGSYS on Linux / kernel on OpenBSD)
  -- attempting the blocked open: enforcement by signal. It did not leak
  -- (asserted above) nor report pledge unavailable, so enforcement held.
  check.enforced("pledge")
end
test_restricts_filesystem()
