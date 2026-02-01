#!/usr/bin/env cosmic
local user = require("cosmic.user")

-- getuid tests

local function test_getuid_returns_number()
  local uid = user.getuid()
  assert(type(uid) == "number", "getuid should return a number, got " .. type(uid))
  assert(uid >= 0, "uid should be non-negative, got " .. tostring(uid))
end
test_getuid_returns_number()

-- getgid tests

local function test_getgid_returns_number()
  local gid = user.getgid()
  assert(type(gid) == "number", "getgid should return a number, got " .. type(gid))
  assert(gid >= 0, "gid should be non-negative, got " .. tostring(gid))
end
test_getgid_returns_number()

-- geteuid tests

local function test_geteuid_returns_number()
  local euid = user.geteuid()
  assert(type(euid) == "number", "geteuid should return a number, got " .. type(euid))
  assert(euid >= 0, "euid should be non-negative, got " .. tostring(euid))
end
test_geteuid_returns_number()

-- getegid tests

local function test_getegid_returns_number()
  local egid = user.getegid()
  assert(type(egid) == "number", "getegid should return a number, got " .. type(egid))
  assert(egid >= 0, "egid should be non-negative, got " .. tostring(egid))
end
test_getegid_returns_number()

-- For non-setuid binaries, effective ids should match real ids

local function test_effective_matches_real_for_normal_process()
  local uid = user.getuid()
  local euid = user.geteuid()
  local gid = user.getgid()
  local egid = user.getegid()

  assert(uid == euid, "for non-setuid process, uid (" .. uid .. ") should equal euid (" .. euid .. ")")
  assert(gid == egid, "for non-setgid process, gid (" .. gid .. ") should equal egid (" .. egid .. ")")
end
test_effective_matches_real_for_normal_process()

-- getlogin tests

local function test_getlogin_returns_string_or_nil()
  local login = user.getlogin()
  -- getlogin may return nil if there's no controlling terminal
  if login ~= nil then
    assert(type(login) == "string", "getlogin should return a string or nil, got " .. type(login))
    assert(#login > 0, "login name should not be empty")
  end
end
test_getlogin_returns_string_or_nil()

-- umask tests

local function test_umask_returns_previous_value()
  -- Save original umask
  local original = user.umask(0)
  assert(type(original) == "number", "umask should return a number")

  -- Set a new umask and verify we get back 0
  local prev = user.umask(022)
  assert(prev == 0, "expected previous umask to be 0, got " .. tostring(prev))

  -- Verify the umask was set correctly
  local current = user.umask(original)
  assert(current == 022, "expected umask to be 022, got " .. tostring(current))

  -- Restore original umask
  user.umask(original)
end
test_umask_returns_previous_value()

-- setuid/setgid tests (only test that setting to current id works)

local function test_setuid_to_current_uid()
  local uid = user.getuid()
  local ok = user.setuid(uid)
  assert(ok, "setuid to current uid should succeed")
end
test_setuid_to_current_uid()

local function test_setgid_to_current_gid()
  local gid = user.getgid()
  local ok = user.setgid(gid)
  assert(ok, "setgid to current gid should succeed")
end
test_setgid_to_current_gid()

-- setresuid/setresgid tests (test with -1 to leave unchanged)

local function test_setresuid_with_no_change()
  local ok = user.setresuid(-1, -1, -1)
  assert(ok, "setresuid with all -1 should succeed")
end
test_setresuid_with_no_change()

local function test_setresgid_with_no_change()
  local ok = user.setresgid(-1, -1, -1)
  assert(ok, "setresgid with all -1 should succeed")
end
test_setresgid_with_no_change()
