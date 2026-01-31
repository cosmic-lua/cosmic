#!/usr/bin/env cosmic
--- Tests for cosmic.welcome module and -e welcome behavior

local unix = require("cosmo.unix")
local path = require("cosmo.path")
local spawn = require("cosmic.spawn")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Create isolated config dir for tests
local test_config_dir = path.join(tmpdir, ".config", "cosmic")
local marker_file = path.join(test_config_dir, ".welcome-shown")

-- Helper to clean up marker file
local function reset_welcome_state()
  unix.rmrf(test_config_dir)
end

-- Test welcome module API directly
local function test_welcome_module_api()
  reset_welcome_state()

  -- Spawn a process with HOME set to tmpdir to test welcome module
  local script = path.join(tmpdir, "test_welcome_api.lua")
  cosmo.Barf(script, [[
local welcome = require("cosmic.welcome")

-- Test was_shown returns false initially
local shown = welcome.was_shown()
print("initial_was_shown=" .. tostring(shown))

-- Test mark_shown creates the marker
welcome.mark_shown()

-- Test was_shown returns true after marking
shown = welcome.was_shown()
print("after_mark_was_shown=" .. tostring(shown))

-- Test generate returns a string with expected content
local msg = welcome.generate()
print("has_help=" .. tostring(msg:find("%-%-help") ~= nil))
print("has_docs=" .. tostring(msg:find("%-%-docs") ~= nil))
print("has_suppress=" .. tostring(msg:find("COSMIC_NO_WELCOME") ~= nil))
]])

  local ok, out = spawn({cosmic, script}, {env = {"HOME=" .. tmpdir}}):read()
  assert(ok, "script should succeed: " .. tostring(out))
  out = out as string
  assert(out:find("initial_was_shown=false"), "was_shown should be false initially")
  assert(out:find("after_mark_was_shown=true"), "was_shown should be true after marking")
  assert(out:find("has_help=true"), "welcome should mention --help")
  assert(out:find("has_docs=true"), "welcome should mention --docs")
  assert(out:find("has_suppress=true"), "welcome should mention COSMIC_NO_WELCOME")

  reset_welcome_state()
end
test_welcome_module_api()

-- Test that welcome does NOT show when stderr is not a TTY (spawned process)
-- This is the expected behavior - welcome only shows when stderr is a real terminal
local function test_no_welcome_when_not_tty()
  reset_welcome_state()

  -- When spawned, stderr is a pipe (not TTY), so welcome should NOT be shown
  local ok, out = spawn({cosmic, "-e", "print('output')"}, {
    env = {"HOME=" .. tmpdir}
  }):read()
  assert(ok, "-e should succeed")
  out = out as string
  assert(out:find("output"), "should print output: " .. out)

  -- Marker file should NOT exist because stderr is not a TTY
  local marker_path = path.join(tmpdir, ".config", "cosmic", ".welcome-shown")
  local st = unix.stat(marker_path)
  assert(st == nil, "marker file should NOT exist when stderr is not a TTY")

  reset_welcome_state()
end
test_no_welcome_when_not_tty()

-- Test that COSMIC_NO_WELCOME suppresses welcome (even if we manually trigger it)
local function test_no_welcome_env_var()
  reset_welcome_state()

  -- Test that env var is respected by checking if marker is created when
  -- we manually call mark_shown only if env var is not set
  local script = path.join(tmpdir, "test_env_var.lua")
  cosmo.Barf(script, [[
local welcome = require("cosmic.welcome")
if not os.getenv("COSMIC_NO_WELCOME") then
  welcome.mark_shown()
end
print("done")
]])

  -- Without env var - marker should be created
  local ok, out = spawn({cosmic, script}, {
    env = {"HOME=" .. tmpdir}
  }):read()
  assert(ok, "script should succeed")
  local marker_path = path.join(tmpdir, ".config", "cosmic", ".welcome-shown")
  local st = unix.stat(marker_path)
  assert(st ~= nil, "marker should exist when COSMIC_NO_WELCOME not set")

  reset_welcome_state()

  -- With env var - marker should NOT be created
  ok, out = spawn({cosmic, script}, {
    env = {"HOME=" .. tmpdir, "COSMIC_NO_WELCOME=1"}
  }):read()
  assert(ok, "script should succeed with COSMIC_NO_WELCOME")
  st = unix.stat(marker_path)
  assert(st == nil, "marker should NOT exist when COSMIC_NO_WELCOME=1")

  reset_welcome_state()
