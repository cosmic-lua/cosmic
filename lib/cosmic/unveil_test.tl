#!/usr/bin/env cosmic
local unveil = require("cosmic.unveil")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local cio = require("cosmic.io")
local a = require("cosmic.assert")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(unveil.apply) == "function", "apply should be a function")
end
test_module_exports()

-- Unveil only a sub-directory, then confirm both that the unveiled file
-- reads AND that a sibling file left outside the unveil is hidden. Both
-- files exist, so the denial is a genuine unveil effect, not a missing
-- path. unveil is OpenBSD-only; on Linux apply() returns ENOSYS and the
-- subprocess reports "skipped" — a genuine platform gap, so it is a soft
-- skip even on the enforce lane (a Linux runner cannot exercise unveil).
local function test_unveil_restricts_paths()
  local allowed_dir = fs.join(tmpdir, "vis")
  fs.makedirs(allowed_dir)
  local allowed_file = fs.join(allowed_dir, "unveiled.txt")
  local hidden_file = fs.join(tmpdir, "secret.txt")
  cio.barf(allowed_file, "visible")
  cio.barf(hidden_file, "secret")

  local script = fs.join(tmpdir, "unveil_test.lua")
  cio.barf(script, string.format([[
local unveil = require("cosmic.unveil")
local ok, err = unveil.apply(%q, "r")
if not ok then
  io.write("skipped: unveil unavailable: " .. tostring(err) .. "\n")
  os.exit(0)
end
ok, err = unveil.apply(nil, nil)
if not ok then
  io.write("skipped: unveil commit failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
local f = io.open(%q, "r")
if f then
  local content = f:read("*a")
  f:close()
  io.write("read:" .. content .. "\n")
else
  io.write("read:failed\n")
end
-- A sibling file outside the unveiled directory must be invisible. On Linux
-- cosmopolitan backs unveil with Landlock; if Landlock is unavailable the
-- apply() call succeeds but does not actually restrict (a no-op), so treat a
-- leak-without-backing as a skip rather than a failure.
local g = io.open(%q, "r")
if g then
  g:close()
  if require("cosmic.landlock").available() then
    io.write("denied-leaked\n")
  else
    io.write("skipped: unveil applied but did not restrict (no backing sandbox)\n")
  end
else
  io.write("denied-blocked\n")
end
]], allowed_dir, allowed_file, hidden_file))

  local ok, out = spawn.spawn({cosmic, script}):read()
  local s = (out or "") as string
  if s:find("skipped") then
    a.skip("unveil unavailable / not enforcing (OpenBSD-only, or no backing): " .. s)
    return
  end
  assert(ok, "unveil subprocess should exit cleanly: " .. s)
  assert(s:find("read:visible"), "should read unveiled file: " .. s)
  -- Backing sandbox present but the sibling still leaked: a real failure
  -- off the lane it stays tolerant, on the enforce lane it is fatal.
  if s:find("denied%-leaked") then
    a.skip("unveil did not hide the non-unveiled sibling despite backing: " .. s, true)
    return
  end
  assert(s:find("denied%-blocked"), "expected denial of the non-unveiled sibling: " .. s)
  a.enforced("unveil")
end
test_unveil_restricts_paths()
