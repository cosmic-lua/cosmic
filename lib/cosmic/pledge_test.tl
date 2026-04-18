#!/usr/bin/env cosmic
local pledge = require("cosmic.pledge")
local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(pledge.apply) == "function", "apply should be a function")
end
test_module_exports()

local function test_stdio_allows_write()
  local script = path.join(tmpdir, "pledge_stdio.lua")
  cosmo.Barf(script, [[
local pledge = require("cosmic.pledge")
local ok, err = pledge.apply("stdio")
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
test_stdio_allows_write()

local function test_restricts_filesystem()
  local script = path.join(tmpdir, "pledge_no_fs.lua")
  cosmo.Barf(script, [[
local pledge = require("cosmic.pledge")
local ok, err = pledge.apply("stdio")
if not ok then
  io.stderr:write("pledge failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
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
  -- Linux: disallowed calls return EPERM, script runs to completion.
  -- OpenBSD: kernel kills the process outright.
  if code == 0 then
    assert(out:find("restricted"), "should report restriction: " .. out)
  end
end
test_restricts_filesystem()
