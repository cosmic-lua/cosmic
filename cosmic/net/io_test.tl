#!/usr/bin/env cosmic
local check = require("cosmic.check")
local net = require("cosmic.net")
local stream = require("cosmic.stream")
local time = require("cosmic.time")

local function pair(): net.Socket, net.Socket
  -- socket_pair's error lives in slot 2, so this wrapper is a one-liner.
  local p = check.must(net.socket_pair())
  return p.a, p.b
end

-- send_all tests

local function test_send_all_basic()
  local a, b = pair()
  local ok, err = a:send_all("hello world")
  assert(ok, "send_all failed: " .. tostring(err))
  local data = b:recv()
  assert(data == "hello world", "expected payload, got: " .. tostring(data))
  assert(a:close())
  assert(b:close())
end
test_send_all_basic()

local function test_send_all_empty()
  local a, b = pair()
  local ok, err = a:send_all("")
  assert(ok, "send_all of empty string failed: " .. tostring(err))
  assert(a:close())
  assert(b:close())
end
test_send_all_empty()

local function test_send_all_large()
  local a, b = pair()
  local payload = string.rep("x", 64 * 1024)
  local ok, err = a:send_all(payload)
  assert(ok, "send_all failed: " .. tostring(err))
  local data, rerr = b:recv_exact(#payload)
  assert(data == payload, "expected 64KiB round-trip: " .. tostring(rerr))
  assert(a:close())
  assert(b:close())
end
test_send_all_large()

local function test_send_all_closed_socket()
  local a, b = pair()
  assert(a:close())
  local ok, err = a:send_all("data")
  assert(not ok, "expected send_all on closed socket to fail")
  assert(err ~= nil, "expected an error message")
  assert(b:close())
end
test_send_all_closed_socket()

-- recv_exact tests

local function test_recv_exact_across_sends()
  local a, b = pair()
  assert(a:send_all("hello"))
  assert(a:send_all("world"))
  local data, err = b:recv_exact(10)
  assert(data == "helloworld", "expected coalesced read: " .. tostring(err))
  assert(a:close())
  assert(b:close())
end
test_recv_exact_across_sends()

local function test_recv_exact_leaves_rest()
  local a, b = pair()
  assert(a:send_all("abcdef"))
  local head = b:recv_exact(3)
  assert(head == "abc", "expected first 3 bytes, got: " .. tostring(head))
  local rest = b:recv_exact(3)
  assert(rest == "def", "expected remaining bytes, got: " .. tostring(rest))
  assert(a:close())
  assert(b:close())
end
test_recv_exact_leaves_rest()

local function test_recv_exact_zero()
  local a, b = pair()
  local data, err = b:recv_exact(0)
  assert(data == "", "expected empty string for n=0: " .. tostring(err))
  assert(a:close())
  assert(b:close())
end
test_recv_exact_zero()

local function test_recv_exact_early_close()
  local a, b = pair()
  assert(a:send_all("abc"))
  assert(a:shutdown())
  local data, err = b:recv_exact(5)
  assert(data == nil, "expected failure on short stream")
  assert(err and err:find("3 of 5", 1, true), "expected byte counts in error, got: " .. tostring(err))
  assert(a:close())
  assert(b:close())
end
test_recv_exact_early_close()

-- line iteration: Socket is a stream.Reader, so stream.lines is the
-- one line algorithm. It splits on "\n" alone, leaving any "\r" in the
-- line — a CRLF protocol strips its own "\r" — asserted below so the
-- behavior is a fact of the suite, not a surprise.

local function lines_of(sock: net.Socket): {string}
  local out: {string} = {}
  for line in stream.lines(sock) do
    out[#out + 1] = line
  end
  return out
end

local function test_lines_basic()
  local a, b = pair()
  assert(a:send_all("alpha\nbeta\r\ngamma"))
  assert(a:shutdown())
  local got = lines_of(b)
  assert(#got == 3, "expected three lines, got " .. #got)
  assert(got[1] == "alpha", "expected first line, got: " .. got[1])
  assert(got[2] == "beta\r", "stream.lines splits on \\n and keeps the \\r,"
    .. " got: " .. got[2])
  assert(got[3] == "gamma", "expected final unterminated line, got: " .. got[3])
  assert(a:close())
  assert(b:close())
end
test_lines_basic()

local function test_lines_empty_line()
  local a, b = pair()
  assert(a:send_all("first\n\nsecond\n"))
  assert(a:shutdown())
  local got = lines_of(b)
  assert(#got == 3, "expected three lines, got " .. #got)
  assert(got[2] == "", "expected empty line preserved")
  assert(got[3] == "second", "expected second line, got: " .. got[3])
  assert(a:close())
  assert(b:close())
end
test_lines_empty_line()

local function test_lines_long_line_multiple_chunks()
  local a, b = pair()
  local long = string.rep("z", 10000)
  assert(a:send_all(long .. "\nnext\n"))
  assert(a:shutdown())
  local got = lines_of(b)
  assert(got[1] == long, "expected 10k line reassembled")
  assert(got[2] == "next", "expected following line")
  assert(a:close())
  assert(b:close())
end
test_lines_long_line_multiple_chunks()

-- set_timeout_ms tests

local function test_set_timeout_ms_recv_times_out()
  local a, b = pair()
  local ok, serr = b:set_timeout_ms(50)
  assert(ok, "set_timeout_ms failed: " .. tostring(serr))
  local data, err = b:recv()
  assert(data == nil, "expected recv to time out")
  assert(err ~= nil, "expected a timeout error, not end of stream")
  assert(a:close())
  assert(b:close())
end
test_set_timeout_ms_recv_times_out()

local function test_set_timeout_ms_clear_restores_blocking()
  local a, b = pair()
  assert(b:set_timeout_ms(50))
  assert(b:set_timeout_ms())
  assert(a:send_all("ping"))
  local data = b:recv()
  assert(data == "ping", "expected recv to work after clearing timeout")
  assert(a:close())
  assert(b:close())
end
test_set_timeout_ms_clear_restores_blocking()

local function test_set_timeout_ms_bounds_line_iteration()
  local a, b = pair()
  assert(b:set_timeout_ms(50))
  assert(a:send_all("partial-without-newline"))
  local line, err = stream.lines(b)()
  assert(line == nil and err ~= nil,
    "expected line iteration to time out on a missing newline, got: " .. tostring(line))
  assert(a:close())
  assert(b:close())
end
test_set_timeout_ms_bounds_line_iteration()

local function test_set_timeout_ms_closed_socket()
  local a, b = pair()
  assert(a:close())
  local ok, err = a:set_timeout_ms(100)
  assert(not ok and err ~= nil, "expected set_timeout_ms on closed socket to fail")
  assert(b:close())
end
test_set_timeout_ms_closed_socket()

-- Socket implements the stream interfaces: a socket can be handed to
-- any consumer of stream.Reader / stream.Writer (e.g. cosmic.sse).
local function test_socket_is_stream()
  local a, b = pair()
  local w: stream.Writer = a
  local r: stream.Reader = b
  local n, werr = w:write("via stream")
  assert(n == 10, "write failed: " .. tostring(werr))
  local chunk, rerr = r:read()
  assert(chunk == "via stream", "read failed: " .. tostring(rerr))
  assert(a:close())
  local eof = r:read()
  assert(eof == nil, "expected bare nil at end of stream")
  assert(b:close())
end
test_socket_is_stream()

-- signal-safety wave: a blocking recv interrupted by a signal is
-- retried automatically instead of surfacing EINTR. The handler supplies
-- the payload via the peer socket.
local function test_recv_retries_eintr()
  local signal = require("cosmic.signal")
  local a, b = pair()
  local fired = false
  local on_alarm = function(_: number)
    if not fired then
      fired = true
      assert(a:send_all("ping"))
    end
  end
  local prev = check.must(signal.sigaction(signal.SIGALRM, on_alarm))
  -- Interval timer: keeps firing until the blocked recv observes a signal,
  -- so the test cannot hang however the timing lands.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 30,
        interval_ms = 30,
      }))
  local data, err = b:recv()
  -- Disarm and restore before asserting so a failure can't leave a
  -- ticking timer behind.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 0,
        interval_ms = 0,
      }))
  assert(signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask))
  assert(data == "ping", "interrupted recv should retry and return the peer's"
    .. " payload, got " .. tostring(data) .. " (err: " .. tostring(err) .. ")")
  assert(a:close())
  assert(b:close())
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
  assert(a:close())
  assert(b:close())
