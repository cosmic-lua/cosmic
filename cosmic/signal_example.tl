--- Examples for the cosmic.signal module.
--- Demonstrates installing a Lua signal handler and controlling
--- delivery with signal masks, and sending signals to processes.

-- Example_handler demonstrates the block/install/raise/unblock
-- pattern: blocking SIGUSR1 first makes delivery deterministic — the
-- signal stays pending until the mask is restored, and the handler
-- runs before the sleep returns.
local function Example_handler()
  local signal = require("cosmic.signal")
  local time = require("cosmic.time")

  local received: number = 0
  local blockmask = signal.sigset(signal.SIGUSR1)
  local oldmask = signal.sigprocmask(signal.SIG_BLOCK, blockmask)

  local old_handler = signal.sigaction(signal.SIGUSR1, function(sig: number)
      received = sig
    end)

  signal.raise(signal.SIGUSR1) -- pending: SIGUSR1 is blocked
  signal.sigprocmask(signal.SIG_SETMASK, oldmask)
  time.sleep(0, 1000000) -- give delivery a moment

  print(received == signal.SIGUSR1)
  signal.sigaction(signal.SIGUSR1, old_handler)
  -- Output:
  -- true
end

-- Example_ignore demonstrates SIG_IGN: with the disposition set to
-- ignore, raise() delivers nothing and the process carries on.
local function Example_ignore()
  local signal = require("cosmic.signal")
  local old_handler = signal.sigaction(signal.SIGUSR2, signal.SIG_IGN)
  local ok = signal.raise(signal.SIGUSR2)
  print(ok)
  signal.sigaction(signal.SIGUSR2, old_handler)
  -- Output:
  -- true
end

-- Example_sigset demonstrates Sigset membership: the constructor
-- seeds the set and add/remove/contains manage it.
local function Example_sigset()
  local signal = require("cosmic.signal")
  local set = signal.sigset(signal.SIGINT)
  print(set:contains(signal.SIGINT), set:contains(signal.SIGTERM))
  set:add(signal.SIGTERM)
  set:remove(signal.SIGINT)
  print(set:contains(signal.SIGINT), set:contains(signal.SIGTERM))
  -- Output:
  -- true	false
  -- false	true
end

-- Suppress unused warnings for examples
local _ = {Example_handler, Example_ignore, Example_sigset}
