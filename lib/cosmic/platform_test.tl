#!/usr/bin/env cosmic
local platform = require("cosmic.platform")

-- os field tests

local function test_os_is_string()
  assert(type(platform.os) == "string", "os should be a string, got " .. type(platform.os))
  assert(#platform.os > 0, "os should be non-empty")
end
test_os_is_string()

local function test_os_is_lowercase()
  assert(platform.os == platform.os:lower(), "os should be lowercase, got " .. platform.os)
end
test_os_is_lowercase()

local function test_os_is_known_value()
  local known: {string: boolean} = {
    linux = true,
    darwin = true,
    windows = true,
    freebsd = true,
    openbsd = true,
    netbsd = true,
  }
  assert(known[platform.os], "os should be a known value, got " .. platform.os)
end
test_os_is_known_value()

-- arch field tests

local function test_arch_is_string()
  assert(type(platform.arch) == "string", "arch should be a string, got " .. type(platform.arch))
  assert(#platform.arch > 0, "arch should be non-empty")
end
test_arch_is_string()

local function test_arch_is_lowercase()
  assert(platform.arch == platform.arch:lower(), "arch should be lowercase, got " .. platform.arch)
end
test_arch_is_lowercase()

local function test_arch_is_known_value()
  local known: {string: boolean} = {
    x86_64 = true,
    aarch64 = true,
  }
  assert(known[platform.arch], "arch should be a known value, got " .. platform.arch)
end
test_arch_is_known_value()

-- fields are stable (same value on repeated access)

local function test_os_is_stable()
  local a = platform.os
  local b = platform.os
  assert(a == b, "os should be stable, got " .. a .. " and " .. b)
end
test_os_is_stable()

local function test_arch_is_stable()
  local a = platform.arch
  local b = platform.arch
  assert(a == b, "arch should be stable, got " .. a .. " and " .. b)
end
test_arch_is_stable()

-- os uses uname-style names (darwin, not macos)

local function test_os_uses_uname_names()
  -- on this platform, just verify it's not returning cosmo's "macos" style
  if platform.os == "macos" then
    error("os should use uname-style 'darwin', not 'macos'")
  end
end
test_os_uses_uname_names()
