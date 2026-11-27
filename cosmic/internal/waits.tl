--- Internal: how a wait of cosmic.clock reaches the event loop without
--- requiring cosmic.poll, which requires cosmic.clock. cosmic.poll sets
--- these when it loads; before then no task can be running, so a wait
--- blocks the process.

local type Failure = require("cosmic.failure")

local record Waits
  --- Whether the caller is a task of a running loop that can park: not
  --- killed, and not under a C call it cannot yield across.
  mut parks?: function(): boolean
  --- Parks the calling task for `ns` nanoseconds, of any length.
  mut delay?: function(ns: integer): (true) | (nil, Failure)
end

return Waits
