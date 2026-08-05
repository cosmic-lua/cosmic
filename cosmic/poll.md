# poll

 Typed interface for polling file descriptors.
 Provides an ergonomic wrapper around unix.poll().

 Descriptor conventions (deliberate): poll is the lowest layer
 and speaks raw integer fds. net.Socket exposes a public `fd` field
 (sockets hand their descriptor around by design); fd.Handle exposes
 :fd() as a method because the Handle owns its descriptor and
 invalidates it on close — :fd() returns -1 once closed, and a -1
 must never be registered here.

## Types

### Events

 Resolved events from a poll operation.

```teal
local record Events
  --  True if readable data is available.
  readable: boolean
  --  True if writing is possible.
  writable: boolean
  --  True if an error occurred.
  error: boolean
  --  True if the peer closed the connection.
  hangup: boolean
  --  True if the fd is invalid.
  invalid: boolean
  --  Raw revents bitmask from poll.
  revents: integer
end
```

### Poller

 Poll set for monitoring multiple file descriptors.

```teal
local record Poller
  --  Add a file descriptor to the set. Fallible instead of throwing:
  --  a nil or negative fd (e.g. an unchecked open, or a closed
  --  fd.Handle's -1) is a caller bug that would otherwise silently
  --  turn every wait into a timeout.
  add: function(Poller, integer, integer): boolean, string
  --  Remove a file descriptor from the set.
  remove: function(Poller, integer)
  --  Clear all file descriptors from the set.
  clear: function(Poller)
  --  Poll for events with optional timeout.
  --  Returns an iterator over (fd, events) pairs for ready descriptors.
  --  EINTR is retried internally by reissuing the same timeout_ms, so the
  --  deadline is not preserved across retries: repeated signals can make
  --  the effective wait exceed timeout_ms. On a hard poll error the
  --  iterator is empty; check err() after the loop — the old second
  --  return was consumed as loop state by the generic `for`, so no
  --  caller ever saw it (the Rows:err() pattern, for the same reason).
  wait: function(Poller, integer): function(): (integer, Events)
  --  The error from the last wait(), or nil when it polled cleanly.
  --  Cleared by the next wait().
  err: function(Poller): string | nil
  --  Poll and return count of ready descriptors. EINTR is retried
  --  internally by reissuing the same timeout_ms (the deadline is not
  --  preserved across retries).
  poll: function(Poller, integer): integer | nil, string
  --  Get events for a specific fd after poll().
  events: function(Poller, integer): Events | nil
  --  Returns true if the poller has no registered fds.
  is_empty: function(Poller): boolean
  --  Returns the number of registered fds.
  count: function(Poller): integer
end
```

### PollModule

```teal
local record PollModule
  new: function(): Poller
  --  Event mask for readable data.
  POLLIN: integer
  --  Event mask for writable.
  POLLOUT: integer
  --  Event mask for priority data (e.g., OOB on TCP).
  POLLPRI: integer
  --  Event mask for error condition.
  POLLERR: integer
  --  Event mask for hangup.
  POLLHUP: integer
  --  Event mask for invalid fd.
  POLLNVAL: integer
  --  Event mask for peer closed connection.
  POLLRDHUP: integer
end
```

## Functions

### new

```teal
function new(): Poller
```

 Create a new poll set.
 Example:
   local p = poll.new()
   p:add(sock.fd, poll.POLLIN)           -- net.Socket: .fd field
   p:add(h:fd(), poll.POLLIN)            -- fd.Handle: :fd() method
   p:add(pipe.reader:fd(), poll.POLLIN)  -- fd.Pipe ends are Handles
   for fd, events in p:wait(30000) do
     if events.readable then
       -- read from fd
     end
   end

**Returns:**

- Poller - A new poll set
