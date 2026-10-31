--- [`Server.serve`] on the worker's own loopback: a
--- client here writes a request's bytes as given and reads the reply as
--- sent, so what the server does on the wire is what is checked.

local Clock = require("cosmic.clock")
local Compress = require("cosmic.compress")
local Server = require("cosmic.http.server")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

--- A reply as a client read it.
local record Got
  status: integer
  --- By lowercased name.
  headers: {string:string}
  body: string
end

--- A client of the server: its connection, and what it has read and
--- not yet taken.
local record Peer
  conn: Net.Conn
  mut buf: string
  __close: function(Peer)
end

local peer_mt: metatable<Peer> = {
  __index = Peer,
  __close = function(self: Peer) local _, _ = self.conn:close() end,
}

local function peer(address: Net.Address): Peer
  local conn = assert(Net.connect(address, { timeout_ns = Clock.seconds(5) }))
  return setmetatable({ conn = conn, buf = "" }, peer_mt)
end

--- Reads more into `p.buf`: false at the connection's end.
local function more(p: Peer): boolean
  local piece, why = p.conn:read()
  if piece == nil then
    assert(why == "", "reading: " .. why)
    return false
  end
  p.buf = p.buf .. piece
  return true
end

--- The next `n` bytes.
local function bytes(p: Peer, n: integer): string
  while #p.buf < n do assert(more(p), "the connection ended within a body") end
  local out = p.buf:sub(1, n)
  p.buf = p.buf:sub(n + 1)
  return out
end

--- The next line, without its CRLF.
local function line(p: Peer): string
  while not p.buf:find("\r\n", 1, true) do assert(more(p), "the connection ended within a line") end
  local at = assert(p.buf:find("\r\n", 1, true))
  local out = p.buf:sub(1, at - 1)
  p.buf = p.buf:sub(at + 2)
  return out
end

