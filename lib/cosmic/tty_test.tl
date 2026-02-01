#!/usr/bin/env cosmic
local tty = require("cosmic.tty")

-- Test module exports

local function test_module_exports()
  assert(tty.isatty ~= nil, "isatty function should be exported")
  assert(tty.winsize ~= nil, "winsize function should be exported")
  assert(tty.stdin_isatty ~= nil, "stdin_isatty function should be exported")
  assert(tty.stdout_isatty ~= nil, "stdout_isatty function should be exported")
  assert(tty.stderr_isatty ~= nil, "stderr_isatty function should be exported")
end
test_module_exports()

-- Test isatty with standard file descriptors
-- Note: In test environments, stdin/stdout/stderr are typically not ttys

local function test_isatty_returns_boolean()
  local result = tty.isatty(0)
  assert(type(result) == "boolean", "isatty should return boolean, got " .. type(result))
end
test_isatty_returns_boolean()

local function test_isatty_stdin()
  local result = tty.isatty(0)
  -- In test environment, stdin is typically not a tty (piped)
  assert(type(result) == "boolean", "isatty(0) should return boolean")
end
test_isatty_stdin()

local function test_isatty_stdout()
  local result = tty.isatty(1)
  assert(type(result) == "boolean", "isatty(1) should return boolean")
end
test_isatty_stdout()

local function test_isatty_stderr()
  local result = tty.isatty(2)
  assert(type(result) == "boolean", "isatty(2) should return boolean")
end
test_isatty_stderr()

-- Test convenience functions

local function test_stdin_isatty()
  local result = tty.stdin_isatty()
  assert(type(result) == "boolean", "stdin_isatty should return boolean")
end
test_stdin_isatty()

local function test_stdout_isatty()
  local result = tty.stdout_isatty()
  assert(type(result) == "boolean", "stdout_isatty should return boolean")
end
test_stdout_isatty()

local function test_stderr_isatty()
  local result = tty.stderr_isatty()
  assert(type(result) == "boolean", "stderr_isatty should return boolean")
end
test_stderr_isatty()

-- Test winsize function

local function test_winsize_non_tty()
  -- When not a tty, winsize should return nil with error message
  -- Open a regular file to get a non-tty fd
  local f = io.open("/dev/null", "r")
  if f then
    -- /dev/null is not a tty, so winsize should fail
    -- But we're testing with fd numbers, so test with what we have
    f:close()
  end
  -- In test environment, fd 0 is likely not a tty
  if not tty.isatty(0) then
    local ws, err = tty.winsize(0)
    -- Should return nil or a valid winsize
    if ws == nil then
      assert(err ~= nil, "winsize should return error message when not a tty")
    end
  end
end
test_winsize_non_tty()

local function test_winsize_structure()
  -- If stdout is a tty, verify winsize returns proper structure
  if tty.isatty(1) then
    local ws, err = tty.winsize(1)
    if ws then
      assert(ws.rows ~= nil, "winsize should have rows field")
      assert(ws.cols ~= nil, "winsize should have cols field")
      assert(type(ws.rows) == "number", "rows should be a number")
      assert(type(ws.cols) == "number", "cols should be a number")
      assert(ws.rows > 0, "rows should be positive")
      assert(ws.cols > 0, "cols should be positive")
    end
  end
end
test_winsize_structure()
