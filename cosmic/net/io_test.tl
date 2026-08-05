#!/usr/bin/env cosmic
local check = require("cosmic.check")
local net = require("cosmic.net")

local function pair(): net.Socket, net.Socket
  -- socketpair's error lives in slot 2 now; the record makes the old
  -- shape-laundering helper a one-liner.
  local p = check.must(net.socketpair())
  return p.a, p.b
end

-- sendall tests

local function test_sendall_basic()
  local a, b = pair()
  local ok, err = a:sendall("hello world")
  assert(ok, "sendall failed: " .. tostring(err))
  local data = b:recv()
  assert(data == "hello world", "expected payload, got: " .. tostring(data))
  a:close()
  b:close()
end
test_sendall_basic()

local function test_sendall_empty()
  local a, b = pair()
  local ok, err = a:sendall("")
  assert(ok, "sendall of empty string failed: " .. tostring(err))
  a:close()
  b:close()
end
test_sendall_empty()

local function test_sendall_large()
  local a, b = pair()
  local payload = string.rep("x", 64 * 1024)
  local ok, err = a:sendall(payload)
  assert(ok, "sendall failed: " .. tostring(err))
  local data, rerr = b:recv_exact(#payload)
  assert(data == payload, "expected 64KiB round-trip: " .. tostring(rerr))
  a:close()
  b:close()
end
test_sendall_large()

local function test_sendall_closed_socket()
  local a, b = pair()
  a:close()
  local ok, err = a:sendall("data")
  assert(not ok, "expected sendall on closed socket to fail")
  assert(err ~= nil, "expected an error message")
  b:close()
end
test_sendall_closed_socket()

-- recv_exact tests

local function test_recv_exact_across_sends()
  local a, b = pair()
  assert(a:sendall("hello"))
  assert(a:sendall("world"))
  local data, err = b:recv_exact(10)
  assert(data == "helloworld", "expected coalesced read: " .. tostring(err))
  a:close()
  b:close()
end
test_recv_exact_across_sends()

local function test_recv_exact_leaves_rest()
  local a, b = pair()
  assert(a:sendall("abcdef"))
  local head = b:recv_exact(3)
  assert(head == "abc", "expected first 3 bytes, got: " .. tostring(head))
  local rest = b:recv_exact(3)
  assert(rest == "def", "expected remaining bytes, got: " .. tostring(rest))
  a:close()
  b:close()
end
test_recv_exact_leaves_rest()

local function test_recv_exact_zero()
  local a, b = pair()
  local data, err = b:recv_exact(0)
  assert(data == "", "expected empty string for n=0: " .. tostring(err))
  a:close()
  b:close()
end
test_recv_exact_zero()

local function test_recv_exact_early_close()
  local a, b = pair()
  assert(a:sendall("abc"))
  a:shutdown()
  local data, err = b:recv_exact(5)
  assert(data == nil, "expected failure on short stream")
  assert(err and err:find("3 of 5", 1, true), "expected byte counts in error, got: " .. tostring(err))
  a:close()
  b:close()
end
test_recv_exact_early_close()

-- readline tests

local function test_readline_basic()
  local a, b = pair()
  assert(a:sendall("alpha\nbeta\r\ngamma"))
  a:shutdown()
  assert(b:readline() == "alpha", "expected first line")
  assert(b:readline() == "beta", "expected CRLF stripped")
  assert(b:readline() == "gamma", "expected final unterminated line")
  local eof, err = b:readline()
  assert(eof == nil and err == nil, "expected bare nil at end of stream, got: " .. tostring(err))
  a:close()
  b:close()
end
test_readline_basic()

local function test_readline_empty_line()
  local a, b = pair()
  assert(a:sendall("first\n\nsecond\n"))
  a:shutdown()
  assert(b:readline() == "first", "expected first line")
  assert(b:readline() == "", "expected empty line preserved")
  assert(b:readline() == "second", "expected second line")
  assert(b:readline() == nil, "expected end of stream")
  a:close()
  b:close()
end
test_readline_empty_line()

local function test_readline_leaves_rest_for_recv()
  local a, b = pair()
  assert(a:sendall("line\nbinary-tail"))
  a:shutdown()
  assert(b:readline() == "line", "expected line")
  local rest = b:recv_exact(11)
  assert(rest == "binary-tail", "expected bytes after newline untouched, got: " .. tostring(rest))
  a:close()
  b:close()
end
test_readline_leaves_rest_for_recv()

local function test_readline_max()
  local a, b = pair()
  assert(a:sendall("abcdef\n"))
  local head = b:readline(3)
  assert(head == "abc", "expected max-bounded read, got: " .. tostring(head))
  local rest = b:readline()
  assert(rest == "def", "expected remainder line, got: " .. tostring(rest))
  a:close()
  b:close()
end
test_readline_max()

local function test_readline_long_line_multiple_chunks()
  local a, b = pair()
  local long = string.rep("z", 10000)
  assert(a:sendall(long .. "\nnext\n"))
  local line = b:readline()
  assert(line == long, "expected 10k line reassembled")
  assert(b:readline() == "next", "expected following line")
  a:close()
  b:close()
end
test_readline_long_line_multiple_chunks()

-- set_timeout tests

local function test_set_timeout_recv_times_out()
  local a, b = pair()
  local ok, serr = b:set_timeout(50)
  assert(ok, "set_timeout failed: " .. tostring(serr))
  local data, err = b:recv()
  assert(data == nil, "expected recv to time out")
  assert(err ~= nil, "expected a timeout error, not end of stream")
  a:close()
  b:close()
end
test_set_timeout_recv_times_out()

local function test_set_timeout_clear_restores_blocking()
  local a, b = pair()
  assert(b:set_timeout(50))
  assert(b:set_timeout())
  assert(a:sendall("ping"))
  local data = b:recv()
  assert(data == "ping", "expected recv to work after clearing timeout")
  a:close()
  b:close()
end
test_set_timeout_clear_restores_blocking()

local function test_set_timeout_readline_times_out()
  local a, b = pair()
  assert(b:set_timeout(50))
  assert(a:sendall("partial-without-newline"))
  local line, err = b:readline()
  assert(line == nil and err ~= nil, "expected readline to time out on missing newline")
  a:close()
  b:close()
end
test_set_timeout_readline_times_out()

local function test_set_timeout_closed_socket()
  local a, b = pair()
  a:close()
  local ok, err = a:set_timeout(100)
  assert(not ok and err ~= nil, "expected set_timeout on closed socket to fail")
  b:close()
end
test_set_timeout_closed_socket()

-- Socket implements the stream interfaces: a socket can be handed to
-- any consumer of stream.Reader / stream.Writer (e.g. cosmic.sse).
local function test_socket_is_stream()
  local stream = require("cosmic.stream")
  local a, b = pair()
  local w: stream.Writer = a
  local r: stream.Reader = b
  local n, werr = w:write("via stream")
  assert(n == 10, "write failed: " .. tostring(werr))
  local chunk, rerr = r:read()
  assert(chunk == "via stream", "read failed: " .. tostring(rerr))
  a:close()
  local eof = r:read()
  assert(eof == nil, "expected bare nil at end of stream")
  b:close()
end
test_socket_is_stream()

-- signal-safety wave: a blocking recv interrupted by a signal is
-- retried automatically instead of surfacing EINTR. The handler supplies
-- the payload via the peer socket.
local function test_recv_retries_eintr()
  local signal = require("cosmic.signal")
  local a, b = pair()
  local fired = false
  local prev = check.must(signal.sigaction(signal.SIGALRM, function(_: number)
      if not fired then
        fired = true
        a:sendall("ping")
      end
    end))
  -- Interval timer: keeps firing until the blocked recv observes a signal,
  -- so the test cannot hang however the timing lands.
  signal.setitimer({
      which = signal.ITIMER_REAL,
      valuesec = 0,
      valuens = 30000000,
      intervalsec = 0,
      intervalns = 30000000,
    })
  local data, err = b:recv()
  -- Disarm and restore before asserting so a failure can't leave a
  -- ticking timer behind.
  signal.setitimer({
      which = signal.ITIMER_REAL,
      valuesec = 0,
      valuens = 0,
      intervalsec = 0,
      intervalns = 0,
    })
  signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask)
  assert(data == "ping", "interrupted recv should retry and return the peer's"
    .. " payload, got " .. tostring(data) .. " (err: " .. tostring(err) .. ")")
  a:close()
  b:close()
