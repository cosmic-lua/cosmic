#!/usr/bin/env cosmic
--- Terminal-mode tests against a REAL terminal.
---
--- tty_test.tl covers the not-a-terminal paths and the module surface.
--- This file covers what needs a real tty: a CI container has no
--- controlling terminal, so tty.open_pty() supplies one and the mode
--- changes are checked where they actually take effect, rather than
--- asserted as `tty.raw ~= nil`.
---
--- Two levels of evidence here, and the second is the point:
---   * settings are read back with attributes, so the assertion is that the
---     KERNEL accepted them -- not merely that we computed some bits;
---   * echo is observed end to end, by writing to the manager side and
---     seeing whether the line discipline sends it back. That is what
---     catches flag arithmetic that looks right and does nothing.

local check = require("cosmic.check")
local fd = require("cosmic.fd")
local fs = require("cosmic.fs")
local poll = require("cosmic.poll")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local time = require("cosmic.time")
local tty = require("cosmic.tty")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

--- Open a pty, or exit the whole file where one cannot be had (no
--- Landlock-free /dev/pts, a sandbox without it, a non-POSIX host).
--- Skipping beats failing: the point is to cover the paths where a
--- terminal EXISTS, not to demand one -- but skipping means EXITING with
--- `check.EXIT_SKIP`, not returning nil for each test to shrug off. A
--- `return` at file scope ends the chunk with status 0, which
--- `records.status_of` grades as PASS, so a host without /dev/pts would
--- make this whole suite report green while testing nothing. Same
--- discipline `check.needs` documents and every other gated precondition
--- in this repo uses (see e.g. `_make/build_test.tl`).
local function with_pty(): tty.Pty
  local pty, err = tty.open_pty()
  if not pty then
    check.needs("a real pty (tty.open_pty failed: " .. tostring(err) .. ")", false)
    return nil
  end
  return pty
end

local function close_pty(pty: tty.Pty)
  assert(fd.wrap(pty.manager):close())
  assert(fd.wrap(pty.subordinate):close())
end

--- The premise every other test rests on: the subordinate really is a
--- terminal. If this ever regressed to a plain pipe the rest would
--- still "pass" while proving nothing.
local function test_openpty_yields_a_real_terminal()
  local pty = with_pty()
  assert(tty.is_tty(pty.subordinate),
    "the subordinate fd must be a terminal")
  assert(tty.is_tty(pty.manager), "the manager fd must be a terminal")
  assert(pty.name:match("^/dev/"),
    "expected a device path, got: " .. tostring(pty.name))
  local ws = check.must(tty.window_size(pty.subordinate))
  assert(ws.rows ~= nil and ws.cols ~= nil, "window_size should report a size")
  close_pty(pty)
end
test_openpty_yields_a_real_terminal()

--- attributes on a terminal returns settings, and a fresh pty starts in
--- the cooked state -- ECHO and ICANON on. Asserted explicitly because
--- every later test is "these bits get cleared": if they were already
--- clear, those tests would pass without doing anything.
local function test_getattr_on_a_terminal_starts_cooked()
  local pty = with_pty()
  local t = check.must(tty.attributes(pty.subordinate))
  assert(t.lflag & tty.ECHO ~= 0, "a fresh pty should start with ECHO on")
  assert(t.lflag & tty.ICANON ~= 0, "a fresh pty should start canonical")
  close_pty(pty)
end
test_getattr_on_a_terminal_starts_cooked()

--- make_raw is documented as pure. Verified against a real Termios
--- rather than a hand-built one, since the input is the shape the
--- kernel actually hands back.
local function test_make_raw_is_pure()
  local pty = with_pty()
  local before = check.must(tty.attributes(pty.subordinate))
  local lflag, oflag = before.lflag, before.oflag
  local vmin = before.cc[tty.VMIN]
  local rawt = tty.make_raw(before)
  assert(before.lflag == lflag and before.oflag == oflag,
    "make_raw must not mutate its input")
  assert(before.cc[tty.VMIN] == vmin,
    "make_raw must not mutate the input's cc table")
  assert(rawt.lflag ~= lflag, "the returned attrs should differ")
  close_pty(pty)
end
test_make_raw_is_pure()

