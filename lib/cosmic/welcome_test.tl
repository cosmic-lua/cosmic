#!/usr/bin/env cosmic
-- Test first-run welcome experience

local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
local cio = require("cosmic.io")
local sys = require("cosmic.sys")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Test --welcome shows message
local function test_welcome_flag()
  local r = spawn.run({cosmic, "--welcome"}) as spawn.Result
  assert(r.ok, "cosmic --welcome should succeed")
  local s = r.stdout
  assert(s:find("Welcome to cosmic%-lua!"), "should show welcome message")
  assert(s:find("cosmic %-%-docs"), "should mention --docs")
  assert(s:find("cosmic %-%-help"), "should mention --help")
  assert(s:find("cosmic %-%-welcome"), "should mention how to see again")
  print("test_welcome_flag: PASS")
end
test_welcome_flag()

-- Test --help mentions --welcome and COSMIC_NO_WELCOME
local function test_help_mentions_welcome()
  local r = spawn.run({cosmic, "--help"}) as spawn.Result
  assert(r.ok, "cosmic --help should succeed")
  local s = r.stdout
  assert(s:find("%-%-welcome"), "help should mention --welcome flag")
  assert(s:find("COSMIC_NO_WELCOME"), "help should mention COSMIC_NO_WELCOME env var")
  print("test_help_mentions_welcome: PASS")
end
test_help_mentions_welcome()

-- Test COSMIC_NO_WELCOME suppresses welcome in scripts
local function test_no_welcome_env()
  local test_script = fs.join(tmpdir, "no_welcome_test.lua")
  cio.barf(test_script, [[
-- Just check the env var is accessible
local no_welcome = os.getenv("COSMIC_NO_WELCOME")
if no_welcome then
  print("COSMIC_NO_WELCOME is set to: " .. no_welcome)
else
  print("COSMIC_NO_WELCOME is not set")
end
]])

  local env = {"COSMIC_NO_WELCOME=1"}
  local r = spawn.run({cosmic, test_script}, {env = env}) as spawn.Result
  local s = r.stdout
  assert(r.ok, "script should succeed: " .. s)
  assert(s:find("COSMIC_NO_WELCOME is set"), "env var should be accessible: " .. s)
  print("test_no_welcome_env: PASS")
end
test_no_welcome_env()

-- PTY-based tests require Linux's script command (different syntax on macOS)
if sys.host_os() ~= "linux" then
  print("Skipping PTY-based tests on " .. sys.host_os())
  return
end

-- Check if PTY creation is available AND cosmic can detect the TTY inside it
local function pty_available(): boolean
  -- Write a tiny probe script that prints tty detection result to stderr
  local probe = fs.join(tmpdir, "pty_probe.lua")
  local io_mod = require("cosmic.io")
  local write_ok, _ = io_mod.barf(probe, "local tty = require('cosmic.tty'); io.stderr:write(tostring(tty.stderr_isatty()))\n")
  if not write_ok then
    return false
  end
  -- Run cosmic through script to simulate a PTY (suppress welcome to avoid mutating binary)
  local cmd = "COSMIC_NO_WELCOME=1 " .. cosmic .. " " .. probe
  local r = spawn.run({"script", "-qc", cmd, "/dev/null"}) as spawn.Result
  local s = r.stdout
  if not r.ok then
    return false
  end
  if s:find("failed to create pseudo%-terminal") or s:find("Permission denied") then
    return false
  end
  -- PTY is only usable if cosmic actually detects a TTY inside it
  if not s:find("true") then
    return false
  end
  return true
end

if not pty_available() then
  print("Skipping PTY-based tests: pseudo-terminal creation not available")
  return
end

-- Helper to run cosmic in a PTY (using script command) to trigger TTY-based welcome
local function run_with_pty(args: {string}): boolean, string
  -- Copy binary to temp location so it's fresh (no embedded marker)
  local fresh_cosmic = fs.join(tmpdir, "cosmic-fresh-" .. tostring(os.time()))
  local cp = spawn.run({"cp", cosmic, fresh_cosmic}) as spawn.Result
  assert(cp.ok, "failed to copy cosmic binary")

  -- Build command string for script
  local cmd = fresh_cosmic
  for _, a in ipairs(args) do
    -- Escape single quotes in arguments
    cmd = cmd .. " '" .. a:gsub("'", "'\\''") .. "'"
  end

  -- Use script command to provide PTY (merges stdout/stderr)
  local r = spawn.run({"script", "-qc", cmd, "/dev/null"}) as spawn.Result
  return r.ok, r.stdout
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

-- Test welcome does NOT appear with -v flag (early-return skips welcome)
local function test_welcome_skipped_with_v_flag()
  local ok, out = run_with_pty({"-v"})
  assert(ok, "cosmic -v should succeed: " .. out)
  assert(not out:find("Welcome to cosmic%-lua!"), "welcome should NOT appear with -v: " .. out)
  assert(out:find("Lua 5%.4") or out:find("cosmic%-lua"), "should show version: " .. out)
  print("test_welcome_skipped_with_v_flag: PASS")
end
test_welcome_skipped_with_v_flag()

-- Test welcome does NOT appear on second run (marker embedded)
local function test_welcome_not_shown_twice()
  -- Copy binary to temp location
  local fresh_cosmic = fs.join(tmpdir, "cosmic-twice-test")
  local cp = spawn.run({"cp", cosmic, fresh_cosmic}) as spawn.Result
  assert(cp.ok, "failed to copy cosmic binary")

  -- First run - should show welcome (use -e to avoid early-return)
  local cmd1 = fresh_cosmic .. " -e 'print(1)'"
  local r1 = spawn.run({"script", "-qc", cmd1, "/dev/null"}) as spawn.Result
  local s1 = r1.stdout
  assert(r1.ok, "first run should succeed: " .. s1)
  assert(s1:find("Welcome to cosmic%-lua!"), "first run should show welcome: " .. s1)

  -- Second run with SAME binary - should NOT show welcome (marker embedded)
  local r2 = spawn.run({"script", "-qc", cmd1, "/dev/null"}) as spawn.Result
  local s2 = r2.stdout
  assert(r2.ok, "second run should succeed: " .. s2)
  assert(not s2:find("Welcome to cosmic%-lua!"), "second run should NOT show welcome: " .. s2)

  print("test_welcome_not_shown_twice: PASS")
end
test_welcome_not_shown_twice()

-- Test COSMIC_NO_WELCOME suppresses welcome even on first run
local function test_no_welcome_env_suppresses()
  -- Copy binary to temp location
  local fresh_cosmic = fs.join(tmpdir, "cosmic-no-welcome-test")
  local cp = spawn.run({"cp", cosmic, fresh_cosmic}) as spawn.Result
  assert(cp.ok, "failed to copy cosmic binary")

  -- Run with COSMIC_NO_WELCOME set (use -e to avoid early-return)
  local cmd = "COSMIC_NO_WELCOME=1 " .. fresh_cosmic .. " -e 'print(1)'"
  local r = spawn.run({"script", "-qc", cmd, "/dev/null"}) as spawn.Result
  local s = r.stdout
  assert(r.ok, "should succeed: " .. s)
  assert(not s:find("Welcome to cosmic%-lua!"), "welcome should be suppressed: " .. s)

  print("test_no_welcome_env_suppresses: PASS")
end
test_no_welcome_env_suppresses()
