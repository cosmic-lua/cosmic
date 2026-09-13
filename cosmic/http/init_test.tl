#!/usr/bin/env cosmic
--- requires: loopback-listen
--- Server tests for cosmic.http, driven over a real loopback socket.
--- A forked child runs `serve_one` on one accepted connection and the
--- parent is the client, writing raw request bytes and reading raw
--- response bytes back: framing is the thing under test, so nothing
--- between the two is allowed to normalize it away.
local check = require("cosmic.check")
local html = require("cosmic.html")
local http = require("cosmic.http")
local net = require("cosmic.net")
local proc = require("cosmic.proc")
local time = require("cosmic.time")

--- Start a server on an ephemeral loopback port and fork a child that
--- serves exactly one connection with handler.
--- @param handler http.Handler The handler the child serves with
--- @param opts http.ListenOptions? Server limits for the child
--- @return integer The port the server bound
--- @return integer The child's pid
local function fork_serve(handler: http.Handler, opts?: http.ListenOptions): integer, integer
  local srv = check.must(http.listen("127.0.0.1", 0, opts))
  local port = srv:port()
  local pid = check.must(proc.fork())
  if pid == 0 then
    local _ok, _err = srv:serve_one(handler)
    os.exit(0)
  end
  assert(srv:close())
  return port, pid
end

--- Read exactly one response: the head, then the Content-Length bytes
--- behind it. Whatever arrived past that is the next response and comes
--- back too, so a pipelined pair is read in two calls.
--- @param conn net.Socket The client socket
--- @param pending string Bytes already read past the previous response
--- @return string The response bytes, head and body
--- @return string Bytes read past this response
local function read_response(conn: net.Socket, pending: string): string, string
  local buf = pending
  local head_end = 0
  while head_end == 0 do
    local at = buf:find("\r\n\r\n", 1, true)
    if at then
      head_end = at
    else
      local chunk = conn:recv(4096)
      if chunk == nil then
        return buf, ""
      end
      buf = buf .. chunk
    end
  end
  local head = buf:sub(1, head_end + 3)
  local declared = head:match("\r\n[Cc]ontent%-[Ll]ength: (%d+)\r\n")
  local total = #head + (math.tointeger(tonumber(declared)) or 0)
  while #buf < total do
    local chunk = conn:recv(4096)
    if chunk == nil then
      break
    end
    buf = buf .. chunk
  end
  return buf:sub(1, total), buf:sub(total + 1)
end

--- Read every byte the server sends until it closes. The framing tests
--- that assert about what is NOT on the wire need the raw stream rather
--- than a reader that already believes the server's `Content-Length`.
--- @param conn net.Socket The client socket
--- @return string Everything the server wrote before closing
local function drain(conn: net.Socket): string
  local buf = ""
  while true do
    local chunk = conn:recv(4096)
    if chunk == nil then
      return buf
    end
    buf = buf .. chunk
  end
end

--- Whether text ends with suffix — the shape most of these assertions
--- want, since a response body is the tail of the bytes read.
--- @param text string The bytes to look at
--- @param suffix string The expected tail
--- @return boolean True when text ends with suffix
local function ends_with(text: string, suffix: string): boolean
  return text:sub(-#suffix) == suffix
end

--- Dial the server, write raw bytes, then stop writing, so the server's
--- keep-alive loop ends at end of stream rather than at its timeout.
--- @param port integer The server port
--- @param raw string The request bytes to write
--- @return net.Socket The connected client socket
local function say(port: integer, raw: string): net.Socket
  local conn = check.must(net.dial("127.0.0.1", port))
  assert(conn:send_all(raw))
  assert(conn:shutdown(net.SHUT_WR))
  return conn
end

--- Dial and write, keeping the write half OPEN: the connection may then
--- only end because the SERVER closed it, which is what the tests about
--- closing assert. The read timeout is what turns a server that wrongly
--- held the connection into a failure rather than a hang.
--- @param port integer The server port
--- @param raw string The request bytes to write
--- @return net.Socket The connected client socket
local function ask(port: integer, raw: string): net.Socket
  local conn = check.must(net.dial("127.0.0.1", port))
  assert(conn:set_timeout_ms(3000))
  assert(conn:send_all(raw))
  return conn
end

--- Assert the server closed: recv reports end of stream (bare nil, no
--- error), not a read timeout and not more bytes.
--- @param conn net.Socket The client socket
local function assert_closed(conn: net.Socket)
  local rest, err = conn:recv(64)
  assert(rest == nil and err == nil,
    "expected the server to close, got: " .. tostring(rest) .. " / " .. tostring(err))
end

local function test_get_answers_with_body_and_length()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local _ok, _err = res:text("hi " .. req.path)
    end)
  local conn = say(port, "GET /x HTTP/1.1\r\nHost: localhost\r\n\r\n")
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 200 OK\r\n"), resp)
  assert(resp:find("Content-Length: 5\r\n", 1, true), resp)
  assert(resp:find("Content-Type: text/plain; charset=utf-8\r\n", 1, true), resp)
  assert(resp:find("Date: ", 1, true), resp)
  assert(ends_with(resp, "hi /x"), resp)
