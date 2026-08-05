#!/usr/bin/env cosmic
local signal = require("cosmic.signal")
local check = require("cosmic.check")
local proc = require("cosmic.proc")
local time = require("cosmic.time")

local function test_strsignal()
  assert(signal.strsignal(signal.SIGKILL) == "SIGKILL", "expected SIGKILL")
  assert(signal.strsignal(signal.SIGTERM) == "SIGTERM", "expected SIGTERM")
  assert(signal.strsignal(signal.SIGINT) == "SIGINT", "expected SIGINT")
  assert(signal.strsignal(9) == "SIGKILL", "expected SIGKILL for signal 9")
end
test_strsignal()

local function test_signal_constants()
  -- Verify key signal constants are defined and have expected values
  assert(signal.SIGKILL == 9, "SIGKILL should be 9")
  assert(signal.SIGTERM == 15, "SIGTERM should be 15")
  assert(signal.SIGINT == 2, "SIGINT should be 2")
  assert(signal.SIGHUP == 1, "SIGHUP should be 1")

  -- Verify signal mask constants
  assert(signal.SIG_BLOCK ~= nil, "SIG_BLOCK should be defined")
  assert(signal.SIG_UNBLOCK ~= nil, "SIG_UNBLOCK should be defined")
  assert(signal.SIG_SETMASK ~= nil, "SIG_SETMASK should be defined")

  -- Verify handler constants
  assert(signal.SIG_DFL ~= nil, "SIG_DFL should be defined")
  assert(signal.SIG_IGN ~= nil, "SIG_IGN should be defined")

  -- Verify sigaction flags
  assert(signal.SA_RESTART ~= nil, "SA_RESTART should be defined")
  assert(signal.SA_RESETHAND ~= nil, "SA_RESETHAND should be defined")

  -- Verify timer constants
  assert(signal.ITIMER_REAL ~= nil, "ITIMER_REAL should be defined")
end
test_signal_constants()

local function test_sigset()
  -- Test Sigset constructor
  local set = signal.sigset(signal.SIGTERM, signal.SIGINT)
  assert(set:contains(signal.SIGTERM), "set should contain SIGTERM")
  assert(set:contains(signal.SIGINT), "set should contain SIGINT")
  assert(not set:contains(signal.SIGHUP), "set should not contain SIGHUP")

  -- Test Sigset with single signal
  local set2 = signal.sigset(signal.SIGUSR1)
  assert(set2:contains(signal.SIGUSR1), "set2 should contain SIGUSR1")

  -- Test add/remove
  set:add(signal.SIGHUP)
  assert(set:contains(signal.SIGHUP), "set should now contain SIGHUP")
  set:remove(signal.SIGHUP)
  assert(not set:contains(signal.SIGHUP), "set should no longer contain SIGHUP")

  -- Test clear/fill
  set:clear()
  assert(not set:contains(signal.SIGTERM), "set should be empty after clear")
  set:fill()
  assert(set:contains(signal.SIGTERM), "set should contain all signals after fill")
end
test_sigset()

local function test_sigprocmask()
  -- Block SIGUSR1, then verify we can unblock it
  local mask = signal.sigset(signal.SIGUSR1)
  local oldmask = signal.sigprocmask(signal.SIG_BLOCK, mask)
  assert(oldmask ~= nil, "sigprocmask should return old mask")

  -- Restore old mask
  signal.sigprocmask(signal.SIG_SETMASK, oldmask)
end
test_sigprocmask()

local function test_sigaction_ignore()
  -- Set up SIGUSR1 to be ignored
  local prev = check.must(signal.sigaction(signal.SIGUSR1, signal.SIG_IGN))

  -- Raise SIGUSR1 - should not terminate since it's ignored
  local ok, err = signal.raise(signal.SIGUSR1)
  assert(ok, "raise should succeed: " .. (err or ""))

  -- Restore old handler
  signal.sigaction(signal.SIGUSR1, prev.handler, prev.flags, prev.mask)
end
test_sigaction_ignore()

local function test_sigaction_handler()
  -- Test that we can install a Lua function as a signal handler
  local received_signal: number = 0

  -- Block SIGUSR1 first so we can control when it's delivered
  local blockmask = signal.sigset(signal.SIGUSR1)
  local oldmask = signal.sigprocmask(signal.SIG_BLOCK, blockmask)

  -- Install handler
  local on_sig = function(sig: number)
    received_signal = sig
  end
  local prev = check.must(signal.sigaction(signal.SIGUSR1, on_sig))

  -- Raise the signal (it will be pending since blocked)
  signal.raise(signal.SIGUSR1)

  -- Unblock to deliver the signal
  signal.sigprocmask(signal.SIG_SETMASK, oldmask)

  -- Allow time for signal delivery
  time.sleep(0, 1000000) -- 1ms

  assert(received_signal == signal.SIGUSR1,
    "handler should have received SIGUSR1, got " .. tostring(received_signal))

  -- Restore old handler
  signal.sigaction(signal.SIGUSR1, prev.handler, prev.flags, prev.mask)
