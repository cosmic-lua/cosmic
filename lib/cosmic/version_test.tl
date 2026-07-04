#!/usr/bin/env cosmic
-- tests for cosmic --version / -v output

local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")

--- cosmic -v should output version info and exit 0
local function test_v_flag()
  local ok, out = spawn.spawn({cosmic, "-v"}):read()
  assert(ok, "cosmic -v should succeed")
  local output = out as string
  -- should contain at least the Lua version
  assert(output:find("Lua 5.4"), "should contain Lua version, got: " .. output)
end
test_v_flag()

--- cosmic --version should produce the same output as -v
local function test_version_flag()
  local ok, out = spawn.spawn({cosmic, "--version"}):read()
  assert(ok, "cosmic --version should succeed")
  local output = out as string
  assert(output:find("Lua 5.4"), "should contain Lua version, got: " .. output)
end
test_version_flag()

--- -v and --version should produce identical output
local function test_v_and_version_match()
  local _, out_v = spawn.spawn({cosmic, "-v"}):read()
  local _, out_ver = spawn.spawn({cosmic, "--version"}):read()
  assert(out_v == out_ver, "-v and --version should match: " .. (out_v as string) .. " vs " .. (out_ver as string))
end
test_v_and_version_match()

--- when cosmic.version is embedded, output should match the full format
local function test_full_version_format()
  local ok, out = spawn.spawn({cosmic, "-v"}):read()
  assert(ok, "cosmic -v should succeed")
  local output = (out as string):gsub("%s+$", "")
  -- the binary has version.lua embedded, so should show full format:
  -- cosmic-lua <version> (cosmos <version>, Lua 5.4)
  if output:find("^cosmic%-lua ") then
    assert(output:find("^cosmic%-lua %S+"), "should have cosmic version after 'cosmic-lua '")
    assert(output:find("%(cosmos %S+,"), "should have cosmos version in parens")
    assert(output:find("Lua 5%.4%)"), "should end with Lua version in parens")
  else
    -- fallback: just Lua version (bootstrap binary without version.lua)
    assert(output == "Lua 5.4", "fallback should be plain 'Lua 5.4', got: " .. output)
  end
end
test_full_version_format()

--- version output should be a single line
local function test_version_single_line()
  local _, out = spawn.spawn({cosmic, "-v"}):read()
  local output = (out as string):gsub("%s+$", "")
  local lines = 0
  for _ in output:gmatch("[^\n]+") do
    lines = lines + 1
  end
  assert(lines == 1, "version should be a single line, got " .. tostring(lines))
end
test_version_single_line()

--- cosmic.version module should be requireable
local function test_require_version_module()
  local ok, out = spawn.spawn({cosmic, "-e", "local v = require('cosmic.version'); print(v.cosmic); print(v.cosmos)"}):read()
  if ok then
    local output = out as string
    -- both fields should be non-empty strings
    local cosmic_ver, cosmos_ver = output:match("^(%S+)\n(%S+)")
    assert(cosmic_ver and cosmic_ver ~= "", "cosmic version should be non-empty")
    assert(cosmos_ver and cosmos_ver ~= "", "cosmos version should be non-empty")
  end
  -- if require fails, that's ok — means version.lua wasn't embedded (bootstrap)
end
test_require_version_module()
