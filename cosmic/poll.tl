--- Typed interface for polling file descriptors.
--- Provides an ergonomic wrapper around unix.poll().
---
--- Descriptor conventions (deliberate): poll is the lowest layer
--- and speaks raw integer fds. net.Socket exposes a public `fd` field
--- (sockets hand their descriptor around by design); fd.Handle exposes
--- :fd() as a method because the Handle owns its descriptor and
--- invalidates it on close — :fd() returns -1 once closed, and a -1
--- must never be registered here.
local unix = require("cosmo.unix")
local errno = require("cosmic.errno")

--- Poll event flags.
--- Use these to specify which events to monitor.
local POLLIN: integer = unix.POLLIN
local POLLOUT: integer = unix.POLLOUT
local POLLPRI: integer = unix.POLLPRI
local POLLERR: integer = unix.POLLERR
local POLLHUP: integer = unix.POLLHUP
local POLLNVAL: integer = unix.POLLNVAL
local POLLRDHUP: integer = unix.POLLRDHUP

--- Resolved events from a poll operation.
local record Events
  --- True if readable data is available.
  readable: boolean
  --- True if writing is possible.
  writable: boolean
  --- True if an error occurred.
  error: boolean
  --- True if the peer closed the connection.
  hangup: boolean
  --- True if the fd is invalid.
  invalid: boolean
  --- Raw revents bitmask from poll.
  revents: integer
end