--- The next reply, to a request of `method` ("GET" when nil).
local function reply(p: Peer, method?: string): Got
  local status_line = line(p)
  local status = math.tointeger(tonumber(status_line:match("^HTTP/1%.1 (%d%d%d) ")))
  assert(status ~= nil, "status line: " .. status_line)
  local headers: mut {string:string} = {}
  while true do
    local text = line(p)
    if text == "" then break end
    local name, value = text:match("^([^:]+): (.*)$")
    assert(name ~= nil and value ~= nil, "header line: " .. text)
    assert(headers[name:lower()] == nil, "repeated header " .. name)
    headers[name:lower()] = value
  end
  local body = ""
  if method == "HEAD" or status < 200 or status == 204 or status == 304 then
    body = ""
  elseif headers["content-length"] ~= nil then
    body = bytes(p, assert(math.tointeger(tonumber(headers["content-length"]))))
  elseif headers["transfer-encoding"] == "chunked" then
    local parts: mut {string} = {}
    while true do
      local size = assert(math.tointeger(tonumber(line(p), 16)))
      if size == 0 then break end
      parts[#parts + 1] = bytes(p, size)
      assert(line(p) == "")
    end
    assert(line(p) == "")
    body = table.concat(parts)
  else
    while more(p) do end
    body, p.buf = p.buf, ""
  end
  return { status = status, headers = headers, body = body }
end

--- Whether the server has closed the connection, all it sent read.
local function ended(p: Peer): boolean
  if p.buf ~= "" then return false end
  local piece, why = p.conn:read()
  return piece == nil and why == ""
end

--- Whether the connection has ended with nothing more sent to read,
--- by an end of stream or a reset: a server closing with part of a body
--- unread may do either.
local function vanished(p: Peer): boolean
  if p.buf ~= "" then return false end
  local piece, _ = p.conn:read()
  return piece == nil
end

local function send(p: Peer, data: string)
  assert(p.conn:write(data))
end

--- The fields of a [`Server.ServeSpec`] that a test changes: `serving` supplies the rest.
local record Tuning
  limits?: Server.ServeSpec.Limits
  timeout_ns?: integer
  idle_ns?: integer
  head_ns?: integer
  body_ns?: integer
  compress?: boolean | Server.Compression
  on_stop?: function(server: Net.Server)
end

--- Runs a server of `handle` (and `tuning`'s fields) on the loopback
--- at a port the kernel chooses, running `client` with its address once it listens,
--- and stops it once `client` returns. Answers what went to on_error.
local function serving(handle: function(Server.Request): Server.Reply,
                       client: function(Net.Address), tuning?: Tuning): {string}
  local troubles: mut {string} = {}
  local chosen: Tuning = tuning or {}
  local given: Server.ServeSpec = {
    handle = handle,
    listeners = { Net.tcp("127.0.0.1", 0) },
    limits = chosen.limits,
    timeout_ns = chosen.timeout_ns,
    idle_ns = chosen.idle_ns,
    head_ns = chosen.head_ns,
    body_ns = chosen.body_ns,
    compress = chosen.compress,
    on_stop = chosen.on_stop,
  }
  given.on_error = function(trouble: string) troubles[#troubles + 1] = trouble end
  given.on_ready = function(addresses: {Net.Address}, server: Net.Server)
    local listening = assert(addresses[1], "the server listens")
    client(listening)
    server:stop()
  end
  assert(Server.serve(given))
  return troubles
end

--- Answers each request with its method, path and query.
local function echo(req: Server.Request): Server.Reply
  local body = assert(Stream.read_all(req.body))
  return { status = 200, headers = { ["Content-Type"] = "text/plain" },
    body = req.method .. " " .. req.path .. " " .. req.query .. " " .. body }
end

--- The `i`th trouble the server reported.
local function trouble_at(troubles: {string}, i: integer): string
  local found = troubles[i]
  assert(found, "expected trouble " .. tostring(i))
  return found
end

local function get(path: string, extra?: string): string
  return "GET " .. path .. " HTTP/1.1\r\nHost: test\r\n" .. (extra or "") .. "\r\n"
end

--- Requests pipelined in one write are answered in order on one
--- connection, which stays open for another after them; each reply
--- carries a Date and its Content-Length, and no Connection header.
local function test_pipelined_requests_are_answered_in_order_on_one_connection()
  local troubles = serving(echo, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, get("/a?x=1") .. get("/b") ..
        "PUT /c HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n\r\nabc")
    local first, second, third = reply(p), reply(p), reply(p)
    assert(first.status == 200 and first.body == "GET /a x=1 ", first.body)
    assert(second.body == "GET /b  ", second.body)
    assert(third.body == "PUT /c  abc", third.body)
    assert(first.headers["content-length"] == tostring(#first.body))
    local date = assert(first.headers["date"], "expected a Date header")
    assert(date:find(" GMT$") ~= nil, date)
    assert(first.headers["connection"] == nil)
    assert(first.headers["content-type"] == "text/plain")
    send(p, get("/d"))
    assert(reply(p).body == "GET /d  ")
  end)
  assert(#troubles == 0, troubles[1])
end

--- `Connection: close` from the client, `close` in a reply, and an
--- HTTP/1.0 request each end the connection after their reply, which
--- says so.
local function test_a_connection_closes_where_either_side_asks()
  serving(function(req: Server.Request): Server.Reply
    return { status = 200, body = "ok", close = req.path == "/bye" }
  end, function(address: Net.Address)
    for _, request in ipairs({ get("/", "Connection: close\r\n"), get("/bye"),
        "GET / HTTP/1.0\r\n\r\n" }) do
      local p <close> = peer(address)
      send(p, request .. get("/never"))
      local got = reply(p)
      assert(got.status == 200 and got.body == "ok")
      assert(got.headers["connection"] == "close", request)
      assert(ended(p), request)
    end
  end)
end

--- A HEAD is answered with the head a GET would have, its
--- Content-Length included, and no body: the next reply on the
--- connection follows at once. A Reader body is closed unread.
local function test_head_is_answered_with_no_body()
  local read_from: boolean = false
  local closed: boolean = false
  local record Watched is Stream.Reader
    read: function(Watched, max_bytes?: integer): string?, string
    close: function(Watched): boolean, string
  end
  local watched: Watched = setmetatable({}, { __index = {
    read = function(_self: Watched, _max_bytes?: integer): string?, string
      read_from = true
      return nil, ""
    end,
    close = function(_self: Watched): boolean, string
      closed = true
      return true, ""
    end,
  } })
  serving(function(req: Server.Request): Server.Reply
    if req.path == "/reader" then return { status = 200, body = watched, length = 42 } end
    return { status = 200, body = "hello" }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "HEAD / HTTP/1.1\r\nHost: test\r\n\r\n" .. "HEAD /reader HTTP/1.1\r\nHost: test\r\n\r\n" ..
        get("/"))
    local head = reply(p, "HEAD")
    assert(head.status == 200 and head.headers["content-length"] == "5")
    local of_reader = reply(p, "HEAD")
    assert(of_reader.headers["content-length"] == "42")
    local after = reply(p)
    assert(after.body == "hello", after.body)
  end)
  assert(closed and not read_from)
end

--- A chunked request body is decoded, its extensions and trailers
--- dropped; a Reader reply without a length goes chunked to HTTP/1.1,
--- and to HTTP/1.0 until the connection closes.
local function test_chunked_bodies_both_ways()
  serving(function(req: Server.Request): Server.Reply
    if req.path == "/stream" then
      return { status = 200, body = Stream.from_string(string.rep("z", 70000)) }
    end
    local body = assert(Stream.read_all(req.body))
    assert(req.length == nil)
    return { status = 200, body = body }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "POST / HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ..
        "5;name=value\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\nTrailer: x\r\n\r\n")
    local echoed = reply(p)
    assert(echoed.body == "hello world", echoed.body)
    send(p, get("/stream"))
    local streamed = reply(p)
    assert(streamed.headers["transfer-encoding"] == "chunked")
    assert(streamed.headers["content-length"] == nil)
    assert(streamed.body == string.rep("z", 70000))
    local old <close> = peer(address)
    send(old, "GET /stream HTTP/1.0\r\n\r\n")
    local whole = reply(old)
    assert(whole.headers["transfer-encoding"] == nil and whole.headers["connection"] == "close")
    assert(whole.body == string.rep("z", 70000), tostring(#whole.body))
  end)
end

--- `Expect: 100-continue` is answered `100 Continue` when the handler
--- first reads the body, and only then; a declared body past the
--- limit is refused at once, with no 100; and a handler that never
--- reads it closes the connection after its reply, since the client
--- may never send it.
local function test_100_continue()
  serving(function(req: Server.Request): Server.Reply
    if req.path == "/ignore" then return { status = 200, body = "ignored" } end
    return { status = 200, body = assert(Stream.read_all(req.body)) }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "PUT / HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n")
    assert(line(p) == "HTTP/1.1 100 Continue")
    assert(line(p) == "")
    send(p, "data")
    assert(reply(p).body == "data")
    local big <close> = peer(address)
    send(big, "PUT / HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nContent-Length: 2000000\r\n\r\n")
    local refused = reply(big)
    assert(refused.status == 413 and refused.headers["connection"] == "close")
    local ignored <close> = peer(address)
    send(ignored, "PUT /ignore HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n")
    local got = reply(ignored)
    assert(got.status == 200 and got.body == "ignored")
    assert(got.headers["connection"] == "close")
  end)
end

--- Each limit is held: a head past head_bytes is 431, a Content-Length
--- past body_bytes 413 before the handler runs, a chunked body past it
--- 413 once read -- the handler's assert on the read reported nowhere
--- -- and a connection past `connections` waits until one closes.
local function test_each_limit_is_answered()
  local handled: integer = 0
  local troubles = serving(function(req: Server.Request): Server.Reply
    handled = handled + 1
    return { status = 200, body = assert(Stream.read_all(req.body)) }
  end, function(address: Net.Address)
    local long <close> = peer(address)
    send(long, get("/", "X-Long: " .. string.rep("a", 2000) .. "\r\n"))
    local got = reply(long)
    assert(got.status == 431 and got.headers["connection"] == "close", tostring(got.status))
    assert(ended(long))
    local big <close> = peer(address)
    send(big, "PUT / HTTP/1.1\r\nHost: test\r\nContent-Length: 101\r\n\r\n")
    assert(reply(big).status == 413)
    local chunked <close> = peer(address)
    send(chunked, "PUT / HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ..
        "50\r\n" .. string.rep("x", 80) .. "\r\n50\r\n" .. string.rep("y", 80) .. "\r\n0\r\n\r\n")
    local over = reply(chunked)
    assert(over.status == 413, tostring(over.status))
    assert(handled == 1, tostring(handled))
    -- One connection at a time: a second waits, unanswered.
    local first <close> = peer(address)
    send(first, get("/"))
    assert(reply(first).status == 200)
    local second <close> = peer(address)
    send(second, get("/"))
    second.conn:set_timeout(Clock.ms(100))
    local nothing, why = second.conn:read()
    assert(nothing == nil and why == Poll.TIMEOUT, why)
    second.conn:set_timeout(Clock.seconds(5))
    local _, _ = first.conn:close()
    assert(reply(second).status == 200)
  end, { limits = { head_bytes = 1024, body_bytes = 100, connections = 1 } })
  assert(#troubles == 0, troubles[1])
end

--- A handler that raises, or answers what is no reply the server can
--- send, is answered 500, the connection closed, and the trouble goes
--- to on_error: a raise with its stack.
local function test_a_failing_handler_is_answered_500()
  local bad: {string: any} = {
    ["/nil"] = nil,
    ["/owned"] = { status = 200, headers = { Date = "Thu, 01 Jan 1970 00:00:00 GMT" } },
    ["/unsent"] = { status = 200, headers = { ["Content-Length"] = "3" } },
    ["/mismatch"] = { status = 200, headers = { ["content-length"] = "4" }, body = "hello" },
    ["/cr"] = { status = 200, headers = { ["X-Bad"] = "a\r\nb" } },
    ["/nocontent"] = { status = 204, body = "not empty" },
    ["/interim"] = { status = 101 },
    ["/typo"] = { status = 200, header = {} },
    ["/crlist"] = { status = 200, headers = { ["Set-Cookie"] = { "a=1", "b=2\r\nX: y" } } },
    ["/lenlist"] = { status = 200, headers = { ["Content-Length"] = { "0" } } },
    ["/datelist"] = { status = 200, headers = { Date = { "x" } } },
    ["/numlist"] = { status = 200, headers = { ["Set-Cookie"] = { 1 } } },
  }
  local paths = { "/raise", "/nil", "/owned", "/cr", "/nocontent", "/interim", "/typo", "/unsent",
    "/mismatch", "/crlist", "/lenlist", "/datelist", "/numlist" }
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.path == "/raise" then error("the handler failed") end
    local answer: any = bad[req.path]
    return answer as Server.Reply
  end, function(address: Net.Address)
    for _, path in ipairs(paths) do
      local p <close> = peer(address)
      send(p, get(path))
      local got = reply(p)
      assert(got.status == 500, path .. ": " .. tostring(got.status))
      assert(got.headers["connection"] == "close", path)
      assert(ended(p), path)
    end
  end)
  assert(#troubles == #paths, tostring(#troubles))
  assert(trouble_at(troubles, 1):find("http: GET /raise: .*the handler failed") ~= nil, troubles[1])
  assert(trouble_at(troubles, 1):find("stack traceback", 1, true) ~= nil, troubles[1])
  assert(trouble_at(troubles, 2):find("not a Server.Reply", 1, true) ~= nil, troubles[2])
  assert(trouble_at(troubles, 3):find("Date: the server writes it itself", 1, true) ~= nil, troubles[3])
  assert(trouble_at(troubles, 4):find("CR, LF or NUL", 1, true) ~= nil, troubles[4])
  assert(trouble_at(troubles, 5):find("no body goes with status 204", 1, true) ~= nil, troubles[5])
  assert(trouble_at(troubles, 6):find("from 200 to 999", 1, true) ~= nil, troubles[6])
  assert(trouble_at(troubles, 7):find("no field header", 1, true) ~= nil, troubles[7])
  assert(trouble_at(troubles, 8):find("Content-Length is 3, but the reply has no body", 1, true) ~= nil, troubles[8])
  assert(trouble_at(troubles, 9):find("Content-Length is 4, but the body is 5 bytes", 1, true) ~= nil, troubles[9])
  assert(trouble_at(troubles, 10):find("CR, LF or NUL", 1, true) ~= nil, troubles[10])
  assert(trouble_at(troubles, 11):find("one value, not a list", 1, true) ~= nil, troubles[11])
  assert(trouble_at(troubles, 12):find("Date: the server writes it itself", 1, true) ~= nil, troubles[12])
  assert(trouble_at(troubles, 13):find("strings or lists of them", 1, true) ~= nil, troubles[13])
end

--- A handler may give a reply's Content-Length, under any case of its
--- name, as the body's size: it is sent once, the body framed by it. A
--- HEAD may be answered with the size alone, as a Content-Length or a
--- `length` and no body: the size is sent, and no bytes, so the next
--- reply on the connection follows at once.
local function test_a_handler_may_give_the_content_length()
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.path == "/match" then
      return { status = 200, headers = { ["content-length"] = "5" }, body = "hello" }
    elseif req.path == "/reader" then
      return { status = 200, headers = { ["CONTENT-LENGTH"] = "3" }, body = Stream.from_string("abc") }
    elseif req.path == "/length" then
      return { status = 200, length = 99 }
    end
    return { status = 200, headers = { ["Content-Type"] = "text/plain", ["Content-Length"] = "1234" } }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "HEAD /size HTTP/1.1\r\nHost: test\r\n\r\n" .. "HEAD /length HTTP/1.1\r\nHost: test\r\n\r\n" ..
        "HEAD /match HTTP/1.1\r\nHost: test\r\n\r\n" .. get("/match") .. get("/reader"))
    local size = reply(p, "HEAD")
    assert(size.status == 200 and size.headers["content-length"] == "1234", size.headers["content-length"])
    assert(size.headers["content-type"] == "text/plain")
    local length = reply(p, "HEAD")
    assert(length.status == 200 and length.headers["content-length"] == "99", length.headers["content-length"])
    local head = reply(p, "HEAD")
    assert(head.status == 200 and head.headers["content-length"] == "5", head.headers["content-length"])
    local matched = reply(p)
    assert(matched.status == 200 and matched.body == "hello", matched.body)
    local reader = reply(p)
    assert(reader.status == 200 and reader.body == "abc" and reader.headers["content-length"] == "3")
    assert(reader.headers["transfer-encoding"] == nil)
    assert(p.buf == "", p.buf)
  end)
  assert(#troubles == 0, troubles[1])
end

--- A reply's list header reaches the wire as one line per element, in
--- order: two cookies are two Set-Cookie lines, never one joined.
local function test_a_list_header_is_sent_as_one_line_per_element()
  local troubles = serving(function(_req: Server.Request): Server.Reply
    return { status = 200, headers = { ["Set-Cookie"] = { "a=1", "b=2" } }, body = "ok" }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n")
    while more(p) do end
    local first = p.buf:find("\r\nSet-Cookie: a=1\r\n", 1, true)
    local second = p.buf:find("\r\nSet-Cookie: b=2\r\n", 1, true)
    assert(first ~= nil and second ~= nil and first < second, p.buf)
    local _, lines = p.buf:gsub("\r\nSet%-Cookie:", "")
    assert(lines == 2, p.buf)
  end)
  assert(#troubles == 0, troubles[1])
end

--- A head sent slower than head_ns is answered 408 and closed, however
--- steadily its bytes come, and so is a body that stalls past
--- timeout_ns; a connection idle past idle_ns is closed.
local function test_a_slow_head_and_an_idle_connection_are_closed()
  serving(echo, function(address: Net.Address)
    local slow <close> = peer(address)
    local started = Clock.monotonic_ns()
    local request = get("/")
    for i = 1, #request do
      if not slow.conn:write(request:sub(i, i)) then break end
      local _, _ = Poll.delay(Clock.ms(20))
      if Clock.monotonic_ns() - started > Clock.seconds(2) then break end
    end
    local got = reply(slow)
    assert(got.status == 408, tostring(got.status))
    assert(Clock.monotonic_ns() - started < Clock.seconds(2))
    local stalled <close> = peer(address)
    send(stalled, "PUT / HTTP/1.1\r\nHost: test\r\nContent-Length: 10\r\n\r\nabc")
    local timed_out = reply(stalled)
    assert(timed_out.status == 408 and timed_out.headers["connection"] == "close", tostring(timed_out.status))
    local idle <close> = peer(address)
    local waited_from = Clock.monotonic_ns()
    assert(ended(idle))
    assert(Clock.monotonic_ns() - waited_from < Clock.seconds(2))
  end, { head_ns = Clock.ms(200), idle_ns = Clock.ms(200), timeout_ns = Clock.ms(200) })
end

--- Stopping closes a kept-alive connection idle at once, rather than
--- waiting out idle_ns, and a request in flight finishes with
--- `Connection: close`.
local function test_stopping_closes_idle_connections_at_once()
  local started = Clock.monotonic_ns()
  local idle_ended: boolean = false
  local in_flight: Got? = nil
  local release: boolean = false
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    idle_ns = Clock.seconds(60),
    handle = function(req: Server.Request): Server.Reply
      if req.path == "/slow" then
        while not release do assert(Poll.delay(Clock.ms(5))) end
      end
      return { status = 200, body = "ok" }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local listening = assert(addresses[1], "the server listens")
      local idle = peer(listening)
      send(idle, get("/"))
      assert(reply(idle).status == 200)
      local busy = peer(listening)
      send(busy, get("/slow"))
      assert(Poll.delay(Clock.ms(20)))
      Poll.spawn(function()
        idle_ended = ended(idle)
        release = true
        in_flight = reply(busy)
        assert(ended(busy))
      end)
      server:stop()
    end,
  })
  assert(idle_ended)
  local in_flight_value = in_flight
  assert(in_flight_value ~= nil, "the reply in flight never came")
  assert(in_flight_value.status == 200 and in_flight_value.headers["connection"] == "close")
  assert(Clock.monotonic_ns() - started < Clock.seconds(10))
end

--- A body the handler reads in part, or not at all, is dropped before
--- the next request, which is read from where the body ends.
local function test_a_body_left_unread_is_dropped_before_the_next_request()
  serving(function(req: Server.Request): Server.Reply
    if req.path == "/part" then
      local piece = assert(req.body:read(3))
      return { status = 200, body = piece }
    end
    if req.path == "/none" then return { status = 200, body = "none" } end
    return { status = 200, body = req.path }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "PUT /part HTTP/1.1\r\nHost: test\r\nContent-Length: 10\r\n\r\n0123456789" ..
        "PUT /none HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ..
        "4\r\nGET \r\n0\r\n\r\n" .. get("/after"))
    assert(reply(p).body == "012")
    assert(reply(p).body == "none")
    assert(reply(p).body == "/after")
  end)
end

--- A malformed request is answered 400 and the connection closed.
local function test_a_malformed_request_is_answered_400()
  serving(echo, function(address: Net.Address)
    for _, request in ipairs({
        "GET / HTTP/1.1\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "GET / HTTP/1.1\r\nHost : t\r\n\r\n",
    }) do
      local p <close> = peer(address)
      send(p, request)
      local got = reply(p)
      assert(got.status == 400, request)
      assert(got.headers["connection"] == "close")
      assert(ended(p))
    end
    local newer <close> = peer(address)
    send(newer, "GET / HTTP/2.0\r\nHost: t\r\n\r\n")
    assert(reply(newer).status == 505)
  end)
end

--- A Reader body that ends short of its length cuts the reply short:
--- the connection closes, and why goes to on_error.
local function test_a_reader_body_short_of_its_length_closes_the_connection()
  local troubles = serving(function(_req: Server.Request): Server.Reply
    return { status = 200, body = Stream.from_string("abc"), length = 10 }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, get("/"))
    assert(line(p) == "HTTP/1.1 200 OK")
    while more(p) do end
    assert(p.buf:find("\r\n\r\nabc$") ~= nil, p.buf)
  end)
  assert(#troubles == 1 and trouble_at(troubles, 1):find("ended 7 bytes short", 1, true) ~= nil, troubles[1])
end

--- A 304 carries no body, and a Content-Length only where the handler
--- gives one, the size of a 200's body, which is passed on.
local function test_a_304_carries_no_length_but_one_given()
  serving(function(req: Server.Request): Server.Reply
    if req.path == "/sized" then
      return { status = 304, headers = { ["Content-Length"] = "10" } }
    end
    return { status = 304, headers = { ETag = '"v1"' } }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, get("/") .. get("/sized") .. get("/"))
    local first = reply(p)
    assert(first.status == 304 and first.headers["content-length"] == nil)
    assert(first.headers["etag"] == '"v1"')
    local sized = reply(p)
    assert(sized.status == 304 and sized.headers["content-length"] == "10")
    assert(reply(p).status == 304)
  end)
end

--- A reply whose Reader body reads the request's own, to a client
--- waiting for `100 Continue`, tells it to go on before the reply's
--- head, never after, where it would be read as the body.
local function test_a_reply_reading_the_request_body_sends_100_first()
  serving(function(req: Server.Request): Server.Reply
    return { status = 200, body = req.body }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "PUT / HTTP/1.1\r\nHost: test\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n")
    assert(line(p) == "HTTP/1.1 100 Continue")
    assert(line(p) == "")
    send(p, "echo")
    local got = reply(p)
    assert(got.status == 200 and got.body == "echo", got.body)
    send(p, get("/"))
    assert(reply(p).status == 200)
  end)
