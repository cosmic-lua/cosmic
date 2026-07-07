#!/usr/bin/env cosmic
local poll = require("cosmic.poll")
local cio = require("cosmic.io")
local net = require("cosmic.net")
local child = require("cosmic.child")

local function test_poll_constants()
  assert(poll.POLLIN ~= nil, "POLLIN not defined")
  assert(poll.POLLOUT ~= nil, "POLLOUT not defined")
  assert(poll.POLLERR ~= nil, "POLLERR not defined")
  assert(poll.POLLHUP ~= nil, "POLLHUP not defined")
  assert(poll.POLLNVAL ~= nil, "POLLNVAL not defined")
  assert(poll.POLLPRI ~= nil, "POLLPRI not defined")
  assert(poll.POLLRDHUP ~= nil, "POLLRDHUP not defined")
end
test_poll_constants()

local function test_poller_new()
  local p = poll.new()
  assert(p ~= nil, "new() returned nil")
  assert(p.empty ~= nil, "empty method missing")
  assert(p.add ~= nil, "add method missing")
  assert(p.remove ~= nil, "remove method missing")
  assert(p.wait ~= nil, "wait method missing")
  assert(p:empty(), "new poller should be empty")
  assert(p:count() == 0, "new poller count should be 0")
end
test_poller_new()

local function test_poller_add_remove_raw_fd()
  local p = poll.new()
  -- Add a raw fd number
  p:add(1, poll.POLLOUT) -- stdout
  assert(not p:empty(), "poller should not be empty after add")
  assert(p:count() == 1, "count should be 1")

  p:add(2, poll.POLLOUT) -- stderr
  assert(p:count() == 2, "count should be 2")

  p:remove(1)
  assert(p:count() == 1, "count should be 1 after remove")

  p:clear()
  assert(p:empty(), "poller should be empty after clear")
end
test_poller_add_remove_raw_fd()

local function test_poll_pipe_readable()
  local pipe, err = cio.pipe()
  assert(pipe ~= nil, "pipe creation failed: " .. tostring(err))
  local pipe = pipe as cio.Pipe

  -- Write to the pipe so it becomes readable
  local n = pipe.writer:write("hello")
  assert(n == 5, "expected 5 bytes written")

  local p = poll.new()
  -- Add the reader using its fd() method
  p:add(pipe.reader:fd(), poll.POLLIN)
  assert(p:count() == 1, "count should be 1")

  -- Poll with short timeout - should return immediately since data is available
  local count = 0
  for fd, events in p:wait(100) do
    assert(fd == pipe.reader:fd(), "expected reader fd")
    assert(events.readable, "expected readable event")
    assert(not events.error, "unexpected error event")
    count = count + 1
  end
  assert(count == 1, "expected 1 ready fd, got " .. count)

  pipe:close()
end
test_poll_pipe_readable()

local function test_poll_pipe_writable()
  local pipe, err = cio.pipe()
  assert(pipe ~= nil, "pipe creation failed: " .. tostring(err))
  local pipe = pipe as cio.Pipe

  local p = poll.new()
  -- Check if writer is writable (should be, since buffer is empty)
  p:add(pipe.writer:fd(), poll.POLLOUT)

  local count = 0
  for fd, events in p:wait(100) do
    assert(fd == pipe.writer:fd(), "expected writer fd")
    assert(events.writable, "expected writable event")
    count = count + 1
  end
  assert(count == 1, "expected 1 ready fd")

  pipe:close()
end
test_poll_pipe_writable()

local function test_poll_multiple_fds()
  local pipe1, err1 = cio.pipe()
  assert(pipe1 ~= nil, "pipe1 creation failed: " .. tostring(err1))
  local pipe1 = pipe1 as cio.Pipe

  local pipe2, err2 = cio.pipe()
  assert(pipe2 ~= nil, "pipe2 creation failed: " .. tostring(err2))
  local pipe2 = pipe2 as cio.Pipe

  -- Write to both pipes
  pipe1.writer:write("hello")
  pipe2.writer:write("world")

  local p = poll.new()
  p:add(pipe1.reader:fd(), poll.POLLIN)
  p:add(pipe2.reader:fd(), poll.POLLIN)
  assert(p:count() == 2, "count should be 2")

  local ready_fds: {number: boolean} = {}
  for fd, events in p:wait(100) do
    assert(events.readable, "expected readable")
    ready_fds[fd] = true
  end

  assert(ready_fds[pipe1.reader:fd()], "pipe1 reader should be ready")
  assert(ready_fds[pipe2.reader:fd()], "pipe2 reader should be ready")

  pipe1:close()
  pipe2:close()
end
test_poll_multiple_fds()

local function test_poll_timeout()
  local pipe, err = cio.pipe()
  assert(pipe ~= nil, "pipe creation failed: " .. tostring(err))
  local pipe = pipe as cio.Pipe

  local p = poll.new()
  -- Poll for read on empty pipe - should timeout
  p:add(pipe.reader:fd(), poll.POLLIN)

  local count = 0
  for _, _ in p:wait(10) do -- 10ms timeout
    count = count + 1
  end
  assert(count == 0, "expected no ready fds on timeout")

  pipe:close()
