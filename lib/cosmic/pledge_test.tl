#!/usr/bin/env cosmic
local pledge = require("cosmic.pledge")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local cio = require("cosmic.io")
local a = require("cosmic.assert")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(pledge.apply) == "function", "apply should be a function")
end
test_module_exports()

local function test_stdio_allows_write()
  local script = fs.join(tmpdir, "pledge_stdio.lua")
  cio.barf(script, [[
local pledge = require("cosmic.pledge")
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
  assert(ok, "pledge stdio should allow io.write: " .. tostring(out))
  assert((out as string):find("pledged"), "should print after pledge: " .. tostring(out))
end
test_stdio_allows_write()

local function test_restricts_filesystem()
  -- Status is written to stdout (not stderr) so the parent can read it via
  -- handle:read(); on Linux a pledge violation raises SIGSYS and kills the
  -- process, so a leak/skip cannot be signalled through the exit code alone.
  local script = fs.join(tmpdir, "pledge_no_fs.lua")
  cio.barf(script, [[
local pledge = require("cosmic.pledge")
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
  if s:find("skipped") then
    -- pledge is supported on every platform cosmic targets (Linux via
    -- seccomp, OpenBSD native); an apply failure means an outer sandbox
    -- pre-empted it. Strict: a hard failure on the enforce lane.
    a.skip("pledge apply failed: " .. s, true)
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
  a.enforced("pledge")
end
test_restricts_filesystem()
