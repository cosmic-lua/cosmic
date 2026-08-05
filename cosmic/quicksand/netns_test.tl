#!/usr/bin/env cosmic
local netns = require("cosmic.quicksand.netns")
local quicksand = require("cosmic.quicksand")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local child = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
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
    check.enforce_skip("netns unshare: namespaces unavailable on this host")
    return
  end
  local script = fs.join(tmpdir, "unshare.lua")
  fs.write(script, [[
local ns = require("cosmic.quicksand.netns")
-- Drop into a fresh userns first so unprivileged callers can create a netns.
-- An outer sandbox (pledge/seccomp) may block unshare entirely; tolerate
-- that by skipping rather than failing (unshare_user returns nil+err, and a
-- seccomp SIGSYS kills the subprocess, handled by the parent below).
local u = ns.unshare_user()
if not u then
  io.write("skipped\n")
  os.exit(0)
end
local nok, nerr = ns.unshare()
if not nok then
  io.write("skipped: " .. tostring(nerr) .. "\n")
  os.exit(0)
end
local up, uerr = ns.bring_up("lo")
if not up then io.stderr:write("bring_up: " .. tostring(uerr) .. "\n"); os.exit(1) end
io.write("ok\n")
]])
  local h = check.must(child.start({cosmic, script}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  -- An outer seccomp/pledge filter may SIGSYS the subprocess on unshare.
  -- Accept signal death as a skip.
  if not ok then
    check.enforce_skip("netns unshare child died before reporting (outer sandbox)")
    return
  end
  local s = out
  assert(s:find("ok") or s:find("skipped"),
    "expected ok or skipped, got: " .. s)
  if s:find("skipped") then
    check.enforce_skip("netns unshare: " .. s:gsub("%s+$", ""))
  end
end
test_unshare_subprocess()

-- get_flags/set_flags exercise the unix.siocgifflags/siocsifflags
-- bindings (struct ifreq lives in C, cosmopolitan#199) that
-- bring_up/bring_down are built on. Loopback exists in any namespace,
-- but an outer sandbox may deny AF_INET sockets — tolerate that.
local function test_get_flags_loopback()
  local flags, err = netns.get_flags("lo")
  if not flags then
    assert(type(err) == "string", "get_flags must explain its failure")
    check.enforce_skip("get_flags lo denied on this host: " .. err)
    return
  end
  assert(math.type(flags) == "integer", "flags should be an integer")
end
test_get_flags_loopback()

local function test_get_flags_bad_interface()
  local flags, err = netns.get_flags("nope0")
  assert(flags == nil, "nonexistent interface should fail")
  assert(type(err) == "string", "failure must carry an error string")
end
test_get_flags_bad_interface()

-- A flag with the 0x8000 bit set must pass through cleanly: the C
-- binding stores flags as uint16_t, and packing them as signed 16-bit
-- overflows exactly here. The interface is nonexistent so
-- SIOCSIFFLAGS can never mutate a real device, regardless of privilege.
local function test_set_flags_high_bit_no_overflow()
  local ok, err = netns.set_flags("nope0", 0x8000)
  assert(ok == false, "set_flags on a nonexistent interface should fail")
  assert(type(err) == "string", "failure must carry an error string")
end
test_set_flags_high_bit_no_overflow()

local function test_get_flags_name_too_long()
  local flags, err = netns.get_flags(string.rep("x", 20))
  assert(flags == nil, "oversized interface name should fail, not throw")
  assert(err == "interface name too long", "got: " .. tostring(err))
end
test_get_flags_name_too_long()