end

local function test_query_and_headers_reach_the_handler()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local answer = req.method .. " " .. req.path
      .. " a=" .. table.concat(req.query["a"] or {}, ",")
      .. " host=" .. tostring(req:header("HOST"))
      local _ok, _err = res:text(answer)
    end)
  local conn = say(port, "GET /p/q?a=1&a=2 HTTP/1.1\r\nHost: example\r\n\r\n")
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(ends_with(resp, "GET /p/q a=1,2 host=example"), resp)
end

local function test_keep_alive_answers_two_requests_in_order()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local _ok, _err = res:text("body" .. req.path)
    end)
  local conn = say(port,
    "GET /1 HTTP/1.1\r\nHost: h\r\n\r\n" ..
    "GET /2 HTTP/1.1\r\nHost: h\r\n\r\n")
  local first, rest = read_response(conn, "")
  local second = read_response(conn, rest)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(ends_with(first, "body/1"), first)
  assert(first:find("Connection: keep-alive\r\n", 1, true), first)
  assert(second:find("^HTTP/1.1 200 OK\r\n"), second)
  assert(ends_with(second, "body/2"), second)
end

local function test_fragmented_head_is_resumed()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local _ok, _err = res:text(req.method .. req.path .. tostring(req:header("x-trace")))
    end)
  local conn = check.must(net.dial("127.0.0.1", port))
  local raw = "GET /frag HTTP/1.1\r\nHost: localhost\r\nX-Trace: abc\r\n\r\n"
  for i = 1, #raw, 4 do
    assert(conn:send_all(raw:sub(i, i + 3)))
    -- A pause per fragment so the server really does see a partial head:
    -- without it the kernel coalesces the writes into one recv and the
    -- resume path is never taken.
    assert(time.sleep_ms(2))
  end
  assert(conn:shutdown(net.SHUT_WR))
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(ends_with(resp, "GET/fragabc"), resp)
end

local function test_post_body_is_read_exactly()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local body = req:body()
      local _ok, _err = res:text("[" .. tostring(body) .. "]")
    end)
  -- The second request is pipelined behind the first body: answering it
  -- proves the server consumed exactly Content-Length bytes and no more.
  -- The length is written with the optional whitespace a field value may
  -- carry, which the parser strips: reading the body at all proves the
  -- 1*DIGIT guard refuses spellings of a length, not a padded legal one.
  local conn = say(port,
    "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length:  5 \r\n\r\nhello" ..
    "GET /after HTTP/1.1\r\nHost: h\r\n\r\n")
  local first, rest = read_response(conn, "")
  local second = read_response(conn, rest)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(ends_with(first, "[hello]"), first)
  assert(ends_with(second, "[]"), second)
end

local function test_oversize_body_is_refused_with_413()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("never")
    end, {max_body_bytes = 8})
  -- No body is sent at all: the refusal is on the declared length.
  local conn = say(port, "POST /big HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\n")
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 413 "), resp)
  assert(resp:find("Connection: close\r\n", 1, true), resp)
end

local function test_empty_chunked_request_body_reads_as_empty()
  -- A chunked request that frames no payload at all is a body of zero
  -- bytes, not a missing one; the handler runs and reads "".
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local body = req:body()
      local _ok, _err = res:text("len=" .. #tostring(body))
    end)
  local conn = say(port,
    "POST /c HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 200 OK\r\n"), resp)
  assert(ends_with(resp, "len=0"), resp)
