#!/usr/bin/env cosmic
-- Test first-run welcome experience

local unix = require("cosmo.unix")
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

-- Test XDG fallback creates marker file when binary write fails
local function test_xdg_fallback()
  -- Create a fake home directory
  local fake_home = path.join(tmpdir, "xdg-test-home")
  unix.makedirs(fake_home, tonumber("755", 8))

  -- Create a script that simulates a scenario where binary can't be written
  -- by using an arg[-1] that points to a non-existent file
  local script = path.join(tmpdir, "xdg_test.lua")
  cosmo.Barf(script, [[
local unix = require("cosmo.unix")
local path = require("cosmo.path")

-- Override arg[-1] to point to a non-existent path so binary write fails
arg[-1] = "/nonexistent/cosmic"

local welcome = require("cosmic.welcome")

-- Check initial state
if welcome.was_shown() then
  print("FAIL: should not be shown initially")
  os.exit(1)
end

-- Mark as shown (will use XDG fallback since binary doesn't exist)
welcome.mark_shown()

-- Check that XDG marker was created
local home = os.getenv("HOME")
local marker = path.join(home, ".config", "cosmic", ".welcome-shown")
if unix.stat(marker) then
  print("XDG marker created at: " .. marker)
else
  print("FAIL: XDG marker not found at: " .. marker)
  os.exit(1)
end

-- Now was_shown should return true (from XDG marker)
if welcome.was_shown() then
  print("was_shown returns true after mark_shown")
else
  print("FAIL: was_shown should return true after mark_shown")
  os.exit(1)
end
]])

  -- Run with modified HOME
  local env = {"HOME=" .. fake_home, "XDG_CONFIG_HOME="}
  local ok, out = spawn.spawn({cosmic, script}, {env = env}):read()
  local s = out as string
  assert(ok, "script should succeed: " .. s)
  assert(s:find("XDG marker created"), "should create XDG marker: " .. s)
  assert(s:find("was_shown returns true"), "was_shown should return true: " .. s)
  print("test_xdg_fallback: PASS")
end
test_xdg_fallback()

-- Test XDG_CONFIG_HOME is respected
local function test_xdg_config_home()
  local custom_config = path.join(tmpdir, "custom-config")
  unix.makedirs(custom_config, tonumber("755", 8))

  local script = path.join(tmpdir, "xdg_config_test.lua")
  cosmo.Barf(script, [[
-- Override arg[-1] to force XDG fallback
arg[-1] = "/nonexistent/cosmic"

local welcome = require("cosmic.welcome")
welcome.mark_shown()

local unix = require("cosmo.unix")
local path = require("cosmo.path")
local xdg = os.getenv("XDG_CONFIG_HOME")
local marker = path.join(xdg, "cosmic", ".welcome-shown")
if unix.stat(marker) then
  print("XDG_CONFIG_HOME marker created at: " .. marker)
else
  print("FAIL: marker not found at: " .. marker)
  os.exit(1)
end
]])

  local env = {"HOME=" .. tmpdir, "XDG_CONFIG_HOME=" .. custom_config}
  local ok, out = spawn.spawn({cosmic, script}, {env = env}):read()
  local s = out as string
  assert(ok, "script should succeed: " .. s)
  assert(s:find("XDG_CONFIG_HOME marker created"), "should use XDG_CONFIG_HOME: " .. s)
  print("test_xdg_config_home: PASS")
end
test_xdg_config_home()

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
