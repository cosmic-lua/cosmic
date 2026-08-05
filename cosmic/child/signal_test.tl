#!/usr/bin/env cosmic
--- Tests for the signal-safety wave: blocking child I/O interrupted
--- by a signal is retried automatically instead of surfacing EINTR.
local check = require("cosmic.check")
local child = require("cosmic.child")
local signal = require("cosmic.signal")

-- A blocking streaming read on the child's stdout is retried when a
-- signal interrupts it, so it returns bare nil at the child's EOF
-- instead of surfacing EINTR mid-wait.
local function test_read_retries_eintr()
  local h = check.must(child.spawn({"sleep", "0.3"}))
  local prev = check.must(signal.sigaction(signal.SIGALRM, function(_: number) end))
  -- Interval timer: fires several times while read blocks on the silent
  -- child, each one interrupting the read.
  signal.setitimer({
      which = signal.ITIMER_REAL,
      valuesec = 0,
      valuens = 50000000,
      intervalsec = 0,
      intervalns = 50000000,
    })
  local data, err = h:read()
  -- Disarm and restore before asserting so a failure can't leave a
  -- ticking timer behind.
  signal.setitimer({
      which = signal.ITIMER_REAL,
      valuesec = 0,
      valuens = 0,
      intervalsec = 0,
      intervalns = 0,
    })
  signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask)
  assert(data == nil and err == nil,
    "interrupted read should retry to the child's EOF, got "
    .. tostring(data) .. " (err: " .. tostring(err) .. ")")
  assert(h:wait())
end
test_read_retries_eintr()
