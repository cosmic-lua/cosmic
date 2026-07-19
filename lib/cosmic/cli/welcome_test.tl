#!/usr/bin/env cosmic
-- Test first-run welcome experience

local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
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
  fs.write(test_script, [[
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
  local write_ok, _ = fs.write(probe, "local tty = require('cosmic.tty'); io.stderr:write(tostring(tty.stderr_isatty()))\n")
  if not write_ok then
    return false
  end
  -- Run cosmic through script to simulate a PTY (suppress welcome so this
  -- probe leaves no first-run state behind)
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

-- The "welcome shown" marker lives in $XDG_CONFIG_HOME/cosmic (#510 step
-- 10), so each test isolates first-run state with its own config dir.
local function fresh_confdir(name: string): string
  local dir = fs.join(tmpdir, "conf-" .. name)
  assert(fs.makedirs(dir))
  return dir
end

-- Copy the cosmic binary so no test ever touches the shared TEST_BIN one.
local function copy_binary(name: string): string
  local dest = fs.join(tmpdir, "cosmic-" .. name)
  local cp = spawn.run({"cp", cosmic, dest}) as spawn.Result
  assert(cp.ok, "failed to copy cosmic binary")
  return dest
end

-- Helper to run a cosmic binary in a PTY (via the script command, which
-- merges stdout/stderr) with first-run state isolated to confdir.
local function run_with_pty(bin: string, args: {string}, confdir: string): boolean, string
  local cmd = "XDG_CONFIG_HOME='" .. confdir .. "' " .. bin
  for _, a in ipairs(args) do
    -- Escape single quotes in arguments
    cmd = cmd .. " '" .. a:gsub("'", "'\\''") .. "'"
  end
  local r = spawn.run({"script", "-qc", cmd, "/dev/null"}) as spawn.Result
  return r.ok, r.stdout
end

-- Test welcome appears on first run with -e flag
local function test_welcome_with_e_flag()
  local ok, out = run_with_pty(copy_binary("e-flag"), {"-e", "print('hello')"}, fresh_confdir("e-flag"))
  assert(ok, "cosmic -e should succeed: " .. out)
  assert(out:find("Welcome to cosmic%-lua!"), "welcome should appear with -e: " .. out)
  assert(out:find("hello"), "should execute the statement: " .. out)
  print("test_welcome_with_e_flag: PASS")
end
test_welcome_with_e_flag()

-- Test welcome does NOT appear with -v flag (early-return skips welcome)
local function test_welcome_skipped_with_v_flag()
  local ok, out = run_with_pty(copy_binary("v-flag"), {"-v"}, fresh_confdir("v-flag"))
  assert(ok, "cosmic -v should succeed: " .. out)
  assert(not out:find("Welcome to cosmic%-lua!"), "welcome should NOT appear with -v: " .. out)
  assert(out:find("Lua 5%.4") or out:find("cosmic%-lua"), "should show version: " .. out)
  print("test_welcome_skipped_with_v_flag: PASS")
end
test_welcome_skipped_with_v_flag()

-- #510 step 10: showing the welcome must NOT modify the executable.
-- The old marker was zip-appended to the running binary, which broke
-- release checksum verification (and loops forever on Windows, where
-- the running exe is locked).
local function test_welcome_does_not_modify_binary()
  local bin = copy_binary("immutable")
  local before = assert(fs.read(bin))
  local ok, out = run_with_pty(bin, {"-e", "print(1)"}, fresh_confdir("immutable"))
  assert(ok, "run should succeed: " .. out)
  assert(out:find("Welcome to cosmic%-lua!"), "welcome should appear: " .. out)
  local after = assert(fs.read(bin))
  assert(#before == #after and before == after,
    "showing the welcome must not modify the binary (size "
    .. tostring(#before) .. " -> " .. tostring(#after) .. ")")
  print("test_welcome_does_not_modify_binary: PASS")
end
test_welcome_does_not_modify_binary()

-- #510 step 10: the shown marker is written under $XDG_CONFIG_HOME.
local function test_marker_written_to_config_dir()
  local confdir = fresh_confdir("marker")
  local ok, out = run_with_pty(copy_binary("marker"), {"-e", "print(1)"}, confdir)
  assert(ok, "run should succeed: " .. out)
  assert(out:find("Welcome to cosmic%-lua!"), "welcome should appear: " .. out)
  assert(fs.isfile(fs.join(confdir, "cosmic", "welcome-shown")),
    "marker should be written to $XDG_CONFIG_HOME/cosmic/welcome-shown")
  print("test_marker_written_to_config_dir: PASS")
end
test_marker_written_to_config_dir()

-- With XDG_CONFIG_HOME unset, the marker falls back to $HOME/.config.
local function test_marker_home_fallback()
  local home = fs.join(tmpdir, "home-fallback")
  assert(fs.makedirs(home))
  local bin = copy_binary("home-fallback")
  local cmd = "XDG_CONFIG_HOME= HOME='" .. home .. "' " .. bin .. " -e 'print(1)'"
  local r = spawn.run({"script", "-qc", cmd, "/dev/null"}) as spawn.Result
  assert(r.ok, "run should succeed: " .. r.stdout)
  assert(r.stdout:find("Welcome to cosmic%-lua!"), "welcome should appear: " .. r.stdout)
  assert(fs.isfile(fs.join(home, ".config", "cosmic", "welcome-shown")),
    "marker should fall back to $HOME/.config/cosmic/welcome-shown")
  print("test_marker_home_fallback: PASS")
end
test_marker_home_fallback()

-- Test welcome does NOT appear on second run (same binary, same config)
local function test_welcome_not_shown_twice()
  local bin = copy_binary("twice")
  local confdir = fresh_confdir("twice")
  local ok1, s1 = run_with_pty(bin, {"-e", "print(1)"}, confdir)
  assert(ok1, "first run should succeed: " .. s1)
  assert(s1:find("Welcome to cosmic%-lua!"), "first run should show welcome: " .. s1)

  local ok2, s2 = run_with_pty(bin, {"-e", "print(1)"}, confdir)
  assert(ok2, "second run should succeed: " .. s2)
  assert(not s2:find("Welcome to cosmic%-lua!"), "second run should NOT show welcome: " .. s2)
  print("test_welcome_not_shown_twice: PASS")
end
test_welcome_not_shown_twice()

-- A marker embedded in the binary still counts as shown: it lets a
-- distributor pre-seed a binary, and keeps copies mutated by older
-- cosmic versions (which zip-appended the marker) quiet.
local function test_embedded_marker_suppresses()
  local czip = require("cosmic.zip")
  local bin = copy_binary("embedded")
  local a = assert(czip.appender(bin)) as czip.Appender
  assert(a:add(".cosmic/welcome-shown", ""))
  a:close()
  local ok, out = run_with_pty(bin, {"-e", "print(1)"}, fresh_confdir("embedded"))
  assert(ok, "run should succeed: " .. out)
  assert(not out:find("Welcome to cosmic%-lua!"),
    "embedded marker should suppress welcome: " .. out)
  print("test_embedded_marker_suppresses: PASS")
end
test_embedded_marker_suppresses()

-- Test COSMIC_NO_WELCOME suppresses welcome even on first run
local function test_no_welcome_env_suppresses()
  local bin = copy_binary("no-welcome")
  local confdir = fresh_confdir("no-welcome")
  local cmd = "COSMIC_NO_WELCOME=1 XDG_CONFIG_HOME='" .. confdir .. "' " .. bin .. " -e 'print(1)'"
  local r = spawn.run({"script", "-qc", cmd, "/dev/null"}) as spawn.Result
  local s = r.stdout
  assert(r.ok, "should succeed: " .. s)
  assert(not s:find("Welcome to cosmic%-lua!"), "welcome should be suppressed: " .. s)
  print("test_no_welcome_env_suppresses: PASS")
end
test_no_welcome_env_suppresses()