end
test_no_welcome_env_var()

-- Test that welcome is not shown when marker already exists
local function test_no_welcome_when_already_shown()
  reset_welcome_state()

  -- Create marker file manually
  unix.makedirs(test_config_dir, tonumber("755", 8))
  local f = io.open(marker_file, "w")
  f:close()

  -- Verify it exists
  local st = unix.stat(marker_file)
  assert(st ~= nil, "marker file should exist")

  -- Test was_shown returns true
  local script = path.join(tmpdir, "test_marker.lua")
  cosmo.Barf(script, [[
local welcome = require("cosmic.welcome")
print("was_shown=" .. tostring(welcome.was_shown()))
]])

  local ok, out = spawn({cosmic, script}, {
    env = {"HOME=" .. tmpdir}
  }):read()
  assert(ok, "script should succeed")
  out = out as string
  assert(out:find("was_shown=true"), "was_shown should return true when marker exists")

  reset_welcome_state()
end
test_no_welcome_when_already_shown()

-- Test that welcome goes to stderr (stdout should be clean)
-- Since stderr is not a TTY in spawn, welcome won't be shown, but this
-- tests that even if it were shown, it would go to stderr not stdout
local function test_welcome_goes_to_stderr()
  reset_welcome_state()

  -- Run and capture stdout only - it should just have the -e output
  local ok, stdout = spawn({cosmic, "-e", "io.write('exact')"}, {
    env = {"HOME=" .. tmpdir}
  }):read()
  assert(ok, "-e should succeed")
  stdout = stdout as string

  -- stdout should be exactly "exact" - no welcome message mixed in
  assert(stdout == "exact", "stdout should be exactly 'exact', got: '" .. stdout .. "'")

  reset_welcome_state()
end
test_welcome_goes_to_stderr()

-- Test the full welcome flow with simulated TTY (using a script that manually triggers it)
local function test_full_welcome_flow()
  reset_welcome_state()

  local script = path.join(tmpdir, "test_full_flow.lua")
  cosmo.Barf(script, [[
local welcome = require("cosmic.welcome")

-- Simulate what main.tl does but without the isatty check
local is_first_run = not welcome.was_shown()
local env_suppressed = os.getenv("COSMIC_NO_WELCOME")

print("is_first_run=" .. tostring(is_first_run))
print("env_suppressed=" .. tostring(env_suppressed ~= nil))

-- Simulate showing welcome (without actually writing to stderr in test)
if is_first_run and not env_suppressed then
  local msg = welcome.generate()
  print("would_show_welcome=true")
  print("msg_length=" .. tostring(#msg))
  welcome.mark_shown()
end

-- Second check should show already shown
print("after_was_shown=" .. tostring(welcome.was_shown()))
]])

  local ok, out = spawn({cosmic, script}, {env = {"HOME=" .. tmpdir}}):read()
  assert(ok, "script should succeed: " .. tostring(out))
  out = out as string
  assert(out:find("is_first_run=true"), "should be first run")
  assert(out:find("env_suppressed=false"), "env should not be suppressed")
  assert(out:find("would_show_welcome=true"), "should want to show welcome")
  assert(out:find("after_was_shown=true"), "should be marked as shown")

  -- Marker should exist
  local marker_path = path.join(tmpdir, ".config", "cosmic", ".welcome-shown")
  local st = unix.stat(marker_path)
  assert(st ~= nil, "marker file should exist after full flow")

  reset_welcome_state()
end
test_full_welcome_flow()
