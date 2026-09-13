#!/usr/bin/env cosmic
--- requires: loopback-listen
--- Streaming tests for cosmic.http: chunked request bodies in, chunked
--- and SSE responses out, and the framing a handler is not allowed to
--- declare for itself.
---
--- The request side is driven over a raw socket, because the framing is
--- the thing under test and a client that already understands chunked
--- would hide a server that does not. The response side is read back
--- through `cosmic.fetch`, which is a real HTTP/1.1 client: what it
--- reconstructs is the proof that the bytes on the wire were framed the
--- way a client expects.
local check = require("cosmic.check")
local fetch = require("cosmic.fetch")
local http = require("cosmic.http")
local net = require("cosmic.net")
local proc = require("cosmic.proc")
local sse = require("cosmic.sse")
local time = require("cosmic.time")

--- Bind an ephemeral loopback port, then hand the accept loop to a
--- forked child so the parent is free to be the client.
--- @param handler http.Handler The handler the child answers with
--- @param opts http.ListenOptions? Limits the child server runs under
--- @return integer The bound port
--- @return integer The pid to wait on once the exchange is over
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

--- Read every byte the server sends until it closes.
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

--- Dial the server and write raw bytes in pieces, pausing between them
--- so the server really does see a fragmented body rather than one
--- recv the kernel coalesced.
--- @param port integer The server port
--- @param parts {string} The request bytes, in the order to write them
--- @return net.Socket The connected client socket
local function say_parts(port: integer, parts: {string}): net.Socket
  local conn = check.must(net.dial("127.0.0.1", port))
  assert(conn:set_timeout_ms(3000))
  for i, part in ipairs(parts) do
    if i > 1 then
      assert(time.sleep_ms(5))
    end
    assert(conn:send_all(part))
  end
  assert(conn:shutdown(net.SHUT_WR))
  return conn
end

local CHUNKED_HEAD = "POST /in HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"

local function test_chunked_request_body_split_across_three_sends()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local body, berr = req:body()
      local _ok, _err = res:text("[" .. tostring(body) .. "] " .. tostring(berr))
    end)
  local conn = say_parts(port, {
      CHUNKED_HEAD .. "5\r\nhello",
      "\r\n6\r\n world",
      "\r\n0\r\n\r\n",
    })
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 200 OK\r\n"), resp)
  assert(resp:find("[hello world] nil", 1, true), resp)
end

local function test_chunked_body_carry_over_is_the_next_request()
  -- The bytes behind the terminating chunk are the next head, and the
  -- keep-alive loop has to answer from them rather than drop them.
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      local body = req:body()
      local _ok, _err = res:text(req.path .. "=" .. tostring(body))
    end)
  local conn = say_parts(port, {
      CHUNKED_HEAD .. "3\r\nabc\r\n0\r\n\r\n" ..
      "GET /second HTTP/1.1\r\nHost: h\r\n\r\n",
    })
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("/in=abc", 1, true), resp)
  assert(resp:find("/second=", 1, true), "the pipelined second request was lost: " .. resp)
end

local function test_oversize_chunked_body_is_refused_with_413()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("handler should not have run")
    end, {max_body_bytes = 16})
  local big = string.rep("x", 64)
  local conn = say_parts(port, {
      CHUNKED_HEAD .. string.format("%x\r\n", #big) .. big .. "\r\n0\r\n\r\n",
    })
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 413 "), resp)
  assert(resp:find("handler should not have run", 1, true) == nil, resp)
end

local function test_pathological_tiny_chunks_trip_the_raw_byte_bound()
  -- The DECODED payload can stay tiny while the RAW framing balloons: a
  -- stream of one-byte chunks is almost entirely "1\r\nX\r\n" overhead. The
  -- raw-byte bound only re-checks on a feed that does not finish the
  -- body, so the chunks are drip-fed one at a time — never sending the
  -- terminating "0\r\n\r\n" — rather than as one write that would let the
  -- decoded-payload check alone decide the outcome.
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("handler should not have run")
    end, {max_body_bytes = 64})
  local parts: {string} = {CHUNKED_HEAD}
  for _ = 1, 13 do
    table.insert(parts, "1\r\nX\r\n")
  end
  local conn = say_parts(port, parts)
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  -- 13 chunks decode to 13 payload bytes — well under the 64-byte bound
  -- — but cost 78 raw bytes of framing, which is what trips the refusal.
  assert(resp:find("^HTTP/1.1 413 "), resp)
  assert(resp:find("handler should not have run", 1, true) == nil, resp)