end

--- A Reader body that raises cuts the reply short: the connection
--- closes, the Reader is closed, and what it raised, with its stack,
--- goes to on_error.
local function test_a_reply_body_that_raises_closes_the_connection()
  local closed: boolean = false
  local record Raising is Stream.Reader
    read: function(Raising, max_bytes?: integer): string?, string
    close: function(Raising): boolean, string
  end
  local raising: Raising = setmetatable({}, { __index = {
    read = function(_self: Raising, _max_bytes?: integer): string?, string
      error("the body broke")
    end,
    close = function(_self: Raising): boolean, string
      closed = true
      return true, ""
    end,
  } })
  local troubles = serving(function(_req: Server.Request): Server.Reply
    return { status = 200, body = raising, length = 5 }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, get("/"))
    assert(line(p) == "HTTP/1.1 200 OK")
    while more(p) do end
  end)
  assert(closed)
  assert(#troubles == 1 and trouble_at(troubles, 1):find("the body broke", 1, true) ~= nil, troubles[1])
  assert(trouble_at(troubles, 1):find("stack traceback", 1, true) ~= nil, troubles[1])
end

--- A request body that fails while a reply's Reader reads it closes the
--- connection after the reply, however cleanly that Reader ends: the
--- bytes after it are no request to serve.
local function test_a_body_failing_under_the_reply_closes_the_connection()
  local paths: mut {string} = {}
  local record Lenient is Stream.Reader
    source: Stream.Reader
    read: function(Lenient, max_bytes?: integer): string?, string
    close: function(Lenient): boolean, string
  end
  local lenient_methods = {
    -- Reads every failure as the end.
    read = function(self: Lenient, max_bytes?: integer): string?, string
      local piece, _ = self.source:read(max_bytes)
      if piece == nil then return nil, "" end
      return piece, ""
    end,
    close = function(_self: Lenient): boolean, string return true, "" end,
  }
  local lenient_mt: metatable<Lenient> = { __index = lenient_methods }
  serving(function(req: Server.Request): Server.Reply
    paths[#paths + 1] = req.path
    local lenient: Lenient = setmetatable({ source = req.body }, lenient_mt)
    return { status = 200, body = lenient }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "POST /up HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcX\r\n" ..
        get("/smuggled"))
    local got = reply(p)
    assert(got.status == 200 and got.body == "abc", got.body)
    while more(p) do end
  end)
  assert(#paths == 1 and paths[1] == "/up", table.concat(paths, " "))
end

--- A request carries the connection's far end: the loopback address and
--- the client's own port, which is not the server's.
local function test_a_request_carries_its_peer_address()
  local seen: Net.Address? = nil
  local server_port: integer = 0
  local troubles = serving(function(req: Server.Request): Server.Reply
    seen = req.peer
    return { status = 200, body = "ok" }
  end, function(address: Net.Address)
    server_port = assert(address.port, "the server reported no port")
    local p <close> = peer(address)
    send(p, get("/"))
    assert(reply(p).status == 200)
  end)
  assert(#troubles == 0, troubles[1])
  local seen_value = seen
  assert(seen_value ~= nil and seen_value.kind == "tcp" and seen_value.host == "127.0.0.1", "no peer")
  assert(assert(seen_value.port) > 0 and seen_value.port ~= server_port)
end

--- A caller's on_stop runs once, as the server stops, with the server;
--- the connection idle then is already closed by the server's own, and
--- what it raises reaches on_error without keeping the server from
--- stopping.
local function test_a_callers_on_stop_runs_once_and_its_raise_is_reported()
  local calls: integer = 0
  local given: Net.Server? = nil
  local idle_ended: boolean = false
  local idle_peer: Peer? = nil
  local troubles = serving(echo, function(address: Net.Address)
    local idle = peer(address)
    idle_peer = idle
    send(idle, get("/"))
    assert(reply(idle).status == 200)
    Poll.spawn(function() idle_ended = ended(idle) end)
  end, { on_stop = function(server: Net.Server)
    calls = calls + 1
    given = server
    error("stopping badly")
  end })
  local _, _ = assert(idle_peer).conn:close()
  assert(calls == 1, tostring(calls))
  local given_value = given
  assert(given_value ~= nil and type(given_value.stop) == "function")
  assert(idle_ended, "the idle connection was left open")
  assert(#troubles == 1 and trouble_at(troubles, 1):find("stopping badly", 1, true) ~= nil, tostring(troubles[1]))
end

--- A spec's on_stop that is no function raises, naming the field.
local function test_a_non_function_on_stop_is_refused()
  local ok, err = pcall(Server.serve, {
    listeners = { Net.tcp("127.0.0.1", 0) }, handle = echo, on_stop = "no",
  } as Server.ServeSpec)
  assert(not ok and tostring(err):find("spec.on_stop", 1, true) ~= nil, tostring(err))
end

--- A handler's 4xx (a 404, a 400, a 401 to a request with a body) keeps the
--- connection for the next request; so does a 5xx it chose, and a
--- `close` it asked for still closes.
local function test_a_handlers_error_reply_keeps_the_connection()
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.path == "/missing" then return { status = 404, body = "no" } end
    if req.path == "/bad" then return { status = 400 } end
    if req.path == "/busy" then return { status = 503, body = "later" } end
    if req.path == "/gone" then return { status = 410, close = true } end
    return { status = 200, body = req.path }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, get("/missing") .. get("/bad") .. get("/busy") .. get("/after"))
    for _, want in ipairs({ 404, 400, 503, 200 }) do
      local got = reply(p)
      assert(got.status == want, tostring(got.status))
      assert(got.headers["connection"] == nil, tostring(want))
    end
    send(p, get("/missing"))
    assert(reply(p).status == 404)
    send(p, get("/gone"))
    local gone = reply(p)
    assert(gone.status == 410 and gone.headers["connection"] == "close")
    assert(ended(p))
  end)
  assert(#troubles == 0, troubles[1])
end

--- An error reply to a request whose body the handler never read still
--- frames: the body, whole or chunked, is dropped, and the request
--- pipelined behind it is answered.
local function test_an_unread_body_with_a_4xx_reply_still_frames()
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.path:find("^/refuse") then return { status = 401, body = "who" } end
    return { status = 200, body = req.path }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "POST /refuse HTTP/1.1\r\nHost: test\r\nContent-Length: 11\r\n\r\nGET /evil H" ..
        "POST /refuse2 HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ..
        "b\r\nGET /evil H\r\n0\r\n\r\n" .. get("/after"))
    local first, second, third = reply(p), reply(p), reply(p)
    assert(first.status == 401 and first.headers["connection"] == nil)
    assert(second.status == 401 and second.headers["connection"] == nil)
    assert(third.status == 200 and third.body == "/after", third.body)
  end)
  assert(#troubles == 0, troubles[1])
end

--- A 4xx to a body that cannot be dropped (past body_bytes) closes the
--- connection, as before: what follows on it is no request.
local function test_a_4xx_to_an_undroppable_body_closes()
  serving(function(_req: Server.Request): Server.Reply
    return { status = 400 }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "POST / HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n" ..
        "20\r\n" .. ("x"):rep(32) .. "\r\n0\r\n\r\n" .. get("/never"))
    local got = reply(p)
    assert(got.status == 400, tostring(got.status))
    assert(ended(p))
  end, { limits = { body_bytes = 8 } })
end

--- A body sent a byte at a time fails past body_ns, however steadily it
--- comes and however short each wait: the handler's read fails and the
--- server answers 408 in place of its reply and closes.
local function test_a_body_slower_than_body_ns_is_answered_408()
  local read_failed: boolean = false
  serving(function(req: Server.Request): Server.Reply
    local _, why = Stream.read_all(req.body)
    read_failed = why ~= nil
    return { status = 200, body = "never" }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "PUT / HTTP/1.1\r\nHost: test\r\nContent-Length: 40\r\n\r\n")
    local started = Clock.monotonic_ns()
    -- Each byte is followed by a short wait for the reply, and the client
    -- stops sending once it comes: bytes sent after the server's linger
    -- ends meet a closed socket, whose reset discards the unread 408 on
    -- BSD, so how late the 408 is read must not set whether it arrives.
    p.conn:set_timeout(Clock.ms(30))
    for _ = 1, 40 do
      if not p.conn:write("x") then break end
      local piece, why = p.conn:read()
      if piece ~= nil then
        p.buf = p.buf .. piece
        break
      end
      assert(why == Poll.TIMEOUT, "reading: " .. why)
      if Clock.monotonic_ns() - started > Clock.seconds(3) then break end
    end
    p.conn:set_timeout(Clock.seconds(5))
    local got = reply(p)
    assert(got.status == 408 and got.headers["connection"] == "close", tostring(got.status))
    assert(Clock.monotonic_ns() - started < Clock.seconds(3))
    assert(ended(p))
  end, { body_ns = Clock.ms(200), timeout_ns = Clock.seconds(2) })
  assert(read_failed, "the handler's read did not fail")