end

local function test_oversize_head_is_refused_with_431()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("never")
    end, {max_head_bytes = 64})
  local conn = say(port,
    "GET /long HTTP/1.1\r\nHost: h\r\nX-Pad: " .. string.rep("x", 400) .. "\r\n\r\n")
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 431 "), resp)
end

local function test_garbage_is_refused_with_400_and_closed()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("never")
    end)
  local conn = ask(port, "@@@@ not http at all\r\n\r\n")
  local resp, rest = read_response(conn, "")
  assert(rest == "", "trailing bytes after a 400: " .. rest)
  assert_closed(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 400 "), resp)
  assert(resp:find("Connection: close\r\n", 1, true), resp)
end

local function test_http_1_0_gets_connection_close()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("ten")
    end)
  local conn = ask(port, "GET / HTTP/1.0\r\n\r\n")
  local resp = read_response(conn, "")
  assert_closed(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 200 OK\r\n"), resp)
  assert(resp:find("Connection: close\r\n", 1, true), resp)
  assert(not resp:find("keep-alive", 1, true), resp)
end

local function test_client_connection_close_ends_the_conversation()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("once")
    end)
  local conn = ask(port, "GET /1 HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
  local resp = read_response(conn, "")
  assert_closed(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("Connection: close\r\n", 1, true), resp)
  assert(ends_with(resp, "once"), resp)
end

local function test_throwing_handler_is_500_and_the_connection_survives()
  local answered = 0
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      answered = answered + 1
      if answered == 1 then
        error("handler exploded")
      end
      local _ok, _err = res:text("second")
    end)
  local conn = say(port,
    "GET /boom HTTP/1.1\r\nHost: h\r\n\r\n" ..
    "GET /next HTTP/1.1\r\nHost: h\r\n\r\n")
  local first, rest = read_response(conn, "")
  local second = read_response(conn, rest)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(first:find("^HTTP/1.1 500 "), first)
  assert(first:find("Content-Length: 0\r\n", 1, true), first)
  assert(second:find("^HTTP/1.1 200 OK\r\n"), second)
  assert(ends_with(second, "second"), second)
end

local function test_handler_that_sends_nothing_is_500()
  local port, pid = fork_serve(function(_req: http.Request, _res: http.Response)
    end)
  local conn = say(port, "GET /silent HTTP/1.1\r\nHost: h\r\n\r\n")
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 500 "), resp)
  assert(resp:find("Content-Length: 0\r\n", 1, true), resp)
end

local function test_html_sends_safe_markup()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:html(html.safe("<b>me & you</b>"))
    end)
  local conn = say(port, "GET /h HTTP/1.1\r\nHost: h\r\n\r\n")
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("Content-Type: text/html; charset=utf-8\r\n", 1, true), resp)
  assert(ends_with(resp, html.escape("<b>me & you</b>")), resp)
end

local function test_json_and_redirect()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      if req.path == "/j" then
        local _ok, _err = res:json({ok = true})
      else
        local _ok, _err = res:redirect("/j")
      end
    end)
  local conn = say(port,
    "GET /j HTTP/1.1\r\nHost: h\r\n\r\n" ..
    "GET /r HTTP/1.1\r\nHost: h\r\n\r\n")
  local first, rest = read_response(conn, "")
  local second = read_response(conn, rest)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(first:find("Content-Type: application/json\r\n", 1, true), first)
  assert(first:find('"ok"', 1, true), first)
  assert(second:find("^HTTP/1.1 303 See Other\r\n"), second)
  assert(second:find("Location: /j\r\n", 1, true), second)
  assert(second:find("Content-Length: 0\r\n", 1, true), second)
end

local function test_status_and_custom_headers()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      res.status = 404
      res:set_header("X-One", "first")
      res:set_header("X-One", "second")
      res:add_header("X-Many", "a")
      res:add_header("X-Many", "b")
      local _ok, _err = res:text("gone")
    end)
  local conn = say(port, "GET /nope HTTP/1.1\r\nHost: h\r\n\r\n")
  local resp = read_response(conn, "")
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 404 Not Found\r\n"), resp)
  assert(not resp:find("X-One: first", 1, true), resp)
  assert(resp:find("X-One: second\r\n", 1, true), resp)
  assert(resp:find("X-Many: a\r\n", 1, true), resp)
  assert(resp:find("X-Many: b\r\n", 1, true), resp)