end

local function test_chunked_body_beside_content_length_is_refused()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local _ok, _err = res:text("handler should not have run")
    end)
  local conn = say_parts(port, {
      "POST /in HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n"
      .. "Transfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
    })
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("^HTTP/1.1 400 "), resp)
end

local function test_written_chunks_read_back_as_their_concatenation()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      assert(res:start())
      for _, piece in ipairs({"one ", "two ", "three"}) do
        assert(res:write(piece))
      end
      -- A zero-length write is a no-op, never the terminating chunk:
      -- the pieces after it must still arrive.
      assert(res:write(""))
      assert(res:write("!"))
      assert(res:finish())
    end)
  local result = check.must(fetch.stream("http://127.0.0.1:" .. port .. "/s",
      {allow_private = true}))
  local pieces: {string} = {}
  while true do
    local chunk, err = result.reader:read()
    assert(err == nil, "no read error expected, got: " .. tostring(err))
    if not chunk then
      break
    end
    table.insert(pieces, chunk)
  end
  assert(proc.wait(pid))

  assert(result.status == 200, "status should be 200")
  assert(table.concat(pieces) == "one two three!",
    "streamed body should arrive whole, got: " .. table.concat(pieces))
end

local function test_sse_events_round_trip_through_sse_parse()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      assert(res:event({data = "first", event = "tick", id = "1"}))
      assert(res:event({data = "second\nline", event = "tick", id = "2"}))
      assert(res:finish())
    end)
  local result = check.must(fetch.stream("http://127.0.0.1:" .. port .. "/events",
      {allow_private = true}))
  local events = sse.parse(result.reader)
  local got: {sse.Event} = {}
  while true do
    local ev = events:next()
    if ev then
      table.insert(got, ev)
    else
      break
    end
  end
  assert(proc.wait(pid))

  assert(result.headers["content-type"] == "text/event-stream",
    "content-type should be text/event-stream, got: "
    .. tostring(result.headers["content-type"]))
  assert(result.headers["cache-control"] == "no-cache",
    "cache-control should be no-cache, got: "
    .. tostring(result.headers["cache-control"]))
  assert(#got == 2, "expected two events, got " .. #got)
  assert(got[1].data == "first" and got[1].event == "tick" and got[1].id == "1",
    "first event did not round-trip: " .. tostring(got[1].data))
  assert(got[2].data == "second\nline" and got[2].event == "tick"
    and got[2].id == "2", "second event did not round-trip: " .. tostring(got[2].data))
end

local function test_handler_may_not_declare_transfer_encoding_itself()
  -- A `send` response is framed by the Content-Length the server
  -- counted. A Transfer-Encoding beside it is RFC 9112 §6.1's two
  -- framings on one message, so the handler's header is dropped rather
  -- than written, exactly as Content-Length and Connection already are.
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      res:set_header("Transfer-Encoding", "chunked")
      local _ok, _err = res:text("body")
    end)
  local conn = say_parts(port, {"GET / HTTP/1.1\r\nHost: h\r\n\r\n"})
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("Content-Length: 4\r\n", 1, true), resp)
  assert(resp:lower():find("transfer%-encoding") == nil,
    "a send response must not carry Transfer-Encoding: " .. resp)
end

local function test_send_after_start_writes_nothing()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      assert(res:start())
      assert(res:write("streamed"))
      local ok, err = res:send("second head")
      assert(ok == false, "send after start must fail")
      assert(err == "http: response already started", "got: " .. tostring(err))
      assert(res:finish())
    end)
  local result = check.must(fetch.stream("http://127.0.0.1:" .. port .. "/s",
      {allow_private = true}))
  local pieces: {string} = {}
  while true do
    local chunk = result.reader:read()
    if not chunk then
      break
    end
    table.insert(pieces, chunk)
  end
  assert(proc.wait(pid))

  assert(table.concat(pieces) == "streamed",
    "the refused send must reach no bytes: " .. table.concat(pieces))
end

local function test_write_and_finish_refuse_an_unstarted_response()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      local wok, werr = res:write("x")
      local fok, ferr = res:finish()
      local _ok, _err = res:text(tostring(wok) .. " " .. werr
        .. " / " .. tostring(fok) .. " " .. ferr)
    end)
  local conn = say_parts(port, {"GET / HTTP/1.1\r\nHost: h\r\n\r\n"})
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("false http: response not started / false http: response not started",
      1, true), resp)