--- Poll set for monitoring multiple file descriptors.
local record Poller
  --- Add a file descriptor to the set. Fallible instead of throwing:
  --- a nil or negative fd (e.g. an unchecked open, or a closed
  --- fd.Handle's -1) is a caller bug that would otherwise silently
  --- turn every wait into a timeout.
  --- @param fd integer File descriptor number
  --- @param events integer Event mask (POLLIN, POLLOUT, etc.)
  --- @return boolean True when registered
  --- @return string? Error message for a nil or negative fd
  add: function(Poller, integer, integer): boolean, string
  --- Remove a file descriptor from the set.
  --- @param fd integer The file descriptor to remove
  remove: function(Poller, integer)
  --- Clear all file descriptors from the set.
  clear: function(Poller)
  --- Poll for events with optional timeout.
  --- Returns an iterator over (fd, events) pairs for ready descriptors.
  --- EINTR is retried internally by reissuing the same timeoutms, so the
  --- deadline is not preserved across retries: repeated signals can make
  --- the effective wait exceed timeoutms. On a hard poll error the
  --- iterator is empty; check err() after the loop — the old second
  --- return was consumed as loop state by the generic `for`, so no
  --- caller ever saw it (the Rows:err() pattern, for the same reason).
  --- @param timeoutms integer Timeout in ms (-1 for infinite, 0 for non-blocking)
  --- @return function Iterator yielding (fd: integer, events: Events)
  wait: function(Poller, integer): function(): (integer, Events)
  --- The error from the last wait(), or nil when it polled cleanly.
  --- Cleared by the next wait().
  err: function(Poller): string | nil
  --- Poll and return count of ready descriptors. EINTR is retried
  --- internally by reissuing the same timeoutms (the deadline is not
  --- preserved across retries).
  --- @param timeoutms integer Timeout in ms (-1 for infinite, 0 for non-blocking)
  --- @return integer | nil Count of ready descriptors
  --- @return string Error message on failure
  poll: function(Poller, integer): integer | nil, string
  --- Get events for a specific fd after poll().
  --- @param fd integer The file descriptor
  --- @return Events | nil The events for this fd, or nil if not ready
  events: function(Poller, integer): Events | nil
  --- Returns true if the poller has no registered fds.
  empty: function(Poller): boolean
  --- Returns the number of registered fds.
  count: function(Poller): integer
end

--- Make Events from raw revents bitmask.
local function make_events(revents: integer): Events
  return {
    readable = (revents & POLLIN) ~= 0,
    writable = (revents & POLLOUT) ~= 0,
    error = (revents & POLLERR) ~= 0,
    hangup = (revents & POLLHUP) ~= 0,
    invalid = (revents & POLLNVAL) ~= 0,
    revents = revents,
  }
end

--- Create a new poll set.
--- @return Poller A new poll set
--- Example:
---   local p = poll.new()
---   p:add(sock.fd, poll.POLLIN)           -- net.Socket: .fd field
---   p:add(h:fd(), poll.POLLIN)            -- fd.Handle: :fd() method
---   p:add(pipe.reader:fd(), poll.POLLIN)  -- fd.Pipe ends are Handles
---   for fd, events in p:wait(30000) do
---     if events.readable then
---       -- read from fd
---     end
---   end
local function new(): Poller
  local fds: {integer: integer} = {}
  local results: {integer: integer} = {}
  local wait_err: string = nil

  local poller: Poller = {}

  poller.add = function(_self: Poller, fd: integer, events: integer): boolean, string
    if fd == nil then
      -- A nil fd is a caller bug (e.g. an unchecked open); registering
      -- nothing would silently turn every wait into a timeout.
      return false, "poll.add: fd must not be nil"
    end
    if fd < 0 then
      -- A closed fd.Handle reports -1; registering it would poll fd -1
      -- forever-quietly, the same silent-timeout failure as nil.
      return false, "poll.add: fd must be non-negative, got " .. tostring(fd)
    end
    fds[fd] = events
    return true
  end

  poller.remove = function(_self: Poller, fd: integer)
    if fd then
      fds[fd] = nil
      results[fd] = nil
    end
  end

  poller.clear = function(_self: Poller)
    fds = {}
    results = {}
  end

  poller.empty = function(_self: Poller): boolean
    return next(fds) == nil
  end

  poller.count = function(_self: Poller): integer
    local n = 0
    for _ in pairs(fds) do
      n = n + 1
    end
    return n
  end

  poller.poll = function(_self: Poller, timeoutms: integer): integer | nil, string
    -- Retry when a signal interrupts the wait: an unretried EINTR otherwise
    -- surfaces as a poll failure, and a caller that loops on it (e.g. a drain
    -- loop waiting on a child that raised SIGCHLD) spins at 100% CPU.
    -- Retrying reissues the same timeoutms rather than tracking elapsed
    -- time, so the effective wait can exceed timeoutms under repeated
    -- signals (see the doc comment on wait/poll above).
    local res: {integer: integer}
    local err: string
    local eno: integer
    while true do
      res, err, eno = unix.poll(fds, timeoutms or -1)
      if res ~= nil or not errno.is(eno, "EINTR") then
        break
      end
    end
    if not res then
      -- Leave results empty rather than nil: events() indexes results
      -- unconditionally, so a stale or nil table there would crash the
      -- next events() call instead of just reporting no events.
      results = {}
      return nil, errno.str(err, "poll")
    end
    results = res
    local ready = 0
    for _ in pairs(results) do
      ready = ready + 1
    end
    return ready
  end

  poller.events = function(_self: Poller, fd: integer): Events | nil
    local revents = results[fd]
    if revents then
      return make_events(revents)
    end
    return nil
  end

  poller.wait = function(self: Poller, timeoutms: integer): function(): (integer, Events)
    local n, err = self:poll(timeoutms)
    if n == nil then
      wait_err = err
      return function(): (integer, Events)
        return nil, nil
      end
    end
    wait_err = nil
    local iter_results = results
    local k: integer = nil
    return function(): (integer, Events)
      local v: integer
      k, v = next(iter_results, k)
      if k then
        return k, make_events(v)
      end
      return nil, nil
    end
  end

  poller.err = function(_self: Poller): string | nil
    return wait_err
  end

  return poller
end

local record PollModule
  type Poller = Poller
  type Events = Events

  new: function(): Poller

  --- Event mask for readable data.
  POLLIN: integer
  --- Event mask for writable.
  POLLOUT: integer
  --- Event mask for priority data (e.g., OOB on TCP).
  POLLPRI: integer
  --- Event mask for error condition.
  POLLERR: integer
  --- Event mask for hangup.
  POLLHUP: integer
  --- Event mask for invalid fd.
  POLLNVAL: integer
  --- Event mask for peer closed connection.
  POLLRDHUP: integer
end

local M: PollModule = {
  new = new,
  POLLIN = POLLIN,
  POLLOUT = POLLOUT,
  POLLPRI = POLLPRI,
  POLLERR = POLLERR,
  POLLHUP = POLLHUP,
  POLLNVAL = POLLNVAL,
  POLLRDHUP = POLLRDHUP,
}

return M
