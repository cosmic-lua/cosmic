#!/usr/bin/env cosmic
local sys = require("cosmic.sys")

-- host_os tests

local function test_host_os_returns_string()
  local os_name = sys.host_os()
  assert(type(os_name) == "string", "host_os should return a string, got " .. type(os_name))
  assert(#os_name > 0, "host_os should return a non-empty string")
end
test_host_os_returns_string()

local function test_host_os_is_lowercase()
  local os_name = sys.host_os()
  assert(os_name == os_name:lower(), "host_os should return lowercase, got " .. os_name)
end
test_host_os_is_lowercase()

local function test_host_os_is_known_value()
  local os_name = sys.host_os()
  local is_known = os_name == "linux" or os_name == "macos" or os_name == "windows"
  or os_name == "freebsd" or os_name == "openbsd" or os_name == "netbsd"
  assert(is_known, "host_os should return a known OS, got " .. os_name)
end
test_host_os_is_known_value()

-- host_isa tests

local function test_host_isa_returns_string()
  local isa = sys.host_isa()
  assert(type(isa) == "string", "host_isa should return a string, got " .. type(isa))
  assert(#isa > 0, "host_isa should return a non-empty string")
end
test_host_isa_returns_string()

local function test_host_isa_is_lowercase()
  local isa = sys.host_isa()
  assert(isa == isa:lower(), "host_isa should return lowercase, got " .. isa)
end
test_host_isa_is_lowercase()

local function test_host_isa_is_known_value()
  local isa = sys.host_isa()
  local is_known = isa == "x86_64" or isa == "aarch64"
  assert(is_known, "host_isa should return a known ISA, got " .. isa)
end
test_host_isa_is_known_value()

-- platform tests

local function test_platform_returns_string()
  local plat = sys.platform()
  assert(type(plat) == "string", "platform should return a string, got " .. type(plat))
  assert(#plat > 0, "platform should return a non-empty string")
end
test_platform_returns_string()

local function test_platform_contains_hyphen()
  local plat = sys.platform()
  assert(plat:find("-"), "platform should contain a hyphen separator, got " .. plat)
end
test_platform_contains_hyphen()

local function test_platform_matches_os_and_isa()
  local os_name = sys.host_os()
  local isa = sys.host_isa()
  local expected = os_name .. "-" .. isa
  local plat = sys.platform()
  assert(plat == expected, "platform should be " .. expected .. ", got " .. plat)
end
test_platform_matches_os_and_isa()

local function test_platform_is_lowercase()
  local plat = sys.platform()
  assert(plat == plat:lower(), "platform should be lowercase, got " .. plat)
end
test_platform_is_lowercase()

-- sysconf / nproc / page_size tests

local function test_nproc_positive()
  local n, err = sys.nproc()
  assert(n, "nproc should succeed, got error: " .. tostring(err))
  assert(math.type(n) == "integer" or type(n) == "number",
    "nproc should return a number, got " .. type(n))
  assert(n >= 1, "nproc should be at least 1, got " .. tostring(n))
end
test_nproc_positive()

local function test_nproc_configured_at_least_online()
  local online = sys.nproc()
  local configured = sys.nproc_configured()
  assert(online and configured, "nproc/nproc_configured should succeed")
  assert(configured >= online,
    "configured (" .. tostring(configured) .. ") should be >= online (" .. tostring(online) .. ")")
end
test_nproc_configured_at_least_online()

local function test_page_size_positive()
  local sz, err = sys.page_size()
  assert(sz, "page_size should succeed, got error: " .. tostring(err))
  assert(sz > 0, "page_size should be positive, got " .. tostring(sz))
  -- Page sizes are always a power of two.
  assert(sz & (sz - 1) == 0, "page_size should be a power of two, got " .. tostring(sz))
end
test_page_size_positive()

local function test_sysconf_direct()
  local sz = sys.sysconf(sys.SC_PAGESIZE)
  local direct = sys.page_size()
  assert(sz == direct, "sysconf(SC_PAGESIZE) should match page_size()")
end
test_sysconf_direct()

-- uname tests

local function test_uname_fields()
  local uts, err = sys.uname()
  assert(uts, "uname should succeed, got error: " .. tostring(err))
  assert(type(uts.sysname) == "string" and #uts.sysname > 0,
    "uname.sysname should be a non-empty string")
  assert(type(uts.nodename) == "string", "uname.nodename should be a string")
  assert(type(uts.release) == "string" and #uts.release > 0,
    "uname.release should be a non-empty string")
  assert(type(uts.version) == "string", "uname.version should be a string")
  assert(type(uts.machine) == "string" and #uts.machine > 0,
    "uname.machine should be a non-empty string")
end
test_uname_fields()
