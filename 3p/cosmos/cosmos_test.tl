#!/usr/bin/env cosmic

local spawn = require("cosmic.child")
local fs = require("cosmic.fs")

global TEST_DIR: string

local function test_lua()
  local bin = fs.join(TEST_DIR, "lua")
  local handle, err = spawn.spawn({bin, "-v"})
  assert(handle, "lua spawn failed: " .. tostring(err))
  local __r1 = (handle as spawn.Handle):wait() as spawn.Result
  local ok, got = __r1.ok, __r1.stdout
  assert(ok, "lua -v failed")
  local want = "Lua"
  assert((got as string):find(want, 1, true), "expected '" .. want .. "' in output, got: " .. (got as string))
end
test_lua()

local function test_zip()
  local bin = fs.join(TEST_DIR, "zip")
  local handle, err = spawn.spawn({bin, "--version"})
  assert(handle, "zip spawn failed: " .. tostring(err))
  local __r2 = (handle as spawn.Handle):wait() as spawn.Result
  local ok, got = __r2.ok, __r2.stdout
  assert(ok, "zip --version failed")
  local want = "Zip"
  assert((got as string):find(want, 1, true), "expected '" .. want .. "' in output, got: " .. (got as string))
end
test_zip()
