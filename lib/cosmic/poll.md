# poll

 Typed interface for polling file descriptors.
 Provides an ergonomic wrapper around unix.poll().

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
  --  Add a file descriptor to the set.
  add: function(Poller, integer, integer)
  --  Remove a file descriptor from the set.
  remove: function(Poller, integer)
  --  Clear all file descriptors from the set.
  clear: function(Poller)
  --  Poll for events with optional timeout.
  --  Returns an iterator over (fd, events) pairs for ready descriptors.
  --  EINTR is retried internally. On a hard poll error the iterator is
  --  empty and the error string is returned as the second value.
  wait: function(Poller, integer): function(): (integer, Events), string
  --  Poll and return count of ready descriptors.
  poll: function(Poller, integer): integer | nil, string
  --  Get events for a specific fd after poll().
  events: function(Poller, integer): Events | nil
  --  Returns true if the poller has no registered fds.
  empty: function(Poller): boolean
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
   p:add(handle.stdout.fd, poll.POLLIN)  -- child.Pipe: use .fd field
   p:add(reader:fd(), poll.POLLIN)       -- io.Handle: call :fd() method
   p:add(sock.fd, poll.POLLIN)           -- net.Socket: use .fd field
   for fd, events in p:wait(30000) do
     if events.readable then
       -- read from fd
     end
   end

**Returns:**

- Poller - A new poll set
