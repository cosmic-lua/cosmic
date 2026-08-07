#!/usr/bin/env cosmic
local check = require("cosmic.check")
local poll = require("cosmic.poll")
local cfd = require("cosmic.fd")
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
  assert(p.is_empty ~= nil, "is_empty method missing")
  assert(p.add ~= nil, "add method missing")
  assert(p.remove ~= nil, "remove method missing")
  assert(p.wait ~= nil, "wait method missing")
  assert(p:is_empty(), "new poller should be empty")
  assert(p:count() == 0, "new poller count should be 0")
end
test_poller_new()

local function test_poller_add_remove_raw_fd()
  local p = poll.new()
  -- Add a raw fd number
  assert(p:add(1, poll.POLLOUT)) -- stdout
  assert(not p:is_empty(), "poller should not be empty after add")
  assert(p:count() == 1, "count should be 1")

  assert(p:add(2, poll.POLLOUT)) -- stderr
  assert(p:count() == 2, "count should be 2")

  p:remove(1)
  assert(p:count() == 1, "count should be 1 after remove")

  p:clear()
  assert(p:is_empty(), "poller should be empty after clear")
end
test_poller_add_remove_raw_fd()

local function test_poll_pipe_readable()
  local pipe = check.must(cfd.pipe())

  -- Write to the pipe so it becomes readable
  local n = pipe.writer:write("hello")
  assert(n == 5, "expected 5 bytes written")

  local p = poll.new()
  -- Add the reader using its fd() method
  assert(p:add(pipe.reader:fd(), poll.POLLIN))
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

  assert(pipe:close())
end
test_poll_pipe_readable()

local function test_poll_pipe_writable()
  local pipe = check.must(cfd.pipe())

  local p = poll.new()
  -- Check if writer is writable (should be, since buffer is empty)
  assert(p:add(pipe.writer:fd(), poll.POLLOUT))

  local count = 0
  for fd, events in p:wait(100) do
    assert(fd == pipe.writer:fd(), "expected writer fd")
    assert(events.writable, "expected writable event")
    count = count + 1
  end
  assert(count == 1, "expected 1 ready fd")

  assert(pipe:close())
end
test_poll_pipe_writable()

local function test_poll_multiple_fds()
  local pipe1 = check.must(cfd.pipe())

  local pipe2 = check.must(cfd.pipe())

  -- Write to both pipes
  assert(pipe1.writer:write("hello"))
  assert(pipe2.writer:write("world"))

  local p = poll.new()
  assert(p:add(pipe1.reader:fd(), poll.POLLIN))
  assert(p:add(pipe2.reader:fd(), poll.POLLIN))
  assert(p:count() == 2, "count should be 2")

  local ready_fds: {number: boolean} = {}
  for fd, events in p:wait(100) do
    assert(events.readable, "expected readable")
    ready_fds[fd] = true
  end

  assert(ready_fds[pipe1.reader:fd()], "pipe1 reader should be ready")
  assert(ready_fds[pipe2.reader:fd()], "pipe2 reader should be ready")

  assert(pipe1:close())
  assert(pipe2:close())
end
test_poll_multiple_fds()

local function test_poll_timeout()
  local pipe = check.must(cfd.pipe())

  local p = poll.new()
  -- Poll for read on empty pipe - should timeout
  assert(p:add(pipe.reader:fd(), poll.POLLIN))

  local count = 0
  for _, _ in p:wait(10) do -- 10ms timeout
    count = count + 1
  end
  assert(count == 0, "expected no ready fds on timeout")

  assert(pipe:close())
end
test_poll_timeout()

local function test_poll_with_socket()
  local sp = check.must(net.socketpair())
  local raw_sock1, sock2 = sp.a, sp.b
  local sock1 = check.must(raw_sock1)

  -- Send data on sock1
  assert(sock1:send("hello"))

  local p = poll.new()
  -- Socket has fd field directly
  assert(p:add(sock2.fd, poll.POLLIN))

  local count = 0
  for fd, events in p:wait(100) do
    assert(fd == sock2.fd, "expected sock2 fd")
    assert(events.readable, "expected readable")
    count = count + 1
  end
  assert(count == 1, "expected 1 ready socket")

  assert(sock1:close())
  assert(sock2:close())
end
test_poll_with_socket()