end
test_poll_timeout()

local function test_poll_with_socket()
  local sock1, sock2, err = net.socketpair()
  assert(sock1 ~= nil and sock2 ~= nil, "socketpair failed: " .. tostring(err))
  local sock1 = sock1 as net.Socket

  -- Send data on sock1
  sock1:send("hello")

  local p = poll.new()
  -- Socket has fd field directly
  p:add(sock2.fd, poll.POLLIN)

  local count = 0
  for fd, events in p:wait(100) do
    assert(fd == sock2.fd, "expected sock2 fd")
    assert(events.readable, "expected readable")
    count = count + 1
  end
  assert(count == 1, "expected 1 ready socket")

  sock1:close()
  sock2:close()
end
test_poll_with_socket()

local function test_poll_with_child_pipes()
  -- Redirect the child's stdout into a pipe we own, then poll the read end.
  local pp0, perr = cio.pipe()
  assert(pp0 ~= nil, "pipe creation failed: " .. tostring(perr))
  local pp = pp0 as cio.Pipe
  local handle, err = child.spawn({"echo", "hello"}, {stdout = pp.writer:fd()})
  assert(handle ~= nil, "spawn failed: " .. tostring(err))
  local h = handle as child.Handle
  pp.writer:close()

  local p = poll.new()
  p:add(pp.reader:fd(), poll.POLLIN)

  local count = 0
  for fd, events in p:wait(1000) do
    assert(fd == pp.reader:fd(), "expected reader fd")
    assert(events.readable or events.hangup, "expected readable or hangup")
    count = count + 1
  end
  assert(count >= 1, "expected at least 1 event from child stdout")

  pp.reader:close()
  h:wait()
end
test_poll_with_child_pipes()

local function test_poll_events_method()
  local pipe, err = cio.pipe()
  assert(pipe ~= nil, "pipe creation failed: " .. tostring(err))
  local pipe = pipe as cio.Pipe

  pipe.writer:write("test")

  local p = poll.new()
  p:add(pipe.reader:fd(), poll.POLLIN)

  local ready, poll_err = p:poll(100)
  assert(ready ~= nil, "poll failed: " .. tostring(poll_err))
  assert(ready == 1, "expected 1 ready fd")

  local events = p:events(pipe.reader:fd())
  assert(events ~= nil, "events should not be nil for ready fd")
  local events = events as poll.Events
  assert(events.readable, "expected readable")
  assert(events.revents ~= nil, "revents should be set")

  local no_events = p:events(999)
  assert(no_events == nil, "events should be nil for non-ready fd")

  pipe:close()
end
test_poll_events_method()

local function test_poll_nonblocking()
  local pipe, err = cio.pipe()
  assert(pipe ~= nil, "pipe creation failed: " .. tostring(err))
  local pipe = pipe as cio.Pipe

  local p = poll.new()
  p:add(pipe.reader:fd(), poll.POLLIN)

  -- Non-blocking poll (timeout = 0)
  local ready, _ = p:poll(0)
  assert(ready == 0, "expected 0 ready fds for non-blocking poll on empty pipe")

  pipe:close()
end
test_poll_nonblocking()

local function test_poll_hangup()
  local pipe, err = cio.pipe()
  assert(pipe ~= nil, "pipe creation failed: " .. tostring(err))
  local pipe = pipe as cio.Pipe

  -- Close the writer to trigger hangup on reader
  pipe.writer:close()

  local p = poll.new()
  p:add(pipe.reader:fd(), poll.POLLIN)

  for fd, events in p:wait(100) do
    assert(fd == pipe.reader:fd(), "expected reader fd")
    -- When writer closes, reader gets POLLHUP
    assert(events.hangup or events.readable, "expected hangup or readable on closed pipe")
  end

  pipe.reader:close()
end
test_poll_hangup()

-- Error fidelity (issue #529): add(nil) raises instead of silently
-- doing nothing, and wait() surfaces a hard poll error instead of
-- returning an indistinguishable empty iterator.

local function test_add_nil_fd_errors()
  local p = poll.new()
  local ok = pcall(function()
      p:add(nil, poll.POLLIN)
    end)
  assert(not ok, "add(nil) should raise, not silently no-op")
end
test_add_nil_fd_errors()

local function test_wait_surfaces_hard_error()
  -- Provoke a real poll failure: more fds than RLIMIT_NOFILE is EINVAL.
  local p = poll.new()
  for i = 1, 100000 do
    p:add(i, poll.POLLIN)
  end
  local n, perr = p:poll(0)
  if n ~= nil then
    io.stderr:write("SKIP: test_wait_surfaces_hard_error (could not provoke poll failure)\n")
    return
  end
  assert(perr:match("E%u+"), "poll error should name the errno, got: " .. perr)
  local iter, werr = p:wait(0)
  assert(type(iter) == "function", "wait must still return an iterator on error")
  for _ in iter do
    assert(false, "the error iterator must be empty")
  end
  assert(type(werr) == "string" and werr:match("E%u+"),
    "wait should surface the poll error, got: " .. tostring(werr))
end
test_wait_surfaces_hard_error()

print("all poll tests passed")