end
test_recv_retries_eintr()

-- send exposes the binding's offset parameter — a partial-send
-- loop can window the buffer without copying via data:sub.
local function test_send_offset()
  local a, b = pair()
  local n, err = a:send("XXhello", 0, 2)
  assert(n == 5, "send with offset should send the tail, got "
    .. tostring(n) .. " (err: " .. tostring(err) .. ")")
  local got = b:recv()
  assert(got == "hello", "peer should see bytes past the offset, got: "
    .. tostring(got))
  a:close()
  b:close()
end
test_send_offset()

-- recv(0) reads "" from the kernel on a stream socket, which is
-- indistinguishable from "peer closed" (api-review-2, #589) unless
-- bufsiz is rejected outright: an honest error, not a throw.
local function test_recv_zero_bufsiz_is_error()
  local a, b = pair()
  local data, err = a:recv(0)
  assert(data == nil, "recv(0) should not return data")
  assert(err ~= nil and err:match("bufsiz"),
    "recv(0) should name bufsiz in the error, got: " .. tostring(err))
  a:close()
  b:close()
end
test_recv_zero_bufsiz_is_error()

local function test_recv_negative_bufsiz_is_error()
  local a, b = pair()
  local data, err = a:recv(-1)
  assert(data == nil, "recv(-1) should not return data")
  assert(err ~= nil and err:match("bufsiz"),
    "recv(-1) should name bufsiz in the error, got: " .. tostring(err))
  a:close()
  b:close()
end
test_recv_negative_bufsiz_is_error()
