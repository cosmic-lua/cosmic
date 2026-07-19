#!/usr/bin/env cosmic

local check = require("cosmic.check")
local spawn = require("cosmic.child")
local fs = require("cosmic.fs")

global TEST_DIR: string

local function test_lua()
  local bin = fs.join(TEST_DIR, "lua")
  local handle = check.must(spawn.spawn({bin, "-v"}))
  local __r1 = check.must(handle:wait())
  local ok, got = __r1.ok, __r1.stdout
  assert(ok, "lua -v failed")
  local want = "Lua"
  assert(got:find(want, 1, true), "expected '" .. want .. "' in output, got: " .. got)
end
test_lua()

local function test_zip()
  local bin = fs.join(TEST_DIR, "zip")
  local handle = check.must(spawn.spawn({bin, "--version"}))
  local __r2 = check.must(handle:wait())
  local ok, got = __r2.ok, __r2.stdout
  assert(ok, "zip --version failed")
  local want = "Zip"
  assert(got:find(want, 1, true), "expected '" .. want .. "' in output, got: " .. got)
end
test_zip()