end

--- A body the handler leaves unread, trickled past body_ns, is dropped
--- no further: the reply already sent stands and the connection closes
--- (no second reply follows); a body in time on the same server is
--- served, and a request with no body has no deadline to meet.
local function test_body_ns_bounds_the_drop_and_spares_what_is_in_time()
  serving(function(req: Server.Request): Server.Reply
    if req.path == "/read" then
      return { status = 200, body = assert(Stream.read_all(req.body)) }
    end
    return { status = 200, body = "ok" }
  end, function(address: Net.Address)
    local fast <close> = peer(address)
    send(fast, "PUT /read HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n\r\nabc")
    assert(reply(fast).body == "abc")
    local _, _ = Poll.delay(Clock.ms(300))
    send(fast, get("/nobody"))
    assert(reply(fast).body == "ok")
    local slow <close> = peer(address)
    send(slow, "PUT /skip HTTP/1.1\r\nHost: test\r\nContent-Length: 40\r\n\r\n")
    assert(reply(slow).body == "ok")
    local started = Clock.monotonic_ns()
    while Clock.monotonic_ns() - started < Clock.seconds(3) do
      if not slow.conn:write("x") then break end
      local _, _ = Poll.delay(Clock.ms(30))
    end
    assert(vanished(slow), "something followed the reply")
  end, { body_ns = Clock.ms(200), timeout_ns = Clock.seconds(2) })
