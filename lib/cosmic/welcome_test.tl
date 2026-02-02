#!/usr/bin/env cosmic
-- Test first-run welcome experience

local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")
local sys = require("cosmic.sys")

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
  local test_script = path.join(tmpdir, "no_welcome_test.lua")
  cosmo.Barf(test_script, [[
-- Just check the env var is accessible
local no_welcome = os.getenv("COSMIC_NO_WELCOME")
if no_welcome then
  print("COSMIC_NO_WELCOME is set to: " .. no_welcome)
else
  print("COSMIC_NO_WELCOME is not set")
end
]])

  local env = {"COSMIC_NO_WELCOME=1"}
  local ok, out = spawn.spawn({cosmic, test_script}, {env = env}):read()
  local s = out as string
  assert(ok, "script should succeed: " .. s)
  assert(s:find("COSMIC_NO_WELCOME is set"), "env var should be accessible: " .. s)
  print("test_no_welcome_env: PASS")
end
test_no_welcome_env()

-- PTY-based tests require Linux's script command (different syntax on macOS)
if sys.host_os() ~= "linux" then
  print("Skipping PTY-based tests on " .. sys.host_os())
  return
end

-- Helper to run cosmic in a PTY (using script command) to trigger TTY-based welcome
local function run_with_pty(args: {string}): boolean, string
  -- Copy binary to temp location so it's fresh (no embedded marker)
  local fresh_cosmic = path.join(tmpdir, "cosmic-fresh-" .. tostring(os.time()))
  local copy_ok = spawn.spawn({"cp", cosmic, fresh_cosmic}):wait()
  assert(copy_ok, "failed to copy cosmic binary")

  -- Build command string for script
  local cmd = fresh_cosmic
  for _, a in ipairs(args) do
    -- Escape single quotes in arguments
    cmd = cmd .. " '" .. a:gsub("'", "'\\''") .. "'"
  end

  -- Use script command to provide PTY (merges stdout/stderr)
  local ok, out = spawn.spawn({"script", "-qc", cmd, "/dev/null"}):read()
  return ok as boolean, out as string
end

-- Test welcome appears on first run with -e flag
local function test_welcome_with_e_flag()
  local ok, out = run_with_pty({"-e", "print('hello')"})
  assert(ok, "cosmic -e should succeed: " .. out)
  assert(out:find("Welcome to cosmic%-lua!"), "welcome should appear with -e: " .. out)
  assert(out:find("hello"), "should execute the statement: " .. out)
  print("test_welcome_with_e_flag: PASS")
end
test_welcome_with_e_flag()

-- Test welcome appears on first run with -v flag
local function test_welcome_with_v_flag()
  local ok, out = run_with_pty({"-v"})
  assert(ok, "cosmic -v should succeed: " .. out)
  assert(out:find("Welcome to cosmic%-lua!"), "welcome should appear with -v: " .. out)
  assert(out:find("Lua 5.4"), "should show version: " .. out)
  print("test_welcome_with_v_flag: PASS")
end
test_welcome_with_v_flag()

-- Test welcome does NOT appear on second run (marker embedded)
local function test_welcome_not_shown_twice()
  -- Copy binary to temp location
  local fresh_cosmic = path.join(tmpdir, "cosmic-twice-test")
  local copy_ok = spawn.spawn({"cp", cosmic, fresh_cosmic}):wait()
  assert(copy_ok, "failed to copy cosmic binary")

  -- First run - should show welcome
  local cmd1 = fresh_cosmic .. " -v"
  local ok1, out1 = spawn.spawn({"script", "-qc", cmd1, "/dev/null"}):read()
  local s1 = out1 as string
  assert(ok1, "first run should succeed: " .. s1)
  assert(s1:find("Welcome to cosmic%-lua!"), "first run should show welcome: " .. s1)

  -- Second run with SAME binary - should NOT show welcome (marker embedded)
  local ok2, out2 = spawn.spawn({"script", "-qc", cmd1, "/dev/null"}):read()
  local s2 = out2 as string
  assert(ok2, "second run should succeed: " .. s2)
  assert(not s2:find("Welcome to cosmic%-lua!"), "second run should NOT show welcome: " .. s2)
  assert(s2:find("Lua 5.4"), "second run should still show version: " .. s2)

  print("test_welcome_not_shown_twice: PASS")
end
test_welcome_not_shown_twice()

-- Test COSMIC_NO_WELCOME suppresses welcome even on first run
local function test_no_welcome_env_suppresses()
  -- Copy binary to temp location
  local fresh_cosmic = path.join(tmpdir, "cosmic-no-welcome-test")
  local copy_ok = spawn.spawn({"cp", cosmic, fresh_cosmic}):wait()
  assert(copy_ok, "failed to copy cosmic binary")

  -- Run with COSMIC_NO_WELCOME set
  local cmd = "COSMIC_NO_WELCOME=1 " .. fresh_cosmic .. " -v"
  local ok, out = spawn.spawn({"script", "-qc", cmd, "/dev/null"}):read()
  local s = out as string
  assert(ok, "should succeed: " .. s)
  assert(not s:find("Welcome to cosmic%-lua!"), "welcome should be suppressed: " .. s)
  assert(s:find("Lua 5.4"), "should still show version: " .. s)

  print("test_no_welcome_env_suppresses: PASS")
end
test_no_welcome_env_suppresses()