end

local function test_crlf_in_a_redirect_target_never_splits_the_response()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local _ok, _err = res:redirect((req.query["next"] or {"/"})[1])
    end)
  -- The query decodes to a real CRLF: a server that wrote it would hand
  -- the client a header line, a blank line and a body of its choosing.
  local conn = say(port,
    "GET /r?next=%2Fhome%0d%0aX-Evil%3A%20injected%0d%0a%0d%0aPWNED HTTP/1.1\r\n"
    .. "Host: h\r\n\r\n")
  local stream = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(stream:find("^HTTP/1.1 500 "), stream)
  assert(not stream:find("X-Evil", 1, true), stream)
  assert(not stream:find("PWNED", 1, true), stream)
  assert(not stream:find("Location", 1, true), stream)
  -- A refused header sends nothing, so the only bytes here are the
  -- server's own head: the blank line that ends it ends the stream.
  assert(stream:find("\r\n\r\n", 1, true) == #stream - 3, stream)
end

local function test_crlf_in_a_header_name_or_value_is_refused_not_stripped()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      -- Both entry points, and both halves of a header: a CRLF in the
      -- NAME splits a response exactly as one in the value does.
      res:add_header("X-Nope\r\nX-Evil-Name: one", "v")
      res:set_header("X-Try", "ok\r\nX-Evil-Value: two")
      local _ok, _err = res:text("body-bytes")
    end)
  local conn = say(port, "GET /s HTTP/1.1\r\nHost: h\r\n\r\n")
  local stream = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(stream:find("^HTTP/1.1 500 "), stream)
  assert(not stream:find("X-Evil", 1, true), stream)
  -- Refused, not sanitized: no part of any refused header appears, and
  -- the send they poisoned put none of its body on the wire either.
  assert(not stream:find("X-Nope", 1, true), stream)
  assert(not stream:find("X-Try", 1, true), stream)
  assert(not stream:find("body-bytes", 1, true), stream)
end

local function test_non_decimal_content_length_is_refused_with_400()
  -- RFC 9110 §8.6 makes Content-Length 1*DIGIT; every one of these is a
  -- length Lua's tonumber would read and an intermediary might not.
  for _, declared in ipairs({"0x5", "0x1p4", "1e2", "10.0", "+5"}) do
    local port, pid = fork_serve(function(req: http.Request, res: http.Response)
        local _ok, _err = res:text("[" .. tostring((req:body())) .. "]")
      end)
    -- A whole second request pipelined behind the five body bytes: a
    -- server that accepted the length would answer it too, which is the
    -- framing disagreement this refuses.
    local conn = ask(port,
      "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: " .. declared .. "\r\n\r\n"
      .. "AAAAAGET /second HTTP/1.1\r\nHost: h\r\n\r\n")
    local resp, rest = read_response(conn, "")
    assert_closed(conn)
    assert(conn:close())
    assert(proc.wait(pid))

    assert(resp:find("^HTTP/1.1 400 "), declared .. ": " .. resp)
    assert(rest == "", declared .. ": bytes past the 400: " .. rest)
  end
end

local function test_head_sends_no_body_and_the_next_request_is_answered()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("hi")
    end)
  local conn = say(port,
    "HEAD /h HTTP/1.1\r\nHost: h\r\n\r\n" ..
    "GET /g HTTP/1.1\r\nHost: h\r\n\r\n")
  local stream = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  local at = stream:find("\r\n\r\n", 1, true)
  assert(at, stream)
  local head, rest = stream:sub(1, at + 3), stream:sub(at + 4)
  assert(head:find("^HTTP/1.1 200 OK\r\n"), head)
  -- Content-Length reports what a GET would have sent...
  assert(head:find("Content-Length: 2\r\n", 1, true), head)
  assert(head:find("Connection: keep-alive\r\n", 1, true), head)
  -- ...and the byte after the head is the NEXT response's status line,
  -- not the body a conforming client would never read.
  assert(rest:find("^HTTP/1.1 200 OK\r\n"), "HEAD leaked a body: " .. rest)
  assert(ends_with(rest, "hi"), rest)
end
