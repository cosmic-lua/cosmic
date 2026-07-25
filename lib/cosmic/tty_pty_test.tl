#!/usr/bin/env cosmic
--- Terminal-mode tests against a REAL terminal (#504).
---
--- tty_test.tl covers the not-a-terminal paths and the module surface;
--- everything that needs an actual tty used to be asserted as
--- `tty.raw ~= nil`, because a CI container has no controlling terminal
--- and there was no way to make one. tty.openpty() (whilp/cosmopolitan#216)
--- supplies one, so the mode changes can now be checked where they
--- actually take effect.
---
--- Two levels of evidence here, and the second is the point:
---   * settings are read back with getattr, so the assertion is that the
---     KERNEL accepted them -- not merely that we computed some bits;
---   * echo is observed end to end, by writing to the manager side and
---     seeing whether the line discipline sends it back. That is what
---     catches flag arithmetic that looks right and does nothing.

local check = require("cosmic.check")
local fd = require("cosmic.fd")
local poll = require("cosmic.poll")
local tty = require("cosmic.tty")

--- Open a pty, or skip the whole file where one cannot be had (no
--- Landlock-free /dev/pts, a sandbox without it, a non-POSIX host).
--- Skipping beats failing: the point is to cover the paths where a
--- terminal EXISTS, not to demand one.
local function with_pty(): tty.Pty
  local pty, err = tty.openpty()
  if not pty then
    check.skip("openpty unavailable: " .. tostring(err))
    return nil
  end
  return pty
end

local function close_pty(pty: tty.Pty)
  fd.wrap(pty.manager):close()
  fd.wrap(pty.subordinate):close()
end

--- The premise every other test rests on: the subordinate really is a
--- terminal. If this ever regressed to a plain pipe the rest would
--- still "pass" while proving nothing.
local function test_openpty_yields_a_real_terminal()
  local pty = with_pty()
  if not pty then return end
  assert(tty.isatty(pty.subordinate),
    "the subordinate fd must be a terminal")
  assert(tty.isatty(pty.manager), "the manager fd must be a terminal")
  assert(pty.name:match("^/dev/"),
    "expected a device path, got: " .. tostring(pty.name))
  local ws = check.must(tty.winsize(pty.subordinate))
  assert(ws.rows ~= nil and ws.cols ~= nil, "winsize should report a size")
  close_pty(pty)
end
test_openpty_yields_a_real_terminal()

--- getattr on a terminal returns settings, and a fresh pty starts in
--- the cooked state -- ECHO and ICANON on. Asserted explicitly because
--- every later test is "these bits get cleared": if they were already
--- clear, those tests would pass without doing anything.
local function test_getattr_on_a_terminal_starts_cooked()
  local pty = with_pty()
  if not pty then return end
  local t = check.must(tty.getattr(pty.subordinate))
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
  if not pty then return end
  local before = check.must(tty.getattr(pty.subordinate))
  local lflag, oflag = before.lflag, before.oflag
  local vmin = before.cc[tty.VMIN + 1]
  local rawt = tty.make_raw(before)
  assert(before.lflag == lflag and before.oflag == oflag,
    "make_raw must not mutate its input")
  assert(before.cc[tty.VMIN + 1] == vmin,
    "make_raw must not mutate the input's cc table")
  assert(rawt.lflag ~= lflag, "the returned attrs should differ")
  close_pty(pty)
end
test_make_raw_is_pure()

--- raw() applied to a real terminal, read back through the kernel.
--- restore() must then put every one of those fields back.
local function test_raw_then_restore_round_trips()
  local pty = with_pty()
  if not pty then return end
  local sfd = pty.subordinate
  local before = check.must(tty.getattr(sfd))

  local original = check.must(tty.raw(sfd))
  local now = check.must(tty.getattr(sfd))
  assert(now.lflag & tty.ECHO == 0, "raw must clear ECHO")
  assert(now.lflag & tty.ICANON == 0, "raw must clear ICANON")
  assert(now.lflag & tty.ISIG == 0, "raw must clear ISIG by default")
  assert(now.oflag & tty.OPOST == 0, "raw must clear OPOST")
  assert(now.cc[tty.VMIN + 1] == 1, "raw must set VMIN=1")
  assert(now.cc[tty.VTIME + 1] == 0, "raw must set VTIME=0")

  assert(tty.restore(sfd, original))
  local after = check.must(tty.getattr(sfd))
  assert(after.lflag == before.lflag, "restore must put lflag back")
  assert(after.oflag == before.oflag, "restore must put oflag back")
  assert(after.cflag == before.cflag, "restore must put cflag back")
  assert(after.cc[tty.VMIN + 1] == before.cc[tty.VMIN + 1],
    "restore must put the cc table back")
  close_pty(pty)
end
test_raw_then_restore_round_trips()

--- keep_signals is the one documented knob on raw(); without a terminal
--- there was no way to tell it did anything.
local function test_raw_keep_signals_leaves_isig()
  local pty = with_pty()
  if not pty then return end
  check.must(tty.raw(pty.subordinate, {keep_signals = true}))
  local now = check.must(tty.getattr(pty.subordinate))
  assert(now.lflag & tty.ISIG ~= 0,
    "keep_signals should leave ISIG set so Ctrl-C still signals")
  assert(now.lflag & tty.ICANON == 0,
    "keep_signals should still leave raw mode otherwise")
  close_pty(pty)
end
test_raw_keep_signals_leaves_isig()

--- noecho is narrower than raw: echo off, line editing untouched.
local function test_noecho_clears_only_echo()
  local pty = with_pty()
  if not pty then return end
  local before = check.must(tty.getattr(pty.subordinate))
  check.must(tty.noecho(pty.subordinate))
  local now = check.must(tty.getattr(pty.subordinate))
  assert(now.lflag & tty.ECHO == 0, "noecho must clear ECHO")
  assert(now.lflag & tty.ICANON ~= 0,
    "noecho must leave canonical mode alone -- that is raw()'s job")
  assert(now.lflag & tty.ISIG == before.lflag & tty.ISIG,
    "noecho must not touch signal generation")
  close_pty(pty)
end
test_noecho_clears_only_echo()

--- Is the byte we wrote to the manager echoed back by the terminal?
--- A short poll timeout, so "no echo" cannot hang the suite.
local function echo_observed(pty: tty.Pty): boolean
  local mgr = fd.wrap(pty.manager)
  assert(mgr:write("x"))
  local set = poll.new()
  set:add(pty.manager, poll.POLLIN)
  local n = set:poll(300)
  if n and n > 0 then
    mgr:read(64)
    return true
  end
  return false
end

--- The assertion that actually matters, and the one #504 was after:
--- echo stops HAPPENING, not merely a bit changes. Flag arithmetic that
--- clears the wrong bit, or writes attrs the kernel quietly rejects,
--- passes every check above and fails this one.
local function test_noecho_actually_stops_echo()
  local pty = with_pty()
  if not pty then return end
  assert(echo_observed(pty),
    "a cooked terminal should echo what is written to it -- if this "
    .. "fails the test below proves nothing")
  check.must(tty.noecho(pty.subordinate))
  assert(not echo_observed(pty),
    "after noecho the terminal must not echo")
  close_pty(pty)
end
test_noecho_actually_stops_echo()

--- Same observable for raw(), which clears ECHO among much else, and
--- restore() must bring echoing back.
local function test_raw_stops_echo_and_restore_revives_it()
  local pty = with_pty()
  if not pty then return end
  local original = check.must(tty.raw(pty.subordinate))
  assert(not echo_observed(pty), "a raw terminal must not echo")
  assert(tty.restore(pty.subordinate, original))
  assert(echo_observed(pty), "restore must bring echoing back")
  close_pty(pty)
end
test_raw_stops_echo_and_restore_revives_it()