local function test_poll_with_child_pipes()
  -- Redirect the child's stdout into a pipe we own, then poll the read end.
  local pp = check.must(cfd.pipe())
  local h = check.must(child.start({"echo", "hello"}, {stdout = pp.writer}))
  assert(pp.writer:close())

  local p = poll.new()
  assert(p:add(pp.reader:fd(), poll.POLLIN))

  local count = 0
  for fd, events in p:wait(1000) do
    assert(fd == pp.reader:fd(), "expected reader fd")
    assert(events.readable or events.hangup, "expected readable or hangup")
    count = count + 1
  end
  assert(count >= 1, "expected at least 1 event from child stdout")

  assert(pp.reader:close())
  assert(h:wait())
end
test_poll_with_child_pipes()

local function test_poll_events_method()
  local pipe = check.must(cfd.pipe())

  assert(pipe.writer:write("test"))

  local p = poll.new()
  assert(p:add(pipe.reader:fd(), poll.POLLIN))

  local ready, poll_err = p:poll(100)
  assert(ready ~= nil, "poll failed: " .. tostring(poll_err))
  assert(ready == 1, "expected 1 ready fd")

  local events = check.must(p:events(pipe.reader:fd()),
    "raw_events should not be nil for ready fd")
  assert(events.readable, "expected readable")
  assert(events.revents ~= nil, "revents should be set")

  local no_events = p:events(999)
  assert(no_events == nil, "events should be nil for non-ready fd")

  assert(pipe:close())
end
test_poll_events_method()

local function test_poll_nonblocking()
  local pipe = check.must(cfd.pipe())

  local p = poll.new()
  assert(p:add(pipe.reader:fd(), poll.POLLIN))

  -- Non-blocking poll (timeout = 0)
  local ready, _ = p:poll(0)
  assert(ready == 0, "expected 0 ready fds for non-blocking poll on empty pipe")

  assert(pipe:close())
end
test_poll_nonblocking()

local function test_poll_hangup()
  local pipe = check.must(cfd.pipe())

  -- Close the writer to trigger hangup on reader
  assert(pipe.writer:close())

  local p = poll.new()
  assert(p:add(pipe.reader:fd(), poll.POLLIN))

  for fd, events in p:wait(100) do
    assert(fd == pipe.reader:fd(), "expected reader fd")
    -- When writer closes, reader gets POLLHUP
    assert(events.hangup or events.readable, "expected hangup or readable on closed pipe")
  end

  assert(pipe.reader:close())
end
test_poll_hangup()

-- Error fidelity: add(nil)/add(-1) return false + err instead of
-- silently doing nothing (or, before the error-shape wave, throwing
-- from library code), and wait() surfaces a hard poll error through
-- err() instead of an indistinguishable empty iterator.

local function test_add_bad_fd_errors()
  local p = poll.new()
  local ok, err = p:add(nil, poll.POLLIN)
  assert(not ok, "add(nil) must fail, not silently no-op")
  assert(err and err:find("nil", 1, true), "error names the problem: " .. tostring(err))
  local ok2, err2 = p:add(-1, poll.POLLIN)
  assert(not ok2, "add(-1) must fail: a closed fd.Handle reports -1")
  assert(err2 and err2:find("-1", 1, true), "error names the fd: " .. tostring(err2))
  assert(p:is_empty(), "failed adds register nothing")
end
test_add_bad_fd_errors()

local function test_wait_surfaces_hard_error()
  -- Provoke a real poll failure: more fds than RLIMIT_NOFILE is EINVAL.
  local p = poll.new()
  for i = 1, 100000 do
    assert(p:add(i, poll.POLLIN))
  end
  local n, perr = p:poll(0)
  if n ~= nil then
    io.stderr:write("SKIP: test_wait_surfaces_hard_error (could not provoke poll failure)\n")
    return
  end
  assert(perr:match("E%u+"), "poll error should name the errno, got: " .. perr)
  -- Regression: results must never be left nil after a failed poll --
  -- events() indexes it unconditionally, so a nil there crashes instead
  -- of reporting "no events for this fd".
  local ev = p:events(1)
  assert(ev == nil, "events() should return nil (not crash) after a failed poll")
  local iter = p:wait(0)
  assert(type(iter) == "function", "wait must still return an iterator on error")
  for _ in iter do
    assert(false, "the error iterator must be empty")
  end
  local werr = p:err()
  assert(type(werr) == "string" and string.match(werr, "E%u+"),
    "err() should surface the poll error, got: " .. tostring(werr))
end
test_wait_surfaces_hard_error()

print("all poll tests passed")