end

--- A body_ns that is no duration raises, naming the field.
local function test_a_degenerate_body_ns_is_refused()
  local ok, err = pcall(Server.serve, {
    listeners = { Net.tcp("127.0.0.1", 0) }, handle = echo, body_ns = -1,
  } as Server.ServeSpec)
  assert(not ok and tostring(err):find("body_ns", 1, true) ~= nil, tostring(err))
end

--- A handler that works past body_ns before it reads a body the client
--- sent in good time gets the body: the time runs from its first read.
local function test_a_slow_handler_reading_a_prompt_body_gets_it()
  local read: string? = nil
  local troubles = serving(function(req: Server.Request): Server.Reply
    assert(Poll.delay(Clock.ms(500)))
    read = assert(Stream.read_all(req.body))
    return { status = 200, body = read }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "PUT / HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n\r\n")
    local _, _ = Poll.delay(Clock.ms(50))
    send(p, "abc")
    local got = reply(p)
    assert(got.status == 200 and got.body == "abc", tostring(got.status))
  end, { body_ns = Clock.ms(200), timeout_ns = Clock.seconds(2) })
  assert(#troubles == 0, troubles[1])
  assert(read == "abc")
end

--- A handler that works past body_ns and ignores the body, sent in good
--- time, is answered as any other: the connection stays open, and the
--- body is dropped in a window of its own before the next request.
local function test_a_slow_handler_ignoring_a_prompt_body_keeps_the_connection()
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.path == "/slow" then assert(Poll.delay(Clock.ms(500))) end
    return { status = 200, body = req.path }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "PUT /slow HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n\r\n")
    local _, _ = Poll.delay(Clock.ms(50))
    send(p, "abc")
    local first = reply(p)
    assert(first.status == 200 and first.body == "/slow", tostring(first.status))
    assert(first.headers["connection"] == nil, "the reply closed the connection")
    send(p, get("/next"))
    local second = reply(p)
    assert(second.status == 200 and second.body == "/next", tostring(second.status))
  end, { body_ns = Clock.ms(200), timeout_ns = Clock.seconds(2) })
  assert(#troubles == 0, troubles[1])
end

--- A client waiting on `Expect: 100-continue` whose request is refused
--- with a string reply is answered and closed, not left to wait for a
--- body it never sends.
local function test_a_refused_100_continue_closes_without_waiting()
  local started = Clock.monotonic_ns()
  local troubles = serving(function(_req: Server.Request): Server.Reply
    return { status = 401, body = "who" }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "POST / HTTP/1.1\r\nHost: test\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n")
    local got = reply(p)
    assert(got.status == 401 and got.headers["connection"] == "close", tostring(got.status))
    assert(ended(p))
  end)
  assert(#troubles == 0, troubles[1])
  assert(Clock.monotonic_ns() - started < Clock.seconds(3))
end

--- A 404 to a HEAD request that carries a body sends no body and drops
--- the request's, so the next request on the connection is answered.
local function test_a_head_with_a_body_and_a_404_keeps_the_connection()
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.method == "HEAD" then return { status = 404, body = "no" } end
    return { status = 200, body = "after" }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, "HEAD /missing HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n\r\nabc" .. get("/after"))
    local head = reply(p, "HEAD")
    assert(head.status == 404 and head.body == "" and head.headers["connection"] == nil)
    local next_reply = reply(p)
    assert(next_reply.status == 200 and next_reply.body == "after", tostring(next_reply.status))
  end)
  assert(#troubles == 0, troubles[1])
end

--- The caller's on_stop runs after the server has marked itself stopping
--- and closed its idle connections: the connection idle is ended by
--- then, and a reply still in flight, finished once on_stop lets it go,
--- carries `Connection: close`.
local function test_on_stop_runs_after_the_server_has_stopped_taking_work()
  local idle_peer: Peer? = nil
  local busy_peer: Peer? = nil
  local idle_ended_at_stop: boolean = false
  local release: boolean = false
  local in_flight: Got? = nil
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.path == "/slow" then
      while not release do assert(Poll.delay(Clock.ms(5))) end
    end
    return { status = 200, body = "ok" }
  end, function(address: Net.Address)
    local idle = peer(address)
    idle_peer = idle
    send(idle, get("/"))
    assert(reply(idle).status == 200)
    local busy = peer(address)
    busy_peer = busy
    send(busy, get("/slow"))
    assert(Poll.delay(Clock.ms(20)))
    Poll.spawn(function() in_flight = reply(busy) end)
  end, { on_stop = function(_server: Net.Server)
    idle_ended_at_stop = vanished(assert(idle_peer))
    release = true
  end })
  local _, _ = assert(idle_peer).conn:close()
  local _, _ = assert(busy_peer).conn:close()
  assert(#troubles == 0, troubles[1])
  assert(idle_ended_at_stop, "the idle connection was open when on_stop ran")
  local in_flight_value = in_flight
  assert(in_flight_value ~= nil and in_flight_value.status == 200 and in_flight_value.headers["connection"] == "close",
    "the reply in flight did not close")
end

--- A body worth compressing, and the type that goes with it.
local TEXT <const> = ("hello, compressible world\n"):rep(100)
local TEXT_TYPE <const> = { ["Content-Type"] = "text/plain" }

--- `body` expanded from `coding`, as a client would.
local function expanded(coding: string, body: string): string
  if coding == "zstd" then
    local out = assert(Stream.run(assert(Compress.zstd_decoder()), body))
    return out
  end
  local out = assert(Compress.inflate("gzip", body))
  return out
end

--- A reply with a body big enough and a type fit to compress is sent
--- in the coding the request prefers: zstd or gzip, by the client's
--- weights, with its own length, the coding named and `Vary`; it
--- expands to the handler's bytes. Without the option, or for a request
--- that sends no Accept-Encoding, it is sent as given.
local function test_a_reply_is_compressed_for_the_accept_encoding()
  local troubles = serving(function(_req: Server.Request): Server.Reply
    return { status = 200, headers = TEXT_TYPE, body = TEXT }
  end, function(address: Net.Address)
    local p = peer(address)
    local cases: {string: string} = {
      ["zstd, gzip"] = "zstd", ["gzip, zstd"] = "zstd", ["GZIP"] = "gzip",
      ["gzip;q=0.8, zstd;q=0.2"] = "gzip", ["zstd;q=0, gzip"] = "gzip",
      ["*"] = "zstd", ["*;q=0.1, gzip"] = "gzip", ["x-gzip"] = "gzip",
      ["br, deflate"] = "", ["identity"] = "", [""] = "",
    }
    for accept, want in pairs(cases) do
      send(p, get("/", "Accept-Encoding: " .. accept .. "\r\n"))
      local got = reply(p)
      local coding: string? = if want == "" then nil else want end
      assert(got.headers["content-encoding"] == coding, accept)
      assert(got.headers["vary"] == "Accept-Encoding", accept)
      assert(got.headers["content-length"] == tostring(#got.body), accept)
      if coding ~= nil then
        assert(#got.body < #TEXT)
        assert(expanded(coding, got.body) == TEXT, accept)
      else
        assert(got.body == TEXT, accept)
      end
    end
    send(p, get("/"))
    local bare = reply(p)
    assert(bare.body == TEXT and bare.headers["content-encoding"] == nil)
    assert(bare.headers["vary"] == "Accept-Encoding")
  end, { compress = true })
  assert(#troubles == 0, troubles[1])
  serving(function(_req: Server.Request): Server.Reply
    return { status = 200, headers = TEXT_TYPE, body = TEXT }
  end, function(address: Net.Address)
    local p = peer(address)
    send(p, get("/", "Accept-Encoding: gzip\r\n"))
    local got = reply(p)
    assert(got.body == TEXT and got.headers["content-encoding"] == nil and got.headers["vary"] == nil)
  end)
end

--- What the server leaves alone, with no `Content-Encoding` added and no
--- `Vary`: a coding the handler set, a range, a body below the
--- threshold or none, a type that is not text, no-transform, an event
--- stream, and the statuses without a body.
local function test_a_reply_that_is_not_to_be_compressed_is_sent_as_given()
  local small = "tiny"
  local png = { ["Content-Type"] = "image/png" }
  local troubles = serving(function(req: Server.Request): Server.Reply
    local path = req.path
    if path == "/encoded" then
      return { status = 200, headers = { ["Content-Type"] = "text/plain", ["content-encoding"] = "identity" },
        body = TEXT }
    elseif path == "/range" then
      local r = Server.range(req.headers["range"], #TEXT)
      assert(r.kind == "span")
      local first, last = assert(r.first), assert(r.last)
      return { status = 206, headers = { ["Content-Type"] = "text/plain",
        ["Content-Range"] = ("bytes %d-%d/%d"):format(first, last, #TEXT) },
        body = TEXT:sub(first + 1, last + 1) .. TEXT:sub(1, 1500) }
    elseif path == "/small" then
      return { status = 200, headers = TEXT_TYPE, body = small }
    elseif path == "/small-reader" then
      return { status = 200, headers = TEXT_TYPE, body = Stream.from_string(small), length = #small }
    elseif path == "/image" then
      return { status = 200, headers = png, body = TEXT }
    elseif path == "/untyped" then
      return { status = 200, body = TEXT }
    elseif path == "/notransform" then
      return { status = 200, headers = { ["Content-Type"] = "text/plain", ["Cache-Control"] = "No-Transform" },
        body = TEXT }
    elseif path == "/events" then
      return { status = 200, headers = { ["Content-Type"] = "text/event-stream" }, body = TEXT }
    elseif path == "/empty" then
      return { status = 200, headers = TEXT_TYPE }
    elseif path == "/204" then
      return { status = 204 }
    end
    return { status = 404, headers = TEXT_TYPE, body = TEXT }
  end, function(address: Net.Address)
    local p = peer(address)
    local function once(path: string, extra?: string, method?: string): Got
      send(p, (method or "GET") .. " " .. path .. " HTTP/1.1\r\nHost: test\r\nAccept-Encoding: zstd, gzip\r\n" ..
          (extra or "") .. "\r\n")
      return reply(p, method)
    end
    for _, path in ipairs({ "/encoded", "/small", "/small-reader", "/image", "/untyped", "/notransform",
        "/events", "/empty", "/204" }) do
      local got = once(path)
      assert(got.headers["vary"] == nil, path)
      assert(got.headers["content-encoding"] == (if path == "/encoded" then "identity" else nil end), path)
      local want = TEXT
      if path == "/small" or path == "/small-reader" then
        want = small
      elseif path == "/empty" or path == "/204" then
        want = ""
      end
      assert(got.body == want, path)
    end
    local ranged = once("/range", "Range: bytes=0-9\r\n")
    assert(ranged.status == 206 and ranged.headers["content-encoding"] == nil)
    assert(ranged.headers["content-range"] == ("bytes 0-9/%d"):format(#TEXT))
    assert(ranged.headers["vary"] == nil and ranged.body:sub(1, 10) == TEXT:sub(1, 10))
    -- A 404 is a reply like any other.
    local missing = once("/other")
    assert(missing.status == 404 and missing.headers["content-encoding"] == "zstd")
  end, { compress = true })
  assert(#troubles == 0, troubles[1])
end

--- A 304 carries the `Vary` and the weak `ETag` of the 200 it stands
--- for (RFC 9110 15.4.5) where that 200 would be compressed: a coding is
--- chosen for the request. It is left as it is for a request that takes
--- identity, a type that is not compressed, a coding of the handler's
--- and no-transform.
local function test_a_304_has_the_vary_and_etag_of_the_compressed_200()
  local troubles = serving(function(req: Server.Request): Server.Reply
    local headers: mut {string:string} = { ETag = '"v1"', ["Content-Type"] = "text/plain" }
    if req.path == "/image" then
      headers["Content-Type"] = "image/png"
    elseif req.path == "/notransform" then
      headers["Cache-Control"] = "no-transform"
    elseif req.path == "/encoded" then
      headers["Content-Encoding"] = "gzip"
    elseif req.path == "/typeless" then
      headers["Content-Type"] = nil
    elseif req.path == "/weak" then
      headers["ETag"] = 'W/"v1"'
    end
    return { status = 304, headers = headers }
  end, function(address: Net.Address)
    local p = peer(address)
    local function once(path: string, accept: string): Got
      send(p, get(path, "Accept-Encoding: " .. accept .. "\r\n"))
      return reply(p)
    end
    for _, accept in ipairs({ "gzip", "zstd, gzip", "*" }) do
      local got = once("/", accept)
      assert(got.status == 304 and got.body == "", accept)
      assert(got.headers["vary"] == "Accept-Encoding" and got.headers["etag"] == 'W/"v1"', accept)
      assert(got.headers["content-encoding"] == nil and got.headers["content-length"] == nil, accept)
    end
    local typeless = once("/typeless", "gzip")
    assert(typeless.headers["vary"] == "Accept-Encoding" and typeless.headers["etag"] == 'W/"v1"')
    local weak = once("/weak", "gzip")
    assert(weak.headers["vary"] == "Accept-Encoding" and weak.headers["etag"] == 'W/"v1"')
    for _, path in ipairs({ "/image", "/notransform", "/encoded" }) do
      local got = once(path, "gzip")
      assert(got.status == 304 and got.headers["vary"] == nil and got.headers["etag"] == '"v1"', path)
    end
    for _, accept in ipairs({ "identity", "br", "" }) do
      local got = once("/", accept)
      assert(got.headers["vary"] == nil and got.headers["etag"] == '"v1"', accept)
    end
  end, { compress = true })
  assert(#troubles == 0, troubles[1])
end

--- `min_bytes` moves the threshold: a body at it is compressed, one
--- below it is not.
local function test_the_threshold_is_min_bytes()
  local body = ("a"):rep(200)
  serving(function(req: Server.Request): Server.Reply
    return { status = 200, headers = TEXT_TYPE, body = body:sub(1, if req.path == "/at" then 200 else 199 end) }
  end, function(address: Net.Address)
    local p = peer(address)
    send(p, get("/at", "Accept-Encoding: gzip\r\n") .. get("/below", "Accept-Encoding: gzip\r\n"))
    local at, below = reply(p), reply(p)
    assert(at.headers["content-encoding"] == "gzip" and expanded("gzip", at.body) == body)
    assert(below.headers["content-encoding"] == nil and below.body == body:sub(1, 199))
  end, { compress = { min_bytes = 200 } })
end

--- A HEAD whose reply has a body gets the head its GET gets, with the
--- compressed length and no bytes; one with a size alone is as given.
local function test_head_has_the_compressed_head_of_a_get()
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.path == "/sized" then
      return { status = 200, headers = { ["Content-Type"] = "text/plain", ["Content-Length"] = "4000" } }
    end
    return { status = 200, headers = TEXT_TYPE, body = TEXT }
  end, function(address: Net.Address)
    local p = peer(address)
    local accept = "Accept-Encoding: gzip\r\n"
    send(p, get("/", accept) .. "HEAD / HTTP/1.1\r\nHost: test\r\n" .. accept .. "\r\n" ..
        "HEAD /sized HTTP/1.1\r\nHost: test\r\n" .. accept .. "\r\n" .. get("/", accept))
    local full = reply(p)
    local head = reply(p, "HEAD")
    assert(head.body == "" and head.headers["content-length"] == full.headers["content-length"])
    assert(head.headers["content-encoding"] == "gzip" and head.headers["vary"] == "Accept-Encoding")
    local sized = reply(p, "HEAD")
    assert(sized.headers["content-length"] == "4000" and sized.headers["content-encoding"] == nil)
    assert(sized.headers["vary"] == nil)
    assert(reply(p).body == full.body)
  end, { compress = true })
  assert(#troubles == 0, troubles[1])
end

--- The handler's own Vary is kept and Accept-Encoding joins it, once:
--- on a string, on a list's own line, and not at all where it is named
--- or `*`.
local function test_vary_is_merged_with_the_handlers()
  local troubles = serving(function(req: Server.Request): Server.Reply
    local vary: string | {string}
    if req.path == "/string" then
      vary = "Cookie"
    elseif req.path == "/list" then
      vary = { "Cookie", "Origin" }
    elseif req.path == "/named" then
      vary = "Cookie, accept-ENCODING"
    elseif req.path == "/star" then
      vary = "*"
    else
      vary = ""
    end
    return { status = 200, headers = { ["Content-Type"] = "text/plain", vary = vary }, body = TEXT }
  end, function(address: Net.Address)
    local p = peer(address)
    local accept = "Accept-Encoding: gzip\r\n"
    local function lines(path: string): {string}
      send(p, get(path, accept))
      local head: mut {string} = {}
      local status_line = line(p)
      assert(status_line == "HTTP/1.1 200 OK", status_line)
      local length = 0
      while true do
        local text = line(p)
        if text == "" then break end
        if text:lower():find("^vary: ") then head[#head + 1] = text end
        local n = text:lower():match("^content%-length: (%d+)$")
        if n ~= nil then length = assert(math.tointeger(tonumber(n))) end
      end
      bytes(p, length)
      return head
    end
    assert(table.concat(lines("/string"), "|") == "vary: Cookie, Accept-Encoding")
    assert(table.concat(lines("/list"), "|") == "vary: Cookie|vary: Origin|vary: Accept-Encoding")
    assert(table.concat(lines("/named"), "|") == "vary: Cookie, accept-ENCODING")
    assert(table.concat(lines("/star"), "|") == "vary: *")
    assert(table.concat(lines("/other"), "|") == "vary: Accept-Encoding")
  end, { compress = true })
  assert(#troubles == 0, troubles[1])
end

--- A strong ETag is weakened on a compressed body, which is another
--- representation than the one it names; a weak one is kept.
local function test_a_compressed_reply_has_a_weak_etag()
  serving(function(req: Server.Request): Server.Reply
    return { status = 200, headers = { ["Content-Type"] = "text/plain",
      ETag = if req.path == "/weak" then 'W/"v1"' else '"v1"' end }, body = TEXT }
  end, function(address: Net.Address)
    local p = peer(address)
    send(p, get("/", "Accept-Encoding: gzip\r\n") .. get("/weak", "Accept-Encoding: gzip\r\n") ..
        get("/", "Accept-Encoding: identity\r\n"))
    assert(reply(p).headers["etag"] == 'W/"v1"')
    assert(reply(p).headers["etag"] == 'W/"v1"')
    assert(reply(p).headers["etag"] == '"v1"')
  end, { compress = true })
end

--- A client that refuses identity and every coding the server writes
--- is answered 406, the Reader body closed; one that refuses identity
--- but takes a coding is answered that. A reply not eligible is not
--- refused.
local function test_a_client_refusing_identity_is_answered_406()
  local refused_body = Stream.from_string(TEXT)
  local troubles = serving(function(req: Server.Request): Server.Reply
    if req.path == "/stream" then
      return { status = 200, headers = TEXT_TYPE, body = refused_body }
    elseif req.path == "/small" then
      return { status = 200, headers = TEXT_TYPE, body = "tiny" }
    end
    return { status = 200, headers = TEXT_TYPE, body = TEXT }
  end, function(address: Net.Address)
    local p = peer(address)
    for _, refusal in ipairs({ "identity;q=0", "*;q=0", "gzip;q=0, identity;q=0", "br, *;q=0" }) do
      send(p, get("/", "Accept-Encoding: " .. refusal .. "\r\n"))
      local got = reply(p)
      assert(got.status == 406 and got.headers["vary"] == "Accept-Encoding", refusal)
      assert(got.headers["content-encoding"] == nil and got.body:find("^406 Not Acceptable") ~= nil, refusal)
    end
    send(p, get("/stream", "Accept-Encoding: identity;q=0\r\n"))
    assert(reply(p).status == 406)
    send(p, get("/", "Accept-Encoding: identity;q=0, gzip\r\n"))
    local taken = reply(p)
    assert(taken.status == 200 and expanded("gzip", taken.body) == TEXT)
    send(p, get("/", "Accept-Encoding: *;q=0, identity\r\n"))
    assert(reply(p).body == TEXT)
    send(p, get("/small", "Accept-Encoding: identity;q=0\r\n"))
    assert(reply(p).body == "tiny")
  end, { compress = true })
  assert(#troubles == 0, troubles[1])
  local piece, why = refused_body:read()
  assert(piece == nil and why ~= "", "the refused Reader was closed")
end

--- A Reader body is compressed as it is read, and goes chunked whether
--- or not the handler gave its length (which is the identity size);
--- an HTTP/1.0 client has it until the connection closes.
local function test_a_reader_body_is_compressed_and_goes_chunked()
  local troubles = serving(function(req: Server.Request): Server.Reply
    local reader = Stream.from_string(TEXT .. TEXT)
    if req.path == "/sized" then
      return { status = 200, headers = TEXT_TYPE, body = reader, length = 2 * #TEXT }
    end
    return { status = 200, headers = TEXT_TYPE, body = reader }
  end, function(address: Net.Address)
    local p = peer(address)
    for _, path in ipairs({ "/", "/sized" }) do
      send(p, get(path, "Accept-Encoding: zstd\r\n"))
      local got = reply(p)
      assert(got.headers["transfer-encoding"] == "chunked" and got.headers["content-length"] == nil, path)
      assert(got.headers["content-encoding"] == "zstd" and got.headers["vary"] == "Accept-Encoding")
      assert(expanded("zstd", got.body) == TEXT .. TEXT, path)
    end
    local old = peer(address)
    send(old, "GET / HTTP/1.0\r\nAccept-Encoding: gzip\r\n\r\n")
    local got = reply(old)
    assert(got.headers["content-encoding"] == "gzip" and got.headers["connection"] == "close")
    assert(expanded("gzip", got.body) == TEXT .. TEXT)
  end, { compress = true })
  assert(#troubles == 0, troubles[1])
end

--- A body that does not shrink is sent as it was, and a spec that
--- gives compress a negative threshold is refused.
local function test_incompressible_bytes_stay_and_a_bad_spec_is_refused()
  local noise: mut {string} = {}
  local state = 12345
  for i = 1, 2000 do
    state = (state * 1103515245 + 12345) % 2147483648
    noise[i] = string.char(state // 65536 % 256)
  end
  local random = table.concat(noise)
  serving(function(_req: Server.Request): Server.Reply
    return { status = 200, headers = { ["Content-Type"] = "application/json" }, body = random }
  end, function(address: Net.Address)
    local p = peer(address)
    send(p, get("/", "Accept-Encoding: gzip\r\n"))
    local got = reply(p)
    assert(got.body == random and got.headers["content-encoding"] == nil)
    assert(got.headers["vary"] == "Accept-Encoding")
  end, { compress = true })
  local spec: Server.ServeSpec = {
    handle = function(_req: Server.Request): Server.Reply return { status = 200 } end,
    listeners = { Net.tcp("127.0.0.1", 0) }, compress = { min_bytes = -1 },
  }
  local ok, err = pcall(Server.serve, spec)
  assert(not ok and tostring(err):find("spec.compress.min_bytes", 1, true) ~= nil, tostring(err))
end

--- A compress table with a field it has none of raises, naming it, as
--- limits does.
local function test_a_compress_table_with_an_unknown_field_is_refused()
  -- A chunk loaded from text, since the checker refuses a table of the
  -- wrong shape where a spec is written.
  local function refused(compress: string): string
    local chunk = assert(load("local Server, Net, handle = ...\n" ..
        "return pcall(Server.serve, { listeners = { Net.tcp('127.0.0.1', 0) }, handle = handle," ..
        " compress = " .. compress .. " })"))
    local ok, err = chunk(Server, Net, echo)
    assert(ok == false)
    return tostring(err)
  end
  assert(refused("{ min_byte = 10 }"):find("spec.compress has no field min_byte", 1, true) ~= nil)
  assert(refused("{ min_bytes = 1.5 }"):find("spec.compress.min_bytes", 1, true) ~= nil)
  assert(refused("{ min_bytes = -1 }"):find("spec.compress.min_bytes", 1, true) ~= nil)
  assert(refused("'yes'"):find("spec.compress must be", 1, true) ~= nil)
end

--- A reply the handler marks `Cache-Control: no-transform` is sent as it
--- is, the opt-out for a reply that mixes a secret with the client's input.
local function test_no_transform_opts_a_reply_out()
  serving(function(_req: Server.Request): Server.Reply
    return { status = 200, headers = { ["Content-Type"] = "text/html", ["Cache-Control"] = "private, no-transform" },
      body = TEXT }
  end, function(address: Net.Address)
    local p = peer(address)
    send(p, get("/", "Accept-Encoding: gzip, zstd\r\n"))
    local got = reply(p)
    assert(got.body == TEXT and got.headers["content-encoding"] == nil and got.headers["vary"] == nil)
  end, { compress = true })
end

--- A Reader body that fails after the head has gone is cut short with
--- its compressor between it and the wire: the connection ends, the
--- Reader under the compressor is closed, and the failure goes to
--- on_error. The failing Reader is a gzip decoder over bytes that are
--- no gzip, since a Reader of the test's own would add to the errors
--- the checker pins for this file; the peer is closed by hand for the
--- same reason.
local function test_a_compressed_reader_that_fails_midway_is_closed_and_reported()
  local source = Stream.from_string(("not gzip at all, but long enough to read\n"):rep(60))
  local troubles = serving(function(_req: Server.Request): Server.Reply
    local decoder, _ = assert(Compress.inflater("gzip"))
    return { status = 200, headers = TEXT_TYPE, body = Stream.transform(source, decoder) }
  end, function(address: Net.Address)
    local p = peer(address)
    send(p, get("/", "Accept-Encoding: gzip\r\n"))
    assert(line(p) == "HTTP/1.1 200 OK")
    while more(p) do end
    local _, _ = p.conn:close()
  end, { compress = true })
  local piece, why = source:read()
  assert(piece == nil and why ~= "", "the Reader under the compressor was closed")
  assert(#troubles == 1 and trouble_at(troubles, 1):find("the reply's body", 1, true) ~= nil, troubles[1])
end

--- A HEAD whose reply has a compressible Reader body has it closed
--- unread, and the head of the GET is sent.
local function test_a_compressed_reader_on_a_head_is_closed()
  local source = Stream.from_string(TEXT)
  local troubles = serving(function(_req: Server.Request): Server.Reply
    return { status = 200, headers = TEXT_TYPE, body = source }
  end, function(address: Net.Address)
    local p = peer(address)
    send(p, "HEAD / HTTP/1.1\r\nHost: test\r\nAccept-Encoding: gzip\r\n\r\n")
    local got = reply(p, "HEAD")
    assert(got.status == 200 and got.body == "" and got.headers["content-encoding"] == "gzip")
    assert(got.headers["transfer-encoding"] == "chunked")
    local _, _ = p.conn:close()
  end, { compress = true })
  local piece, why = source:read()
  assert(piece == nil and why ~= "", "the Reader was closed unread")
  assert(#troubles == 0, troubles[1])
end