end

local function test_http_10_stream_is_framed_by_the_close()
  -- No chunked encoding exists before HTTP/1.1, so the body is framed
  -- by the connection ending and the head has to say so.
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      assert(res:start())
      assert(res:write("aa"))
      assert(res:write("bb"))
      assert(res:finish())
    end)
  local conn = say_parts(port, {"GET / HTTP/1.0\r\nHost: h\r\n\r\n"})
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("Connection: close\r\n", 1, true), resp)
  assert(resp:lower():find("transfer%-encoding") == nil,
    "HTTP/1.0 has no chunked encoding to announce: " .. resp)
  assert(resp:lower():find("content%-length") == nil, resp)
  -- The raw bytes, with no chunk headers between them and no terminator.
  assert(resp:sub(-4) == "aabb", resp)
end

local function test_chunked_stream_keeps_the_connection_alive()
  local port, pid = fork_serve(function(req: http.Request, res: http.Response)
      assert(res:start())
      assert(res:write(req.path))
      assert(res:finish())
    end)
  local conn = say_parts(port, {
      "GET /one HTTP/1.1\r\nHost: h\r\n\r\nGET /two HTTP/1.1\r\nHost: h\r\n\r\n",
    })
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  assert(resp:find("Transfer-Encoding: chunked\r\n", 1, true), resp)
  assert(resp:find("Connection: keep-alive\r\n", 1, true), resp)
  assert(resp:find("4\r\n/one\r\n0\r\n\r\n", 1, true), resp)
  assert(resp:find("4\r\n/two\r\n0\r\n\r\n", 1, true),
    "the connection should have carried a second streamed response: " .. resp)
end

local function test_unfinished_stream_closes_the_connection()
  -- Both requests arrive pipelined in one write, so the second request's
  -- bytes are already sitting in the connection's buffer when the first
  -- handler returns without finishing its stream. If the guard that
  -- closes the connection on an unfinished stream were gone, the loop
  -- would go on to parse and answer that second request too, writing a
  -- second status line into the still-open first response's body — the
  -- assertion below counts status lines rather than looking for "/two"
  -- in the body, because the corrupted framing would still not contain
  -- literal "/two" text (the handler never writes the path).
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      assert(res:start())
      assert(res:write("partial"))
    end)
  local conn = say_parts(port, {
      "GET /one HTTP/1.1\r\nHost: h\r\n\r\nGET /two HTTP/1.1\r\nHost: h\r\n\r\n",
    })
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  -- No terminator was written, so nothing may follow the open body: a
  -- second response here would be read as more of the first one.
  assert(resp:find("7\r\npartial\r\n", 1, true), resp)
  local status_lines = 0
  local at = 1
  while true do
    local found = resp:find("HTTP/1.1 200 OK", at, true)
    if not found then
      break
    end
    status_lines = status_lines + 1
    at = found + 1
  end
  assert(status_lines == 1,
    "an unterminated stream must not be followed by another response, "
    .. "got " .. status_lines .. " status lines: " .. resp)
end

local function test_head_request_streams_no_body()
  local port, pid = fork_serve(function(_req: http.Request, res: http.Response)
      assert(res:start())
      assert(res:write("never sent"))
      assert(res:finish())
    end)
  local conn = say_parts(port, {
      "HEAD /h HTTP/1.1\r\nHost: h\r\n\r\nGET /g HTTP/1.1\r\nHost: h\r\n\r\n",
    })
  local resp = drain(conn)
  assert(conn:close())
  assert(proc.wait(pid))

  -- The HEAD answer reports the framing a GET would have used...
  local at = check.must((resp:find("\r\n\r\n", 1, true)))
  local head, rest = resp:sub(1, at + 3), resp:sub(at + 4)
  assert(head:find("Transfer-Encoding: chunked\r\n", 1, true), head)
  -- ...and sends none of it, not even the terminating chunk: that is
  -- body framing too, so the byte after the head is the NEXT response's
  -- status line rather than something a client would read as content.
  assert(rest:find("^HTTP/1.1 200 OK\r\n"), "HEAD leaked a body: " .. resp)
  -- The GET behind it is the control: the handler really did write.
  assert(rest:find("a\r\nnever sent\r\n0\r\n\r\n", 1, true), rest)
end