end
test_send_offset()

-- recv(0) reads "" from the kernel on a stream socket, which is
-- indistinguishable from "peer closed" unless max_bytes is rejected
-- outright: an honest error, not a throw.
local function test_recv_zero_max_bytes_is_error()
  local a, b = pair()
  local data, err = a:recv(0)
  assert(data == nil, "recv(0) should not return data")
  assert(err ~= nil and err:match("max_bytes"),
    "recv(0) should name max_bytes in the error, got: " .. tostring(err))
  assert(a:close())
  assert(b:close())
end
test_recv_zero_max_bytes_is_error()

local function test_recv_negative_max_bytes_is_error()
  local a, b = pair()
  local data, err = a:recv(-1)
  assert(data == nil, "recv(-1) should not return data")
  assert(err ~= nil and err:match("max_bytes"),
    "recv(-1) should name max_bytes in the error, got: " .. tostring(err))
  assert(a:close())
  assert(b:close())
end
test_recv_negative_max_bytes_is_error()

-- Socket:fd() is a method, not a field, and it reports -1 once closed —
-- the fd.Handle shape. That is what lets poll.add reject a descriptor
-- nobody holds instead of quietly polling a recycled one.
local function test_fd_is_minus_one_after_close()
  local a, b = pair()
  assert(a:fd() >= 0, "expected a live descriptor, got " .. tostring(a:fd()))
  assert(a:close())
  assert(a:fd() == -1, "closed socket should report -1, got " .. tostring(a:fd()))
  local poll = require("cosmic.poll")
  local ok, err = poll.new():add(a:fd(), poll.POLLIN)
  assert(not ok, "a closed socket's -1 must not register with a Poller")
  assert(err ~= nil, "expected an error message")
  assert(b:close())
