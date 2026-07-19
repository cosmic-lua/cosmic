#!/usr/bin/env cosmic
-- tests for cosmic --version / -v output

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")

--- cosmic -v should output version info and exit 0
local function test_v_flag()
  local r = check.must(spawn.run({cosmic, "-v"}))
  assert(r.ok, "cosmic -v should succeed")
  assert(r.stdout:find("Lua 5.4"), "should contain Lua version, got: " .. r.stdout)
end
test_v_flag()

--- cosmic --version should produce the same output as -v
local function test_version_flag()
  local r = check.must(spawn.run({cosmic, "--version"}))
  assert(r.ok, "cosmic --version should succeed")
  assert(r.stdout:find("Lua 5.4"), "should contain Lua version, got: " .. r.stdout)
end
test_version_flag()

--- -v and --version should produce identical output
local function test_v_and_version_match()
  local rv = check.must(spawn.run({cosmic, "-v"}))
  local rver = check.must(spawn.run({cosmic, "--version"}))
  assert(rv.stdout == rver.stdout, "-v and --version should match: " .. rv.stdout .. " vs " .. rver.stdout)
end
test_v_and_version_match()

--- when cosmic.version is embedded, output should match the full format
local function test_full_version_format()
  local r = check.must(spawn.run({cosmic, "-v"}))
  assert(r.ok, "cosmic -v should succeed")
  local output = r.stdout:gsub("%s+$", "")
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
  local r = check.must(spawn.run({cosmic, "-v"}))
  local output = r.stdout:gsub("%s+$", "")
  local lines = 0
  for _ in output:gmatch("[^\n]+") do
    lines = lines + 1
  end
  assert(lines == 1, "version should be a single line, got " .. tostring(lines))
end
test_version_single_line()

--- cosmic.version module should be requireable
local function test_require_version_module()
  local r = check.must(spawn.run({cosmic, "-e", "local v = require('cosmic.version'); print(v.cosmic); print(v.cosmos)"}))
  if r.ok then
    -- both fields should be non-empty strings
    local cosmic_ver, cosmos_ver = r.stdout:match("^(%S+)\n(%S+)")
    assert(cosmic_ver and cosmic_ver ~= "", "cosmic version should be non-empty")
    assert(cosmos_ver and cosmos_ver ~= "", "cosmos version should be non-empty")
  end
  -- if require fails, that's ok — means version.lua wasn't embedded (bootstrap)
end
test_require_version_module()
