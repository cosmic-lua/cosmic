#!/usr/bin/env cosmic
local cfd = require("cosmic.fd")
local fs = require("cosmic.fs")
local spawn = require("cosmic.child")
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

-- isatty (issue #505): assert real verdicts on fds whose tty-ness is
-- known, instead of only checking the return type.

local function test_isatty_regular_file_is_false()
  local test_file = fs.join(os.getenv("TEST_TMPDIR") as string, "not_a_tty")
  fs.write(test_file, "x")
  local h = cfd.open(test_file, cfd.O_RDONLY)
  assert(h, "should open the scratch file")
  local hh = h as cfd.Handle
  assert(tty.isatty(hh:fd()) == false, "a regular file fd is not a tty")
  hh:close()
end
test_isatty_regular_file_is_false()

local function test_isatty_bad_fd_is_false()
  assert(tty.isatty(999) == false, "an unopened fd is not a tty")
end
test_isatty_bad_fd_is_false()

local function test_isatty_pty_master_is_true()
  -- A pty master is the one fd guaranteed to BE a tty. /dev/ptmx exists
  -- on Linux; elsewhere this case is exercised wherever the device exists.
  if not fs.exists("/dev/ptmx") then
    return
  end
  local h, err = cfd.open("/dev/ptmx", cfd.O_RDWR)
  assert(h, "opening /dev/ptmx should succeed: " .. tostring(err))
  local hh = h as cfd.Handle
  assert(tty.isatty(hh:fd()) == true, "a pty master must report as a tty")
  hh:close()
end
test_isatty_pty_master_is_true()

local function test_convenience_functions_agree_with_isatty()
  assert(tty.stdin_isatty() == tty.isatty(0), "stdin_isatty must equal isatty(0)")
  assert(tty.stdout_isatty() == tty.isatty(1), "stdout_isatty must equal isatty(1)")
  assert(tty.stderr_isatty() == tty.isatty(2), "stderr_isatty must equal isatty(2)")
end
test_convenience_functions_agree_with_isatty()

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
  local ws, _err = tty.winsize(1)
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
  local termios, _err = tty.getattr(0)
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

-- getpass (issue #505): exercised end-to-end in a subprocess with a
-- piped (non-tty) stdin, instead of only checking the export exists.

local getpass_script = fs.join(os.getenv("TEST_TMPDIR") as string, "getpass_child.lua")
fs.write(getpass_script, [[
local tty = require("cosmic.tty")
local line, err = tty.getpass("pw: ")
if line == nil then
  io.write("ERR:" .. tostring(err))
else
  io.write("GOT:" .. line)
end
]])
local cosmic_bin = fs.join(os.getenv("TEST_BIN") as string, "cosmic")

local function test_getpass_non_tty_reads_one_line()
  local h = spawn.spawn({cosmic_bin, getpass_script}, {stdin = "sekrit\nsecond\n"})
  assert(h, "getpass child should spawn")
  local r = (h as spawn.Handle):wait() as spawn.Result
  assert(r.ok, "getpass child should exit 0: " .. tostring(r.stderr))
  assert(r.stdout == "GOT:sekrit",
    "getpass should return exactly the first stdin line, got: " .. tostring(r.stdout))
  assert((r.stderr as string):match("^pw: "),
    "the prompt must go to stderr, got: " .. tostring(r.stderr))
end
test_getpass_non_tty_reads_one_line()

local function test_getpass_non_tty_eof()
  local h = spawn.spawn({cosmic_bin, getpass_script}, {stdin = ""})
  assert(h, "getpass child should spawn")
  local r = (h as spawn.Handle):wait() as spawn.Result
  assert(r.ok, "getpass child should exit 0: " .. tostring(r.stderr))
  assert(r.stdout == "ERR:EOF",
    "getpass at stdin EOF should return nil, 'EOF', got: " .. tostring(r.stdout))
end
test_getpass_non_tty_eof()

-- make_raw: pure raw-mode computation, unit-testable without a tty
-- (issue #529, review item 35).

local function fixture_termios(): tty.Termios
  local cc: {integer} = {}
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
  local vmin = tty.VMIN + 1
  local vtime = tty.VTIME + 1
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
  local vmin = tty.VMIN + 1
  local vtime = tty.VTIME + 1
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
