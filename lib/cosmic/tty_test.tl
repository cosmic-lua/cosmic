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
  if not tty.isatty(1) then
    io.stderr:write("SKIP: test_winsize_structure (stdout is not a tty)\n")
    return
  end
  local ws, err = tty.winsize(1)
  if ws then
    local w = ws as tty.WinSize
    assert(w.rows ~= nil, "winsize should have rows field")
    assert(w.cols ~= nil, "winsize should have cols field")
    assert(type(w.rows) == "number", "rows should be a number")
    assert(type(w.cols) == "number", "cols should be a number")
    assert(w.rows > 0, "rows should be positive")
    assert(w.cols > 0, "cols should be positive")
  end
end
test_winsize_structure()

-- Test termios function exports

local function test_termios_exports()
  assert(tty.getattr ~= nil, "getattr function should be exported")
  assert(tty.setattr ~= nil, "setattr function should be exported")
  assert(tty.raw ~= nil, "raw function should be exported")
  assert(tty.noecho ~= nil, "noecho function should be exported")
  assert(tty.restore ~= nil, "restore function should be exported")
end
test_termios_exports()

local function test_termios_constants()
  assert(tty.NOW ~= nil, "NOW constant should be exported")
  assert(tty.DRAIN ~= nil, "DRAIN constant should be exported")
  assert(tty.FLUSH ~= nil, "FLUSH constant should be exported")
  assert(tty.ECHO ~= nil, "ECHO constant should be exported")
  assert(tty.ICANON ~= nil, "ICANON constant should be exported")
  assert(tty.ISIG ~= nil, "ISIG constant should be exported")
  assert(tty.IEXTEN ~= nil, "IEXTEN constant should be exported")
end
test_termios_constants()

local function test_getattr_non_tty()
  -- When not a tty, getattr should fail with error
  if not tty.isatty(0) then
    local termios, err = tty.getattr(0)
    assert(termios == nil, "getattr should return nil for non-tty")
    assert(err ~= nil, "getattr should return error message for non-tty")
  end
end
test_getattr_non_tty()

local function test_getattr_structure()
  -- If stdin is a tty, verify getattr returns proper structure
  if not tty.isatty(0) then
    io.stderr:write("SKIP: test_getattr_structure (stdin is not a tty)\n")
    return
  end
  local termios, err = tty.getattr(0)
  if termios then
    local t = termios as tty.Termios
    assert(t.iflag ~= nil, "termios should have iflag")
    assert(t.oflag ~= nil, "termios should have oflag")
    assert(t.cflag ~= nil, "termios should have cflag")
    assert(t.lflag ~= nil, "termios should have lflag")
    assert(t.cc ~= nil, "termios should have cc array")
    assert(type(t.iflag) == "number", "iflag should be number")
    assert(type(t.lflag) == "number", "lflag should be number")
  end
end
test_getattr_structure()

local function test_raw_non_tty()
  -- When not a tty, raw should fail with error
  if not tty.isatty(0) then
    local original, err = tty.raw(0)
    assert(original == nil, "raw should return nil for non-tty")
    assert(err ~= nil, "raw should return error message for non-tty")
  end
end
test_raw_non_tty()

local function test_noecho_non_tty()
  -- When not a tty, noecho should fail with error
  if not tty.isatty(0) then
    local original, err = tty.noecho(0)
    assert(original == nil, "noecho should return nil for non-tty")
    assert(err ~= nil, "noecho should return error message for non-tty")
  end
end
test_noecho_non_tty()

-- Test getpass function

local function test_getpass_exported()
  assert(tty.getpass ~= nil, "getpass function should be exported")
  assert(type(tty.getpass) == "function", "getpass should be a function")
end
test_getpass_exported()

local function test_getpass_non_tty_eof()
  -- When stdin is not a tty and is at EOF, getpass should return nil, "EOF"
  if not tty.isatty(0) then
    -- stdin in test env is closed/at EOF or piped with no data
    -- We can't easily test the EOF path without modifying stdin,
    -- but we can verify the function is callable without panicking.
    -- The non-tty path reads from stdin; if stdin has data it returns a line.
    -- Skip actual invocation since it would consume stdin unexpectedly.
    io.stderr:write("SKIP: test_getpass_non_tty_eof (cannot safely consume stdin in test)\n")
  end