--- raw() applied to a real terminal, read back through the kernel.
--- restore() must then put every one of those fields back.
local function test_raw_then_restore_round_trips()
  local pty = with_pty()
  local sfd = pty.subordinate
  local before = check.must(tty.attributes(sfd))

  local original = check.must(tty.raw(sfd))
  local now = check.must(tty.attributes(sfd))
  assert(now.lflag & tty.ECHO == 0, "raw must clear ECHO")
  assert(now.lflag & tty.ICANON == 0, "raw must clear ICANON")
  assert(now.lflag & tty.ISIG == 0, "raw must clear ISIG by default")
  assert(now.oflag & tty.OPOST == 0, "raw must clear OPOST")
  assert(now.cc[tty.VMIN] == 1, "raw must set VMIN=1")
  assert(now.cc[tty.VTIME] == 0, "raw must set VTIME=0")

  assert(tty.restore(sfd, original))
  local after = check.must(tty.attributes(sfd))
  assert(after.lflag == before.lflag, "restore must put lflag back")
  assert(after.oflag == before.oflag, "restore must put oflag back")
  assert(after.cflag == before.cflag, "restore must put cflag back")
  assert(after.cc[tty.VMIN] == before.cc[tty.VMIN],
    "restore must put the cc table back")
  close_pty(pty)
end
test_raw_then_restore_round_trips()

--- keep_signals is the one documented knob on raw(); without a terminal
--- there was no way to tell it did anything.
local function test_raw_keep_signals_leaves_isig()
  local pty = with_pty()
  check.must(tty.raw(pty.subordinate, {keep_signals = true}))
  local now = check.must(tty.attributes(pty.subordinate))
  assert(now.lflag & tty.ISIG ~= 0,
    "keep_signals should leave ISIG set so Ctrl-C still signals")
  assert(now.lflag & tty.ICANON == 0,
    "keep_signals should still leave raw mode otherwise")
  close_pty(pty)
end
test_raw_keep_signals_leaves_isig()

--- disable_echo is narrower than raw: echo off, line editing untouched.
local function test_noecho_clears_only_echo()
  local pty = with_pty()
  local before = check.must(tty.attributes(pty.subordinate))
  check.must(tty.disable_echo(pty.subordinate))
  local now = check.must(tty.attributes(pty.subordinate))
  assert(now.lflag & tty.ECHO == 0, "disable_echo must clear ECHO")
  assert(now.lflag & tty.ICANON ~= 0,
    "disable_echo must leave canonical mode alone -- that is raw()'s job")
  assert(now.lflag & tty.ISIG == before.lflag & tty.ISIG,
    "disable_echo must not touch signal generation")
  close_pty(pty)
end
test_noecho_clears_only_echo()

--- Is the byte we wrote to the manager echoed back by the terminal?
--- A short poll timeout, so "no echo" cannot hang the suite.
local function echo_observed(pty: tty.Pty): boolean
  local mgr = fd.wrap(pty.manager)
  assert(mgr:write("x"))
  local set = poll.new()
  assert(set:add(pty.manager, poll.POLLIN))
  local ready = set:wait(300)
  if ready and next(ready) ~= nil then
    assert(mgr:read(64))
    return true
  end
  return false
end

--- The assertion that actually matters, and the one was after:
--- echo stops HAPPENING, not merely a bit changes. Flag arithmetic that
--- clears the wrong bit, or writes attrs the kernel quietly rejects,
--- passes every check above and fails this one.
local function test_noecho_actually_stops_echo()
  local pty = with_pty()
  assert(echo_observed(pty),
    "a cooked terminal should echo what is written to it -- if this "
    .. "fails the test below proves nothing")
  check.must(tty.disable_echo(pty.subordinate))
  assert(not echo_observed(pty),
    "after disable_echo the terminal must not echo")
  close_pty(pty)
end
test_noecho_actually_stops_echo()

--- Same observable for raw(), which clears ECHO among much else, and
--- restore() must bring echoing back.
local function test_raw_stops_echo_and_restore_revives_it()
  local pty = with_pty()
  local original = check.must(tty.raw(pty.subordinate))
  assert(not echo_observed(pty), "a raw terminal must not echo")
  assert(tty.restore(pty.subordinate, original))
  assert(echo_observed(pty), "restore must bring echoing back")
  close_pty(pty)
end
test_raw_stops_echo_and_restore_revives_it()

-- read_password, the last path listed. It reads fd 0 specifically and
-- only suppresses echo when fd 0 is a terminal, so covering it needs a
-- process whose stdin IS a pty -- login_tty in a forked child, which
-- replaces that child's session. Hence the fork: it must not happen in
-- the test process.
--
-- The child reports through a file rather than stdout, because after
-- login_tty its stdout IS the terminal under observation; mixing the
-- two would make "what did the terminal echo?" unanswerable.

