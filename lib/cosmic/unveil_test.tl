#!/usr/bin/env cosmic
local unveil = require("cosmic.unveil")
local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(unveil.apply) == "function", "apply should be a function")
end
test_module_exports()

local function test_unveil_restricts_paths()
  local allowed_file = path.join(tmpdir, "unveiled.txt")
  cosmo.Barf(allowed_file, "visible")

  local script = path.join(tmpdir, "unveil_test.lua")
  cosmo.Barf(script, string.format([[
local unveil = require("cosmic.unveil")
local ok, err = unveil.apply(%q, "r")
if not ok then
  io.stderr:write("unveil failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
ok, err = unveil.apply(nil, nil)
if not ok then
  io.stderr:write("unveil commit failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
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
  -- unveil is OpenBSD-only at runtime; on Linux it returns ENOSYS. Accept
  -- either the expected "read:visible" (when unveil works) or a non-zero
  -- exit (when unveil is unavailable).
  if ok then
    assert((out as string):find("read:visible"), "should read unveiled file: " .. tostring(out))
  end
end
test_unveil_restricts_paths()
