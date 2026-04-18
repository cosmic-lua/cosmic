#!/usr/bin/env cosmic
local netns = require("cosmic.quicksand.netns")
local quicksand = require("cosmic.quicksand")
local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function test_module_exports()
  assert(type(netns.open) == "function")
  assert(type(netns.enter) == "function")
  assert(type(netns.unshare) == "function")
  assert(type(netns.bring_up) == "function")
  assert(type(netns.bring_down) == "function")
  assert(type(netns.close) == "function")
end
test_module_exports()

local function test_open_self()
  local c = quicksand.capabilities()
  if not c.linux then
    local fd, err = netns.open(nil)
    assert(fd == nil, "non-linux: open should fail")
    assert(err, "non-linux: expected error string")
    return
  end
  local fd, err = netns.open(nil)
  assert(fd, "open(self) failed: " .. tostring(err))
  assert(type(fd) == "number", "fd should be a number")
  assert(fd >= 0, "fd should be non-negative")
  assert(netns.close(fd))
end
test_open_self()

-- unshare() is irreversible for the current thread, so run in a subprocess.
local function test_unshare_subprocess()
  local c = quicksand.capabilities()
  if not (c.linux and c.net_ns and (c.user_ns or c.cap_net_admin)) then
    return
  end
  local script = path.join(tmpdir, "unshare.lua")
  cosmo.Barf(script, [[
local unix = require("cosmo.unix")
local ns = require("cosmic.quicksand.netns")
-- Drop into a fresh userns first so unprivileged callers can create a netns.
if not unix.unshare(unix.CLONE_NEWUSER) then
  io.write("skipped\n")
  os.exit(0)
end
local ok, err = ns.unshare()
if not ok then io.stderr:write("unshare: " .. tostring(err) .. "\n"); os.exit(1) end
local up, uerr = ns.bring_up("lo")
if not up then io.stderr:write("bring_up: " .. tostring(uerr) .. "\n"); os.exit(1) end
io.write("ok\n")
]])
  local ok, out = spawn.spawn({cosmic, script}):read()
  assert(ok, "subprocess failed: " .. tostring(out))
  local s = out as string
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped, got: " .. s)
end
test_unshare_subprocess()