--- Wait until read_password has actually turned echo off.
---
--- read_password writes its prompt BEFORE calling disable_echo, so a parent that
--- writes as soon as it sees the prompt can have its input echoed by a
--- still-cooked terminal. That is a race, and it would show up as a
--- flaky failure rather than a wrong answer. The ECHO bit is the real
--- readiness signal, and the parent's copy of the subordinate fd
--- reports the same terminal state the child is changing.
local function await_echo_off(pty: tty.Pty): boolean
  for _ = 1, 500 do
    local t = tty.attributes(pty.subordinate)
    if t is tty.Termios and t.lflag & tty.ECHO == 0 then
      return true
    end
    assert(time.sleep_ms(10))
  end
  return false
end

local function test_getpass_reads_without_echoing()
  local pty = with_pty()
  local result = fs.join(TEST_TMPDIR, "read_password.out")

  local pid = proc.fork()
  if pid == 0 then
    -- Child: adopt the pty as our controlling terminal, so fd 0 is a
    -- tty and read_password takes the echo-suppressing branch.
    local ok, lerr = tty.login_tty(pty.subordinate)
    if not ok then
      assert(fs.write(result, "LOGIN_TTY_FAILED:" .. tostring(lerr)))
      os.exit(0)
    end
    local pw, err = tty.read_password("Password: ")
    assert(fs.write(result, pw or ("ERR:" .. tostring(err))))
    os.exit(0)
  end

  local mgr = fd.wrap(pty.manager)
  if not await_echo_off(pty) then
    assert(signal.kill(pid, 9))
    assert(proc.wait(pid))
    close_pty(pty)
    -- Same discipline as `with_pty`: a timed-out race is a SKIP, and a
    -- skip must exit EXIT_SKIP, not `return` and leave the file to exit
    -- 0 (a PASS by `records.status_of`'s reading).
    check.needs("read_password disabling echo before the race timeout", false)
  end
  assert(mgr:write("hunter2\n"))
  assert(proc.wait(pid))

  -- Everything the terminal sent back while the child was reading.
  local seen = ""
  local set = poll.new()
  assert(set:add(pty.manager, poll.POLLIN))
  while true do
    local ready = set:wait(300)
    if not ready or next(ready) == nil then break end
    local chunk = mgr:read(4096)
    if not chunk or #chunk == 0 then break end
    seen = seen .. chunk
  end
  close_pty(pty)

  local got = check.must(fs.read(result))
  assert(got == "hunter2",
    "read_password should return the typed line, got: " .. got)
  assert(seen:find("Password: ", 1, true),
    "read_password should write its prompt to the terminal, saw: " .. seen)
  -- The whole point of read_password: the secret must not come back.
  assert(not seen:find("hunter2", 1, true),
    "read_password must not echo what was typed, but the terminal returned: "
    .. seen)
end
test_getpass_reads_without_echoing()

--- read_password restores the terminal when it is done, so a caller that
--- prompts for a password does not leave the user's terminal mute.
local function test_getpass_restores_echo_afterwards()
  local pty = with_pty()
  local result = fs.join(TEST_TMPDIR, "getpass_restore.out")

  local pid = proc.fork()
  if pid == 0 then
    if not tty.login_tty(pty.subordinate) then os.exit(1) end
    local pw = tty.read_password("pw: ")
    assert(fs.write(result, pw or ""))
    os.exit(0)
  end

  local mgr = fd.wrap(pty.manager)
  if not await_echo_off(pty) then
    assert(signal.kill(pid, 9))
    assert(proc.wait(pid))
    close_pty(pty)
    -- Same discipline as `with_pty`: a timed-out race is a SKIP, and a
    -- skip must exit EXIT_SKIP, not `return` and leave the file to exit
    -- 0 (a PASS by `records.status_of`'s reading).
    check.needs("read_password disabling echo before the race timeout", false)
  end
  assert(mgr:write("secret\n"))
  assert(proc.wait(pid))

  local after = check.must(tty.attributes(pty.subordinate))
  assert(after.lflag & tty.ECHO ~= 0,
    "read_password must restore echo before returning")
  assert(after.lflag & tty.ICANON ~= 0,
    "read_password must leave canonical mode as it found it")
  close_pty(pty)
end
test_getpass_restores_echo_afterwards()
