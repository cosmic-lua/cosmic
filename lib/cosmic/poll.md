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
  revents: number
end
```

### Poller

 Poll set for monitoring multiple file descriptors.

```teal
local record Poller
  --  Add a file descriptor to the set.
  add: function(Poller, number, number)
  --  Remove a file descriptor from the set.
  remove: function(Poller, number)
  --  Clear all file descriptors from the set.
  clear: function(Poller)
  --  Poll for events with optional timeout.
  --  Returns an iterator over (fd, events) pairs for ready descriptors.
  --  EINTR is retried internally. A hard poll error yields an empty iterator
  --  (indistinguishable from a timeout); callers that must detect errors
  --  should use poll() directly, which returns them.
  wait: function(Poller, number): function(): number, Events
  --  Poll and return count of ready descriptors.
  poll: function(Poller, number): number | nil, string
  --  Get events for a specific fd after poll().
  events: function(Poller, number): Events | nil
  --  Returns true if the poller has no registered fds.
  empty: function(Poller): boolean
  --  Returns the number of registered fds.
  count: function(Poller): number
end
```

### PollModule

```teal
local record PollModule
  new: function(): Poller
  --  Event mask for readable data.
  POLLIN: number
  --  Event mask for writable.
  POLLOUT: number
  --  Event mask for priority data (e.g., OOB on TCP).
  POLLPRI: number
  --  Event mask for error condition.
  POLLERR: number
  --  Event mask for hangup.
  POLLHUP: number
  --  Event mask for invalid fd.
  POLLNVAL: number
  --  Event mask for peer closed connection.
  POLLRDHUP: number
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
