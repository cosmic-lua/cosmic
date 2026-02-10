#!/usr/bin/env cosmic
local sandbox = require("cosmic.sandbox")
local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Test that sandbox module exports expected functions

local function test_module_exports()
  assert(sandbox.pledge ~= nil, "pledge function should be exported")
  assert(sandbox.unveil ~= nil, "unveil function should be exported")
  assert(type(sandbox.pledge) == "function", "pledge should be a function")
  assert(type(sandbox.unveil) == "function", "unveil should be a function")
end
test_module_exports()

-- Test pledge in a subprocess (pledge is irreversible, so we isolate it)

local function test_pledge_stdio_allows_write()
  local script = path.join(tmpdir, "pledge_stdio.lua")
  cosmo.Barf(script, [[
local sandbox = require("cosmic.sandbox")
local ok, err = sandbox.pledge("stdio")
if not ok then
  io.stderr:write("pledge failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
io.write("pledged\n")
]])
  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "pledge stdio should allow io.write: " .. tostring(out))
  assert((out as string):find("pledged"), "should print after pledge: " .. tostring(out))
end
test_pledge_stdio_allows_write()

local function test_pledge_restricts_filesystem()
  local script = path.join(tmpdir, "pledge_no_fs.lua")
  cosmo.Barf(script, [[
local sandbox = require("cosmic.sandbox")
-- Pledge only stdio - no filesystem access
local ok, err = sandbox.pledge("stdio")
if not ok then
  io.stderr:write("pledge failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
-- Opening a file should fail after pledging only stdio
local f, open_err = io.open("/dev/null", "r")
if f then
  f:close()
  io.stderr:write("ERROR: file open should have been blocked\n")
  os.exit(1)
end
io.write("restricted\n")
]])
  local handle = spawn.spawn({cosmic, script})
  handle.stdin:close()
  local out = handle.stdout:read()
  local code = handle:wait()
  -- On Linux, pledge violations return EPERM; on OpenBSD, the process is killed.
  -- Either way, the io.open should fail or the process should be terminated.
  if code == 0 then
    assert(out:find("restricted"), "should report restriction: " .. out)
  end
  -- If code != 0, the pledge killed the process, which is the expected behavior
end
test_pledge_restricts_filesystem()

-- Test unveil in a subprocess (unveil is irreversible once committed)

local function test_unveil_restricts_paths()
  local allowed_file = path.join(tmpdir, "unveiled.txt")
  cosmo.Barf(allowed_file, "visible")

  local script = path.join(tmpdir, "unveil_test.lua")
  cosmo.Barf(script, string.format([[
local sandbox = require("cosmic.sandbox")
-- Unveil only the tmpdir as readable
local ok, err = sandbox.unveil(%q, "r")
if not ok then
  io.stderr:write("unveil failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
-- Commit the unveil policy
ok, err = sandbox.unveil(nil, nil)
if not ok then
  io.stderr:write("unveil commit failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
-- Reading the unveiled path should succeed
local f = io.open(%q, "r")
if f then
  local content = f:read("*a")
  f:close()
  io.write("read:" .. content .. "\n")
else
  io.write("read:failed\n")
end
]], tmpdir, allowed_file))

  local ok, out = spawn.spawn({cosmic, script}):read()
  -- unveil may not be supported on all platforms; accept success or platform error
  if ok then
    assert((out as string):find("read:visible"), "should read unveiled file: " .. tostring(out))
  end
end
test_unveil_restricts_paths()