end
test_sigaction_handler()

local function test_kill()
  -- Test kill by sending signal 0 (which just checks permissions)
  local pid = proc.getpid()
  local ok = signal.kill(pid, 0)
  assert(ok, "kill with signal 0 should succeed for own process")
end
test_kill()

local function test_raise()
  -- Set up handler for SIGUSR2
  local received = false
  local on_sig = function(_: number)
    received = true
  end
  local prev = check.must(signal.sigaction(signal.SIGUSR2, on_sig))

  signal.raise(signal.SIGUSR2)

  -- Small delay to ensure signal is delivered
  time.sleep(0, 1000000) -- 1ms

  assert(received, "should have received SIGUSR2")

  -- Restore old handler
  signal.sigaction(signal.SIGUSR2, prev.handler, prev.flags, prev.mask)
end
test_raise()

local function test_setitimer()
  -- Test that setitimer with opts record fires SIGALRM
  local received = false

  -- Block SIGALRM so we control delivery
  local blockmask = signal.sigset(signal.SIGALRM)
  local oldmask = signal.sigprocmask(signal.SIG_BLOCK, blockmask)

  -- Install handler
  local on_sig = function(_: number)
    received = true
  end
  local prev = check.must(signal.sigaction(signal.SIGALRM, on_sig))

  -- Set single-shot timer: fire in 100ms, no repeat
  signal.setitimer({
      which = signal.ITIMER_REAL,
      valuesec = 0,
      valuens = 100000000,
      intervalsec = 0,
      intervalns = 0,
    })

  -- Unblock SIGALRM to allow delivery
  signal.sigprocmask(signal.SIG_SETMASK, oldmask)

  -- Wait 200ms for signal delivery
  time.sleep(0, 200000000)

  assert(received, "SIGALRM handler should have been called")

  -- Disarm timer and restore old handler
  signal.setitimer({
      which = signal.ITIMER_REAL,
      valuesec = 0,
      valuens = 0,
      intervalsec = 0,
      intervalns = 0,
    })
  signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask)
end
test_setitimer()

-- Error fidelity: failures surface the binding's errno
-- string instead of being fabricated or discarded.

local function test_raise_error_names_errno()
  local ok, err = signal.raise(999999)
  assert(ok == false, "raise of invalid signal should fail")
  assert(type(err) == "string" and err:match("EINVAL"),
    "raise error should name EINVAL, got: " .. tostring(err))
end
test_raise_error_names_errno()

local function test_setitimer_error_names_errno()
  local result, err = signal.setitimer({
      which = 999999,
      valuesec = 0,
      valuens = 0,
      intervalsec = 0,
      intervalns = 0,
    })
  assert(result == nil, "setitimer with bad which should return nil")
  assert(type(err) == "string" and err:match("EINVAL"),
    "setitimer error should name EINVAL, got: " .. tostring(err))
end
test_setitimer_error_names_errno()

local function test_sigprocmask_error_names_errno()
  local mask = signal.sigset(signal.SIGUSR1)
  local old, err = signal.sigprocmask(999999, mask)
  assert(old == nil, "sigprocmask with bad how should return nil")
  assert(type(err) == "string" and err:match("EINVAL"),
    "sigprocmask error should name EINVAL, got: " .. tostring(err))
end
test_sigprocmask_error_names_errno()

local function test_sigsuspend_returns_eintr()
  -- sigsuspend never succeeds: it returns nil plus EINTR once a signal
  -- is delivered. Arm a short one-shot timer to provide that signal.
  local prev = check.must(signal.sigaction(signal.SIGALRM, function(_: number) end))
  signal.setitimer({
      which = signal.ITIMER_REAL,
      valuesec = 0,
      valuens = 50000000,
      intervalsec = 0,
      intervalns = 0,
    })
  local mask = signal.sigset(signal.SIGUSR2)
  local _, err = signal.sigsuspend(mask)
  assert(type(err) == "string" and err:match("EINTR"),
    "sigsuspend should return an EINTR error, got: " .. tostring(err))
  signal.setitimer({
      which = signal.ITIMER_REAL,
      valuesec = 0,
      valuens = 0,
      intervalsec = 0,
      intervalns = 0,
    })
  signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask)
end
test_sigsuspend_returns_eintr()
