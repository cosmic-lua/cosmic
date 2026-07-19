--- Typed interface for polling file descriptors.
--- Provides an ergonomic wrapper around unix.poll().
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
  --- Add a file descriptor to the set.
  --- @param fd integer File descriptor number
  --- @param events integer Event mask (POLLIN, POLLOUT, etc.)
  add: function(Poller, integer, integer)
  --- Remove a file descriptor from the set.
  --- @param fd integer The file descriptor to remove
  remove: function(Poller, integer)
  --- Clear all file descriptors from the set.
  clear: function(Poller)
  --- Poll for events with optional timeout.
  --- Returns an iterator over (fd, events) pairs for ready descriptors.
  --- EINTR is retried internally. On a hard poll error the iterator is
  --- empty and the error string is returned as the second value.
  --- @param timeoutms integer Timeout in ms (-1 for infinite, 0 for non-blocking)
  --- @return function Iterator yielding (fd: integer, events: Events)
  --- @return string? Error message when the underlying poll failed
  wait: function(Poller, integer): function(): (integer, Events), string
  --- Poll and return count of ready descriptors.
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
---   p:add(handle.stdout.fd, poll.POLLIN)  -- child.Pipe: use .fd field
---   p:add(reader:fd(), poll.POLLIN)       -- io.Handle: call :fd() method
---   p:add(sock.fd, poll.POLLIN)           -- net.Socket: use .fd field
---   for fd, events in p:wait(30000) do
---     if events.readable then
---       -- read from fd
---     end
---   end
local function new(): Poller
  local fds: {integer: integer} = {}
  local results: {integer: integer} = {}

  local poller: Poller = {}

  poller.add = function(_self: Poller, fd: integer, events: integer)
    if fd == nil then
      -- A nil fd is a caller bug (e.g. an unchecked open); registering
      -- nothing would silently turn every wait into a timeout.
      error("poll.add: fd must not be nil", 2)
    end
    fds[fd] = events
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
    local res: {integer: integer}
    local err: string
    local eno: integer
    while true do
      res, err, eno = unix.poll(fds, timeoutms or -1)
      if res ~= nil or not errno.is(eno, "EINTR") then
        break
      end
    end
    results = res
    if not results then
      return nil, errno.str(err, "poll")
    end
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

  poller.wait = function(self: Poller, timeoutms: integer): function(): (integer, Events), string
    local n, err = self:poll(timeoutms)
    if n == nil then
      return function(): (integer, Events)
        return nil, nil
      end, err
    end
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
