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
  local h = check.must(child.start({"sleep", "0.3"}))
  local prev = check.must(signal.sigaction(signal.SIGALRM, function(_: number) end))
  -- Interval timer: fires several times while read blocks on the silent
  -- child, each one interrupting the read.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 50,
        interval_ms = 50,
      }))
  local data, err = h:read()
  -- Disarm and restore before asserting so a failure can't leave a
  -- ticking timer behind.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 0,
        interval_ms = 0,
      }))
  assert(signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask))
  assert(data == nil and err == nil,
    "interrupted read should retry to the child's EOF, got "
    .. tostring(data) .. " (err: " .. tostring(err) .. ")")
  assert(h:wait())
end
test_read_retries_eintr()
