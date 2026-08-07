#!/usr/bin/env cosmic
local check = require("cosmic.check")
local poll = require("cosmic.poll")
local cfd = require("cosmic.fd")
local net = require("cosmic.net")
local child = require("cosmic.child")

-- wait() returns the ready set as {fd: Events}; count entries directly.
local function ready_count(ready: {integer: poll.Events}): integer
  local n = 0
  for _ in pairs(ready) do n = n + 1 end
  return n
end

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
end
test_poller_new()

local function test_poller_add_remove_raw_fd()
  local p = poll.new()
  assert(p:add(1, poll.POLLOUT)) -- stdout
  assert(not p:is_empty(), "poller should not be empty after add")
  assert(p:add(2, poll.POLLOUT)) -- stderr
  p:remove(1)
  p:remove(2)
  assert(p:is_empty(), "poller should be empty after removing both")
  assert(p:add(1, poll.POLLOUT))
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
  assert(p:add(pipe.reader:fd(), poll.POLLIN))

  -- Short timeout - returns immediately since data is available
  local ready = check.must(p:wait(100))
  assert(ready_count(ready) == 1, "expected 1 ready fd")
  local events = check.must(ready[pipe.reader:fd()], "reader should be ready")
  assert(events.readable, "expected readable event")
  assert(not events.error, "unexpected error event")

  assert(pipe:close())
end
test_poll_pipe_readable()

local function test_poll_pipe_writable()
  local pipe = check.must(cfd.pipe())

  local p = poll.new()
  -- Writer is writable, since the pipe buffer is empty
  assert(p:add(pipe.writer:fd(), poll.POLLOUT))

  local ready = check.must(p:wait(100))
  assert(ready_count(ready) == 1, "expected 1 ready fd")
  local events = check.must(ready[pipe.writer:fd()], "writer should be ready")
  assert(events.writable, "expected writable event")

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

  local ready = check.must(p:wait(100))
  for _, events in pairs(ready) do
    assert(events.readable, "expected readable")
  end
  assert(ready[pipe1.reader:fd()], "pipe1 reader should be ready")
  assert(ready[pipe2.reader:fd()], "pipe2 reader should be ready")

  assert(pipe1:close())
  assert(pipe2:close())
end
test_poll_multiple_fds()

local function test_poll_timeout()
  local pipe = check.must(cfd.pipe())

  local p = poll.new()
  -- Poll for read on empty pipe - should time out with an EMPTY map,
  -- which is a successful wait, not an error.
  assert(p:add(pipe.reader:fd(), poll.POLLIN))

  local ready, err = p:wait(10)
  assert(ready ~= nil, "timeout is not an error: " .. tostring(err))
  assert(ready_count(ready) == 0, "expected no ready fds on timeout")

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

  local ready = check.must(p:wait(100))
  assert(ready_count(ready) == 1, "expected 1 ready socket")
  local events = check.must(ready[sock2.fd], "sock2 should be ready")
  assert(events.readable, "expected readable")

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

  local ready = check.must(p:wait(1000))
  assert(ready_count(ready) >= 1, "expected at least 1 event from child stdout")
  local events = check.must(ready[pp.reader:fd()], "reader should be ready")
  assert(events.readable or events.hangup, "expected readable or hangup")
  assert(events.revents ~= nil, "revents should be set")

  assert(pp.reader:close())
  assert(h:wait())
end
test_poll_with_child_pipes()

local function test_poll_nonblocking()
  local pipe = check.must(cfd.pipe())

  local p = poll.new()
  assert(p:add(pipe.reader:fd(), poll.POLLIN))

  -- Non-blocking wait (timeout = 0) on an empty pipe: empty map
  local ready = check.must(p:wait(0))
  assert(ready_count(ready) == 0, "expected 0 ready fds for non-blocking wait")
  assert(ready[999] == nil, "an unready fd simply has no entry")

  assert(pipe:close())
end
test_poll_nonblocking()

local function test_poll_hangup()
  local pipe = check.must(cfd.pipe())

  -- Close the writer to trigger hangup on reader
  assert(pipe.writer:close())

  local p = poll.new()
  assert(p:add(pipe.reader:fd(), poll.POLLIN))

  local ready = check.must(p:wait(100))
  local events = check.must(ready[pipe.reader:fd()], "reader should report")
  -- When writer closes, reader gets POLLHUP
  assert(events.hangup or events.readable, "expected hangup or readable on closed pipe")

  assert(pipe.reader:close())
end
test_poll_hangup()

-- Error fidelity: add(nil)/add(-1) return false + err instead of
-- silently doing nothing, and wait() surfaces a hard poll error in
-- slot 2 — the old iterator ate it as loop state, patched by a
-- stateful err() sidecar; both are gone.

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
  local ready, perr = p:wait(0)
  if ready ~= nil then
    io.stderr:write("SKIP: test_wait_surfaces_hard_error (could not provoke poll failure)\n")
    return
  end
  assert(perr:match("E%u+"), "wait error should name the errno, got: " .. perr)
end
test_wait_surfaces_hard_error()

print("all poll tests passed")
