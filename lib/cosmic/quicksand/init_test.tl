#!/usr/bin/env cosmic
local quicksand = require("cosmic.quicksand")

local function test_module_exports()
  assert(type(quicksand.capabilities) == "function", "capabilities should be a function")
  assert(type(quicksand.is_supported) == "function", "is_supported should be a function")
end
test_module_exports()

local function test_capabilities_shape()
  local c = quicksand.capabilities()
  assert(type(c) == "table", "capabilities() should return a table")
  assert(type(c.linux) == "boolean", "capabilities().linux should be boolean")
  assert(type(c.user_ns) == "boolean", "capabilities().user_ns should be boolean")
  assert(type(c.mount_ns) == "boolean", "capabilities().mount_ns should be boolean")
  assert(type(c.net_ns) == "boolean", "capabilities().net_ns should be boolean")
  assert(type(c.uts_ns) == "boolean", "capabilities().uts_ns should be boolean")
  assert(type(c.pid_ns) == "boolean", "capabilities().pid_ns should be boolean")
  assert(type(c.pivot_root) == "boolean", "capabilities().pivot_root should be boolean")
  assert(type(c.cap_net_admin) == "boolean", "capabilities().cap_net_admin should be boolean")
  assert(type(c.landlock) == "boolean", "capabilities().landlock should be boolean")
  assert(type(c.pledge) == "boolean", "capabilities().pledge should be boolean")
  assert(type(c.unveil) == "boolean", "capabilities().unveil should be boolean")
end
test_capabilities_shape()

local function test_capabilities_cached()
  local a = quicksand.capabilities()
  local b = quicksand.capabilities()
  assert(a == b, "capabilities() must return the same cached table on repeat calls")
end
test_capabilities_cached()

local function test_is_supported_returns_boolean()
  local v = quicksand.is_supported()
  assert(type(v) == "boolean", "is_supported() should return a boolean, got " .. type(v))
end
test_is_supported_returns_boolean()

local function test_is_supported_matches_capabilities()
  local c = quicksand.capabilities()
  local expected = c.linux and c.net_ns and c.mount_ns
  assert(quicksand.is_supported() == expected,
    "is_supported() must agree with capabilities().linux/net_ns/mount_ns")
end
test_is_supported_matches_capabilities()

local function test_jail_reexported()
  local J = quicksand.Jail as {string: any}
  assert(J, "Jail should be re-exported from cosmic.quicksand")
  assert(type(J.new) == "function")
  assert(type(J.merge) == "function")
end
test_jail_reexported()
