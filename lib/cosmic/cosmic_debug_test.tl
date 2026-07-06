#!/usr/bin/env cosmic
--- Tests for cosmic-debug binary

local spawn = require("cosmic.child")
local fs = require("cosmic.fs")

global TEST_BIN: string

local function test_cosmic_debug_version()
  local bin = fs.join(TEST_BIN, "cosmic-debug")
  local h = spawn.spawn({bin, "-v"})
  local __r1 = (h as spawn.Handle):wait() as spawn.Result
  local ok, got = __r1.ok, __r1.stdout
  assert(ok, "cosmic-debug -v failed: " .. tostring(got))
  local want = "Lua"
  assert((got as string):find(want, 1, true), "expected '" .. want .. "' in output, got: " .. (got as string))
end
test_cosmic_debug_version()

local function test_cosmic_debug_runs_lua()
  local bin = fs.join(TEST_BIN, "cosmic-debug")
  local h = spawn.spawn({bin, "-e", "print('hello from debug')"})
  local __r2 = (h as spawn.Handle):wait() as spawn.Result
  local ok, got = __r2.ok, __r2.stdout
  assert(ok, "cosmic-debug -e failed: " .. tostring(got))
  local want = "hello from debug"
  assert((got as string):find(want, 1, true), "expected '" .. want .. "' in output, got: " .. (got as string))
end
test_cosmic_debug_runs_lua()

local function test_cosmic_debug_help()
  local bin = fs.join(TEST_BIN, "cosmic-debug")
  local h = spawn.spawn({bin, "--help"})
  local __r3 = (h as spawn.Handle):wait() as spawn.Result
  local ok, got = __r3.ok, __r3.stdout
  assert(ok, "cosmic-debug --help failed: " .. tostring(got))
  local want = "cosmic"
  assert((got as string):lower():find(want, 1, true), "expected '" .. want .. "' in help output, got: " .. (got as string))
end
test_cosmic_debug_help()

print("cosmic_debug: all tests passed")
