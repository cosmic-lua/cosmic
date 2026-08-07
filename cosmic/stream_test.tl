#!/usr/bin/env cosmic
--- Stream-contract conformance suite (api-review-2): every byte
--- producer honors the one EOF convention — read returns a chunk, bare
--- nil (no error) at end of stream, and keeps returning bare nil after
--- EOF; failures return nil plus an error message. Run against
--- fd.Handle, net.Socket, fetch.Reader, and child.Handle.
local check = require("cosmic.check")
local stream = require("cosmic.stream")
local fd = require("cosmic.fd")
local net = require("cosmic.net")
local child = require("cosmic.child")
local fetch = require("cosmic.fetch")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")

local lua_bin = fs.join(os.getenv("TEST_BIN"), "cosmic")

--- Drain a Reader to EOF and check the contract along the way: no
--- errors, bare nil terminates, and reads after EOF stay bare nil.
--- Taking stream.Reader here is itself the compile-time conformance
--- check for every type passed in below.
local function check_reader(r: stream.Reader, want: string, label: string)
  local parts: {string} = {}
  while true do
    local chunk, err = r:read(4096)
    assert(err == nil, label .. ": unexpected read error: " .. tostring(err))
    if chunk == nil then
      break
    end
    assert(chunk ~= "", label .. ": a Reader never yields \"\"")
    parts[#parts + 1] = chunk
  end
  local got = table.concat(parts)
  assert(got == want, label .. ": payload mismatch, got '" .. got .. "'")
  for i = 1, 2 do
    local again, err2 = r:read(4096)
    assert(again == nil and err2 == nil,
      label .. ": read " .. i .. " after EOF must stay bare nil, got "
      .. tostring(again) .. ", " .. tostring(err2))
  end
end

local function test_fd_handle_conforms()
  local p = check.must(fd.pipe())
  assert(p.writer:write("fd bytes"))
  assert(p.writer:close())
  check_reader(p.reader, "fd bytes", "fd.Handle")
  assert(p.reader:close())
end
test_fd_handle_conforms()

local function test_socket_recv_eof_is_nil()
  local sp = check.must(net.socketpair())
  local a, b = sp.a, sp.b

  assert(a:send("socket bytes"))
  assert(a:close())

  local got = ""
  while true do
    local chunk, rerr = b:recv(4096)
    assert(rerr == nil, "unexpected recv error: " .. tostring(rerr))
    if chunk == nil then break end
    got = got .. chunk
  end
  assert(got == "socket bytes", "payload mismatch, got '" .. got .. "'")
  -- recv after end of stream stays bare nil
  local again, aerr = b:recv(4096)
  assert(again == nil and aerr == nil, "recv after EOF must stay bare nil")
  assert(b:close())

  -- and the error channel is intact: recv on a closed socket errors
  local d, cerr = b:recv()
  assert(d == nil and cerr == "socket closed", "closed-socket recv shape")
end
test_socket_recv_eof_is_nil()

local function test_socket_zero_byte_datagram_stays_empty()
  -- "" is reserved for the one honest case: a zero-byte datagram on a
  -- message socket. It must NOT be collapsed into nil.
  local sp = check.must(net.socketpair({socktype = net.SOCK_DGRAM}))
  local a, b = sp.a, sp.b

  assert(a:send(""))
  local dgram, derr = b:recv(4096)
  assert(dgram == "", "zero-byte datagram must arrive as \"\", got "
    .. tostring(dgram) .. " (" .. tostring(derr) .. ")")

  assert(a:send("dgram"))
  local data = b:recv(4096)
  assert(data == "dgram", "datagram payload intact")

  assert(a:close())
  assert(b:close())
end
test_socket_zero_byte_datagram_stays_empty()

local function test_child_handle_conforms()
  local h = check.must(child.start({lua_bin, "-e", "io.write('child bytes'); io.flush()"}))
  check_reader(h, "child bytes", "child.Handle")
  assert(h:wait())
end
test_child_handle_conforms()

--- Fork a loopback server answering one request, closing right after.
local function serve_once(response: string): integer, integer
  local srv = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local port = check.must(s:getsockname()).port
  local pid = proc.fork()
  if pid == 0 then
    local conn = s:accept()
    if conn then
      local c = check.must(conn)
      local buf = ""
      while not buf:find("\r\n\r\n", 1, true) do
        local data = c:recv(4096)
        if not data then break end
        buf = buf .. data
      end
      assert(c:send(response))
      assert(c:close())
    end
    os.exit(0)
  end
  assert(s:close())
  return math.tointeger(port), pid
end

local function test_fetch_reader_conforms()
  local body = "fetch bytes"
  local port, pid = serve_once("HTTP/1.1 200 OK\r\nContent-Length: " .. #body
    .. "\r\nConnection: close\r\n\r\n" .. body)
  local result = fetch.stream("http://127.0.0.1:" .. port .. "/",
    {allow_private = true})
  assert(result.ok == true, "stream failed: " .. tostring(result.error))
  check_reader(result.reader, body, "fetch.Reader")
  assert(result.reader:close())
  assert(proc.wait(pid))
end
test_fetch_reader_conforms()

local function test_from_string_conforms()
  check_reader(stream.from_string("in-memory bytes"), "in-memory bytes",
    "stream.from_string")
end
test_from_string_conforms()

local function test_from_string_chunks_and_edges()
  -- n bounds each chunk; the tail chunk may be short.
  local r = stream.from_string("abcdef")
  check.equal(r:read(4), "abcd", "first bounded chunk")
  check.equal(r:read(4), "ef", "short tail chunk")
  check.equal(r:read(4), nil, "then end of stream")

  -- An empty string is an empty stream: bare nil immediately.
  local empty = stream.from_string("")
  local chunk, err = empty:read()
  assert(chunk == nil and err == nil, "empty string reads as clean EOF")

  -- A non-positive bound is an honest error, not a sneaky EOF.
  local bad = stream.from_string("data")
  local got, bad_err = bad:read(0)
  assert(got == nil and bad_err ~= nil, "n must be positive")
end
test_from_string_chunks_and_edges()

local function test_from_string_feeds_lines()
  local iter = stream.lines(stream.from_string("one\ntwo\nthree"))
  check.equal(iter(), "one", "first line")
  check.equal(iter(), "two", "second line")
  check.equal(iter(), "three", "final unterminated line")
  check.equal(iter(), nil, "then nil")
end
test_from_string_feeds_lines()

local function test_buffer_collects_writes()
  local buf = stream.buffer()
  check.equal(buf:contents(), "", "empty before any write")
  check.equal(buf:write("collected "), 10, "write reports the chunk written")
  assert(buf:write("bytes"))
  check.equal(buf:contents(), "collected bytes", "contents is everything written")
  check.equal(buf:contents(), "collected bytes", "contents is repeatable")
end
test_buffer_collects_writes()

local function test_buffer_round_trips_through_copy()
  local buf = stream.buffer()
  local copied = check.must(stream.copy(buf, stream.from_string("round trip")))
  check.equal(copied, 10, "copy reports the byte count")
  check.equal(buf:contents(), "round trip", "from_string -> buffer round-trips")
end
test_buffer_round_trips_through_copy()
