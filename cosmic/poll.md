# poll

 Typed interface for polling file descriptors.
 Provides an ergonomic wrapper around unix.poll().

 poll is the lowest layer and speaks raw integer fds. Every cosmic
 handle that owns one — fd.Handle, net.Socket — hands it over with
 :fd(), which returns -1 once closed; add() rejects a -1 rather than
 polling a descriptor nobody holds.

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
  --  Wait for events, up to timeout_ms. Returns the ready set as a
  --  {fd: Events} map — an empty map on timeout, `nil, err` on a hard
  --  poll failure — so `for fd, ev in pairs(ready) do` iterates it
  --  directly and the error arrives in slot 2. EINTR is retried against
  --  an absolute deadline, so repeated signals cannot stretch the wait
  --  past timeout_ms.
  wait: function(Poller, timeout_ms?: integer): {integer: Events} | nil, string
  --  Returns true if the poller has no registered fds.
  is_empty: function(Poller): boolean
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
   p:add(sock:fd(), poll.POLLIN)         -- net.Socket
   p:add(h:fd(), poll.POLLIN)            -- fd.Handle
   p:add(pipe.reader:fd(), poll.POLLIN)  -- fd.Pipe ends are Handles
   local ready = assert(p:wait(30000))
   for fd, events in pairs(ready) do
     if events.readable then
       -- read from fd
     end
   end

**Returns:**

- Poller - A new poll set