end
test_fd_is_minus_one_after_close()

-- accept bounds its own wait: the listener's send/recv semantics stay
-- untouched, which set_timeout_ms on the listener could not promise.
local function test_accept_times_out()
  local srv = check.must(net.listen_tcp("127.0.0.1", 0))
  local t0 = time.monotonic()
  local conn, err = srv:accept({timeout_ms = 100})
  local elapsed_ms = (time.monotonic() - t0) * 1000
  assert(conn == nil, "accept with no client pending should not return a socket")
  assert(err ~= nil and err:find("timed out", 1, true) ~= nil,
    "expected a timeout error, got: " .. tostring(err))
  assert(elapsed_ms < 5000, "accept should return at its bound, took "
    .. tostring(elapsed_ms) .. "ms")
  assert(srv:close())
end
test_accept_times_out()

local function test_accept_within_timeout_returns_the_connection()
  local srv = check.must(net.listen_tcp("127.0.0.1", 0))
  local port = check.must(srv:local_endpoint()).port
  local client = check.must(net.dial("127.0.0.1", port))
  local conn = check.must(srv:accept({timeout_ms = 5000}))
  assert(client:send_all("bounded"))
  assert(conn:recv() == "bounded", "expected the payload through a bounded accept")
  assert(client:close())
  assert(conn:close())
  assert(srv:close())
end
test_accept_within_timeout_returns_the_connection()