end
test_getpass_non_tty_eof()

local function test_getpass_tty_only()
  -- When stdin is a tty, getpass would prompt interactively — skip in test env.
  if tty.isatty(0) then
    io.stderr:write("SKIP: test_getpass_tty_only (stdin is a tty, interactive test not supported)\n")
  else
    -- Non-tty: function exists and has correct signature, already tested above.
    assert(tty.getpass ~= nil, "getpass exported")
  end
end
test_getpass_tty_only()

-- make_raw: pure raw-mode computation, unit-testable without a tty
-- (issue #529, review item 35).

local function fixture_termios(): tty.Termios
  local cc: {number} = {}
  for i = 1, 20 do
    cc[i] = i
  end
  return {
    iflag = tty.IXON | tty.ICRNL | tty.BRKINT,
    oflag = tty.OPOST,
    cflag = 0,
    lflag = tty.ECHO | tty.ICANON | tty.ISIG | tty.IEXTEN,
    cc = cc,
    ispeed = 15,
    ospeed = 15,
  }
end

local function test_make_raw_clears_input_and_output_flags()
  local t = fixture_termios()
  local raw = tty.make_raw(t)
  assert(raw.iflag & tty.IXON == 0, "raw mode must clear IXON (Ctrl-S freeze)")
  assert(raw.iflag & tty.ICRNL == 0, "raw mode must clear ICRNL (\\r translation)")
  assert(raw.iflag & tty.BRKINT == 0, "raw mode must clear BRKINT")
  assert(raw.oflag & tty.OPOST == 0, "raw mode must clear OPOST")
  assert(raw.lflag & tty.ECHO == 0, "raw mode must clear ECHO")
  assert(raw.lflag & tty.ICANON == 0, "raw mode must clear ICANON")
  assert(raw.lflag & tty.ISIG == 0, "raw mode must clear ISIG by default")
  assert(raw.lflag & tty.IEXTEN == 0, "raw mode must clear IEXTEN")
end
test_make_raw_clears_input_and_output_flags()

local function test_make_raw_sets_vmin_vtime()
  local t = fixture_termios()
  local raw = tty.make_raw(t)
  local vmin = (tty.VMIN + 1) as integer
  local vtime = (tty.VTIME + 1) as integer
  assert(raw.cc[vmin] == 1, "raw mode must set VMIN=1")
  assert(raw.cc[vtime] == 0, "raw mode must set VTIME=0")
end
test_make_raw_sets_vmin_vtime()

local function test_make_raw_keep_signals()
  local t = fixture_termios()
  local raw = tty.make_raw(t, {keep_signals = true})
  assert(raw.lflag & tty.ISIG ~= 0, "keep_signals must preserve ISIG")
  assert(raw.lflag & tty.ECHO == 0, "keep_signals still clears ECHO")
end
test_make_raw_keep_signals()

local function test_make_raw_does_not_alias_or_mutate_input()
  local t = fixture_termios()
  local raw = tty.make_raw(t)
  local vmin = (tty.VMIN + 1) as integer
  local vtime = (tty.VTIME + 1) as integer
  assert(raw.cc ~= t.cc, "make_raw must deep-copy cc, not alias it")
  assert(t.iflag & tty.IXON ~= 0, "make_raw must not mutate its input")
  assert(t.cc[vmin] ~= raw.cc[vmin] or t.cc[vtime] ~= raw.cc[vtime],
    "input cc must keep its original values")
  raw.cc[1] = 999
  assert(t.cc[1] ~= 999, "mutating the result must not corrupt the input")
end
test_make_raw_does_not_alias_or_mutate_input()

local function test_winsize_error_names_errno()
  local ws, err = tty.winsize(999)
  assert(ws == nil, "winsize on a bad fd should fail")
  assert(type(err) == "string" and err:match("E%u+"),
    "winsize error should name the errno, got: " .. tostring(err))
end
test_winsize_error_names_errno()
