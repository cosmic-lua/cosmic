--- Examples for the cosmic.poll module.
--- Demonstrates monitoring file descriptors for readiness with a
--- Poller, using a pipe from cosmic.fd as a deterministic fd source.

-- Example_pipe_readiness demonstrates the poll/events pattern: an
-- empty pipe is writable but not readable; after a write, both ends
-- are ready. A timeout of 0 makes poll() non-blocking.
local function Example_pipe_readiness()
  local fd = require("cosmic.fd")
  local poll = require("cosmic.poll")

  local p = assert(fd.pipe()) as fd.Pipe
  local set = poll.new()
  set:add(p.writer:fd(), poll.POLLOUT)
  set:add(p.reader:fd(), poll.POLLIN)

  print(set:poll(0)) -- only the writer is ready
  p.writer:write("ping")
  print(set:poll(0)) -- now the reader is ready too

  local ev = set:events(p.reader:fd()) as poll.Events
  print(ev.readable)
  print(p.reader:read(4))
  p:close()
  -- Output:
  -- 1
  -- 2
  -- true
  -- ping
end

-- Example_wait_iterator demonstrates wait(), which yields each ready
-- fd with its resolved Events record instead of requiring a follow-up
-- events() lookup per descriptor.
local function Example_wait_iterator()
  local fd = require("cosmic.fd")
  local poll = require("cosmic.poll")

  local p = assert(fd.pipe()) as fd.Pipe
  p.writer:write("x")

  local set = poll.new()
  set:add(p.reader:fd(), poll.POLLIN)
  for ready_fd, ev in set:wait(0) do
    print(ready_fd == p.reader:fd(), ev.readable)
  end
  p:close()
  -- Output:
  -- true	true
end

-- Suppress unused warnings for examples
local _ = {Example_pipe_readiness, Example_wait_iterator}
