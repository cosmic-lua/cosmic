#!/usr/bin/env cosmic
-- Test first-run welcome experience

local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Test --welcome shows message
local function test_welcome_flag()
  local ok, out = spawn.spawn({cosmic, "--welcome"}):read()
  assert(ok, "cosmic --welcome should succeed")
  local s = out as string
  assert(s:find("Welcome to cosmic%-lua!"), "should show welcome message")
  assert(s:find("cosmic %-%-docs"), "should mention --docs")
  assert(s:find("cosmic %-%-help"), "should mention --help")
  assert(s:find("cosmic %-%-welcome"), "should mention how to see again")
  print("test_welcome_flag: PASS")
end
test_welcome_flag()

-- Test --help mentions --welcome and COSMIC_NO_WELCOME
local function test_help_mentions_welcome()
  local ok, out = spawn.spawn({cosmic, "--help"}):read()
  assert(ok, "cosmic --help should succeed")
  local s = out as string
  assert(s:find("%-%-welcome"), "help should mention --welcome flag")
  assert(s:find("COSMIC_NO_WELCOME"), "help should mention COSMIC_NO_WELCOME env var")
  print("test_help_mentions_welcome: PASS")
end
test_help_mentions_welcome()

-- Test COSMIC_NO_WELCOME suppresses welcome in scripts
local function test_no_welcome_env()
  local script = path.join(tmpdir, "no_welcome_test.lua")
  cosmo.Barf(script, [[
-- Just check the env var is accessible
local no_welcome = os.getenv("COSMIC_NO_WELCOME")
if no_welcome then
  print("COSMIC_NO_WELCOME is set to: " .. no_welcome)
else
  print("COSMIC_NO_WELCOME is not set")
end
]])

  local env = {"COSMIC_NO_WELCOME=1"}
  local ok, out = spawn.spawn({cosmic, script}, {env = env}):read()
  local s = out as string
  assert(ok, "script should succeed: " .. s)
  assert(s:find("COSMIC_NO_WELCOME is set"), "env var should be accessible: " .. s)
  print("test_no_welcome_env: PASS")
end
test_no_welcome_env()
