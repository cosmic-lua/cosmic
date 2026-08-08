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
local time = require("cosmic.time")

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
  --- Wait for events, up to timeout_ms. Returns the ready set as a
  --- {fd: Events} map — an empty map on timeout, `nil, err` on a hard
  --- poll failure — so `for fd, ev in pairs(ready) do` iterates it and
  --- the error arrives in slot 2 the house way (the old iterator ate
  --- it as loop state, patched by a stateful err() sidecar; both are
  --- gone). EINTR is retried against an absolute deadline, so repeated
  --- signals can no longer stretch the wait past timeout_ms.
  --- @param timeout_ms integer? Timeout in ms; nil blocks forever, 0 polls
  --- @return {integer: Events} | nil Ready set (empty on timeout)
  --- @return string? Error message on failure
  wait: function(Poller, timeout_ms?: integer): {integer: Events} | nil, string
  --- Returns true if the poller has no registered fds.
  is_empty: function(Poller): boolean
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
---   local ready = assert(p:wait(30000))
---   for fd, events in pairs(ready) do
---     if events.readable then
---       -- read from fd
---     end
---   end
local function new(): Poller
  local fds: {integer: integer} = {}

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
    end
  end

  poller.clear = function(_self: Poller)
    fds = {}
  end

  poller.is_empty = function(_self: Poller): boolean
    return next(fds) == nil
  end

  poller.wait = function(_self: Poller, timeout_ms?: integer): {integer: Events} | nil, string
    -- Retry when a signal interrupts the wait: an unretried EINTR otherwise
    -- surfaces as a poll failure, and a caller that loops on it (e.g. a drain
    -- loop waiting on a child that raised SIGCHLD) spins at 100% CPU. The
    -- retry reissues the REMAINDER of an absolute deadline, not the full
    -- timeout, so repeated signals cannot stretch the wait (the posture
    -- child.io and shm already took).
    local deadline_ms: integer = nil
    if timeout_ms and timeout_ms >= 0 then
      deadline_ms = time.monotonic_ms() + timeout_ms
    end
    local res: {integer: integer}
    local err: string
    local eno: integer
    while true do
      local wait_ms = -1
      if deadline_ms then
        wait_ms = math.max(0, deadline_ms - time.monotonic_ms())
      end
      res, err, eno = unix.poll(fds, wait_ms)
      if res ~= nil or not errno.is_code(eno, "EINTR") then
        break
      end
    end
    if not res then
      return nil, errno.format(err, "poll")
    end
    local ready: {integer: Events} = {}
    for fd, revents in pairs(res) do
      ready[fd] = make_events(revents)
    end
    return ready
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
