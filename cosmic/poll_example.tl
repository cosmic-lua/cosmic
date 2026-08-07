--- Examples for the cosmic.poll module.
--- Demonstrates monitoring file descriptors for readiness with a
--- Poller, using a pipe from cosmic.fd as a deterministic fd source.

-- Example_pipe_readiness demonstrates the wait pattern: an
-- empty pipe is writable but not readable; after a write, both ends
-- are ready. A timeout of 0 makes wait() non-blocking.
local function Example_pipe_readiness()
  local check = require("cosmic.check")
  local fd = require("cosmic.fd")
  local poll = require("cosmic.poll")

  local p = check.must(fd.pipe())
  local set = poll.new()
  assert(set:add(p.writer:fd(), poll.POLLOUT))
  assert(set:add(p.reader:fd(), poll.POLLIN))

  local function ready_count(ready: {integer: poll.Events}): integer
    local n = 0
    for _ in pairs(ready) do n = n + 1 end
    return n
  end
  local ready = check.must(set:wait(0))
  print(ready_count(ready)) -- only the writer is ready
  assert(p.writer:write("ping"))
  ready = check.must(set:wait(0))
  print(ready_count(ready)) -- now the reader is ready too

  local ev = check.must(ready[p.reader:fd()])
  print(ev.readable)
  print(check.must(p.reader:read(4)))
  assert(p:close())
  -- Output:
  -- 1
  -- 2
  -- true
  -- ping
end

-- Example_wait_ready_set demonstrates wait(), which returns the ready
-- set as a {fd: Events} map: iterate it with pairs, or index a specific
-- descriptor directly.
local function Example_wait_ready_set()
  local check = require("cosmic.check")
  local fd = require("cosmic.fd")
  local poll = require("cosmic.poll")

  local p = check.must(fd.pipe())
  assert(p.writer:write("x"))

  local set = poll.new()
  assert(set:add(p.reader:fd(), poll.POLLIN))
  local ready = check.must(set:wait(0))
  for ready_fd, ev in pairs(ready) do
    print(ready_fd == p.reader:fd(), ev.readable)
  end
  assert(p:close())
  -- Output:
  -- true	true
end

-- Suppress unused warnings for examples
local _ = {Example_pipe_readiness, Example_wait_ready_set}
