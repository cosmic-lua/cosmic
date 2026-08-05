#!/usr/bin/env cosmic
--- Tests for cosmic-debug binary

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")

global TEST_BIN: string

local function test_cosmic_debug_version()
  local bin = fs.join(TEST_BIN, "cosmic-debug")
  local h = check.must(child.start({bin, "-v"}))
  local __r1 = check.must(h:wait())
  local ok, got = __r1.ok, __r1.stdout
  assert(ok, "cosmic-debug -v failed: " .. tostring(got))
  local want = "Lua"
  assert(got:find(want, 1, true), "expected '" .. want .. "' in output, got: " .. got)
end
test_cosmic_debug_version()

local function test_cosmic_debug_runs_lua()
  local bin = fs.join(TEST_BIN, "cosmic-debug")
  local h = check.must(child.start({bin, "-e", "print('hello from debug')"}))
  local __r2 = check.must(h:wait())
  local ok, got = __r2.ok, __r2.stdout
  assert(ok, "cosmic-debug -e failed: " .. tostring(got))
  local want = "hello from debug"
  assert(got:find(want, 1, true), "expected '" .. want .. "' in output, got: " .. got)
end
test_cosmic_debug_runs_lua()

local function test_cosmic_debug_help()
  local bin = fs.join(TEST_BIN, "cosmic-debug")
  local h = check.must(child.start({bin, "--help"}))
  local __r3 = check.must(h:wait())
  local ok, got = __r3.ok, __r3.stdout
  assert(ok, "cosmic-debug --help failed: " .. tostring(got))
  local want = "cosmic"
  assert(got:lower():find(want, 1, true), "expected '" .. want .. "' in help output, got: " .. got)
end
test_cosmic_debug_help()

print("cosmic_debug: all tests passed")
