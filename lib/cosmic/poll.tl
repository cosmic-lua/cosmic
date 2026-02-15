--- Typed interface for polling file descriptors.
--- Provides an ergonomic wrapper around unix.poll().
local unix = require("cosmo.unix")

--- Poll event flags.
--- Use these to specify which events to monitor.
local POLLIN: number = unix.POLLIN
local POLLOUT: number = unix.POLLOUT
local POLLPRI: number = unix.POLLPRI
local POLLERR: number = unix.POLLERR
local POLLHUP: number = unix.POLLHUP
local POLLNVAL: number = unix.POLLNVAL
local POLLRDHUP: number = unix.POLLRDHUP

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
  revents: number
end

--- Poll set for monitoring multiple file descriptors.
local record Poller
  --- Add a file descriptor or handle to the set.
  --- Accepts raw fd numbers, or objects with .fd field or :fd() method.
  --- @param p any File descriptor number, io.Handle, child.Pipe, or net.Socket
  --- @param events number Event mask (POLLIN, POLLOUT, etc.)
  add: function(Poller, any, number)
  --- Remove a file descriptor or handle from the set.
  --- @param p any The fd or handle to remove
  remove: function(Poller, any)
  --- Clear all file descriptors from the set.
  clear: function(Poller)
  --- Poll for events with optional timeout.
  --- Returns an iterator over (fd, events) pairs for ready descriptors.
  --- @param timeoutms number Timeout in ms (-1 for infinite, 0 for non-blocking)
  --- @return function Iterator yielding (fd: number, events: Events)
  wait: function(Poller, number): function(): number, Events
  --- Poll and return count of ready descriptors.
  --- @param timeoutms number Timeout in ms (-1 for infinite, 0 for non-blocking)
  --- @return number Count of ready descriptors
  --- @return string Error message on failure
  poll: function(Poller, number): number, string
  --- Get events for a specific fd after poll().
  --- @param fd number The file descriptor
  --- @return Events The events for this fd, or nil if not ready
  events: function(Poller, number): Events
  --- Returns true if the poller has no registered fds.
  empty: function(Poller): boolean
  --- Returns the number of registered fds.
  count: function(Poller): number
end

--- Extract a file descriptor number from a pollable object.
--- Supports: raw fd numbers, objects with .fd field, objects with :fd() method.
local function get_fd(p: any): number
  if type(p) == "number" then
    return p as number
  elseif type(p) == "table" then
    local t = p as {any: any}
    local fd_val = t.fd
    if type(fd_val) == "number" then
      return fd_val as number
    elseif type(fd_val) == "function" then
      return (fd_val as function(any): number)(p)
      end
    end
    return nil
  end

  --- Make Events from raw revents bitmask.
  local function make_events(revents: number): Events
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
  ---   p:add(handle.stdout, poll.POLLIN)
  ---   p:add(handle.stderr, poll.POLLIN)
  ---   for fd, events in p:wait(30000) do
  ---     if events.readable then
  ---       -- read from fd
  ---     end
  ---   end
  local function new(): Poller
    local fds: {number: number} = {}
    local results: {number: number} = {}

    local poller: Poller = {}

    poller.add = function(self: Poller, p: any, events: number)
      local fd = get_fd(p)
      if fd then
        fds[fd] = events
      end
    end

    poller.remove = function(self: Poller, p: any)
      local fd = get_fd(p)
      if fd then
        fds[fd] = nil
        results[fd] = nil
      end
    end

    poller.clear = function(self: Poller)
      fds = {}
      results = {}
    end

    poller.empty = function(self: Poller): boolean
      return next(fds) == nil
    end

    poller.count = function(self: Poller): number
      local n = 0
      for _ in pairs(fds) do
        n = n + 1
      end
      return n
    end

    poller.poll = function(self: Poller, timeoutms: number): number, string
      results = unix.poll(fds, timeoutms or -1)
      if not results then
        return nil, "poll failed"
      end
      local ready = 0
      for _ in pairs(results) do
        ready = ready + 1
      end
      return ready
    end

    poller.events = function(self: Poller, fd: number): Events
      local revents = results[fd]
      if revents then
        return make_events(revents)
      end
      return nil
    end

    poller.wait = function(self: Poller, timeoutms: number): function(): number, Events
      local _, err = self:poll(timeoutms)
      if err then
        return function(): number, Events
          return nil, nil
        end
      end
      local iter_results = results
      local k: number = nil
      return function(): number, Events
        local v: number
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
    new: function(): Poller

    --- Event mask for readable data.
    POLLIN: number
    --- Event mask for writable.
    POLLOUT: number
    --- Event mask for priority data (e.g., OOB on TCP).
    POLLPRI: number
    --- Event mask for error condition.
    POLLERR: number
    --- Event mask for hangup.
    POLLHUP: number
    --- Event mask for invalid fd.
    POLLNVAL: number
    --- Event mask for peer closed connection.
    POLLRDHUP: number
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
