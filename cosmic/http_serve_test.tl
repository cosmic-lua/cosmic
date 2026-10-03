--- [`Http.serve`] over a socket file in the test's own directory: a
--- client here writes a request's bytes as given and reads the reply as
--- sent, so what the server does on the wire is what is checked.

local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")

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
  buf: string
  metamethod __close: function(Peer)
end

local peer_mt: metatable<Peer> = {
  __index = Peer,
  __close = function(self: Peer) local _, _ = self.conn:close() end,
}

local function peer(address: Net.Address): Peer
  local conn = assert(Net.connect(address, { timeout_ns = Time.seconds(5) }))
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
  local headers: {string:string} = {}
  while true do
    local text = line(p)
    if text == "" then break end
    local name, value = text:match("^([^:]+): (.*)$")
    assert(name ~= nil, "header line: " .. text)
    assert(headers[name:lower()] == nil, "repeated header " .. name)
    headers[name:lower()] = value
  end
  local body = ""
  if method == "HEAD" or status < 200 or status == 204 or status == 304 then
    body = ""
  elseif headers["content-length"] ~= nil then
    body = bytes(p, assert(math.tointeger(tonumber(headers["content-length"]))))
  elseif headers["transfer-encoding"] == "chunked" then
    local parts: {string} = {}
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

local function send(p: Peer, data: string)
  assert(p.conn:write(data))
end

--- Runs a server of `handle` (and `spec`'s other fields) at a socket
--- file in `tmp`, running `client` with its address once it listens,
--- and stops it once `client` returns. Answers what went to on_error.
local function serving(tmp: string, handle: function(Http.Request): Http.Reply,
    client: function(Net.Address), spec?: Http.ServeSpec): {string}
  local troubles: {string} = {}
  local given: Http.ServeSpec = spec or {}
  given.listeners = { Net.unix(tmp .. "/s.sock") }
  given.handle = handle
  given.on_error = function(trouble: string) troubles[#troubles + 1] = trouble end
  given.on_ready = function(addresses: {Net.Address}, server: Net.Server)
    client(addresses[1])
    server:stop()
  end
  assert(Http.serve(given))
  return troubles
end

--- Answers each request with its method, path and query.
local function echo(req: Http.Request): Http.Reply
  local body = assert(Stream.read_all(req.body))
  return { status = 200, headers = { ["Content-Type"] = "text/plain" },
    body = req.method .. " " .. req.path .. " " .. req.query .. " " .. body }
end

local function get(path: string, extra?: string): string
  return "GET " .. path .. " HTTP/1.1\r\nHost: test\r\n" .. (extra or "") .. "\r\n"
end

--- Requests pipelined in one write are answered in order on one
--- connection, which stays open for another after them; each reply
--- carries a Date and its Content-Length, and no Connection header.
local function test_pipelined_requests_are_answered_in_order_on_one_connection(tmp: string)
  local troubles = serving(tmp, echo, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, get("/a?x=1") .. get("/b") ..
      "PUT /c HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n\r\nabc")
    local first, second, third = reply(p), reply(p), reply(p)
    assert(first.status == 200 and first.body == "GET /a x=1 ", first.body)
    assert(second.body == "GET /b  ", second.body)
    assert(third.body == "PUT /c  abc", third.body)
    assert(first.headers["content-length"] == tostring(#first.body))
    assert(first.headers["date"]:find(" GMT$") ~= nil, first.headers["date"])
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
local function test_a_connection_closes_where_either_side_asks(tmp: string)
  serving(tmp, function(req: Http.Request): Http.Reply
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
local function test_head_is_answered_with_no_body(tmp: string)
  local read_from = false
  local closed = false
  local record Watched is Stream.Reader
    read: function(Watched, max_bytes?: integer): string | nil, string
    close: function(Watched): boolean, string
  end
  local watched: Watched = setmetatable({}, { __index = {
    read = function(_self: Watched, _max_bytes?: integer): string | nil, string
      read_from = true
      return nil, ""
    end,
    close = function(_self: Watched): boolean, string
      closed = true
      return true, ""
    end,
  } })
  serving(tmp, function(req: Http.Request): Http.Reply
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
local function test_chunked_bodies_both_ways(tmp: string)
  serving(tmp, function(req: Http.Request): Http.Reply
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
local function test_100_continue(tmp: string)
  serving(tmp, function(req: Http.Request): Http.Reply
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
local function test_each_limit_is_answered(tmp: string)
  local handled = 0
  local troubles = serving(tmp, function(req: Http.Request): Http.Reply
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
    second.conn:set_timeout(Time.ms(100))
    local nothing, why = second.conn:read()
    assert(nothing == nil and why == Poll.TIMEOUT, why)
    second.conn:set_timeout(Time.seconds(5))
    local _, _ = first.conn:close()
    assert(reply(second).status == 200)
  end, { limits = { head_bytes = 1024, body_bytes = 100, connections = 1 } })
  assert(#troubles == 0, troubles[1])
end

--- A handler that raises, or answers what is no reply the server can
--- send, is answered 500, the connection closed, and the trouble goes
--- to on_error: a raise with its stack.
local function test_a_failing_handler_is_answered_500(tmp: string)
  local bad: {string: any} = {
    ["/nil"] = nil,
    ["/owned"] = { status = 200, headers = { ["Content-Length"] = "3" } },
    ["/cr"] = { status = 200, headers = { ["X-Bad"] = "a\r\nb" } },
    ["/nocontent"] = { status = 204, body = "not empty" },
    ["/interim"] = { status = 101 },
    ["/typo"] = { status = 200, header = {} },
  }
  local paths = { "/raise", "/nil", "/owned", "/cr", "/nocontent", "/interim", "/typo" }
  local troubles = serving(tmp, function(req: Http.Request): Http.Reply
    if req.path == "/raise" then error("the handler failed") end
    local answer: any = bad[req.path]
    return answer as Http.Reply
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
  assert(troubles[1]:find("http: GET /raise: .*the handler failed") ~= nil, troubles[1])
  assert(troubles[1]:find("stack traceback", 1, true) ~= nil, troubles[1])
  assert(troubles[2]:find("not an Http.Reply", 1, true) ~= nil, troubles[2])
  assert(troubles[3]:find("Content-Length: the server writes it itself", 1, true) ~= nil, troubles[3])
  assert(troubles[4]:find("CR, LF or NUL", 1, true) ~= nil, troubles[4])
  assert(troubles[5]:find("no body goes with status 204", 1, true) ~= nil, troubles[5])
  assert(troubles[6]:find("from 200 to 999", 1, true) ~= nil, troubles[6])
  assert(troubles[7]:find("no field header", 1, true) ~= nil, troubles[7])
end

--- A head sent slower than head_ns is answered 408 and closed, however
--- steadily its bytes come; a connection idle past idle_ns is closed.
local function test_a_slow_head_and_an_idle_connection_are_closed(tmp: string)
  serving(tmp, echo, function(address: Net.Address)
    local slow <close> = peer(address)
    local started = Time.monotonic_ns()
    local request = get("/")
    for i = 1, #request do
      if not slow.conn:write(request:sub(i, i)) then break end
      local _, _ = Poll.delay(Time.ms(20))
      if Time.monotonic_ns() - started > Time.seconds(2) then break end
    end
    local got = reply(slow)
    assert(got.status == 408, tostring(got.status))
    assert(Time.monotonic_ns() - started < Time.seconds(2))
    local idle <close> = peer(address)
    local waited_from = Time.monotonic_ns()
    assert(ended(idle))
    assert(Time.monotonic_ns() - waited_from < Time.seconds(2))
  end, { head_ns = Time.ms(200), idle_ns = Time.ms(200) })
end

--- Stopping closes a kept-alive connection idle at once, rather than
--- waiting out idle_ns, and a request in flight finishes with
--- `Connection: close`.
local function test_stopping_closes_idle_connections_at_once(tmp: string)
  local started = Time.monotonic_ns()
  local idle_ended = false
  local in_flight: Got = nil
  local release = false
  assert(Http.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    idle_ns = Time.seconds(60),
    handle = function(req: Http.Request): Http.Reply
      if req.path == "/slow" then
        while not release do assert(Poll.delay(Time.ms(5))) end
      end
      return { status = 200, body = "ok" }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local idle = peer(addresses[1])
      send(idle, get("/"))
      assert(reply(idle).status == 200)
      local busy = peer(addresses[1])
      send(busy, get("/slow"))
      assert(Poll.delay(Time.ms(20)))
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
  assert(in_flight.status == 200 and in_flight.headers["connection"] == "close")
  assert(Time.monotonic_ns() - started < Time.seconds(10))
end

--- A body the handler reads in part, or not at all, is dropped before
--- the next request, which is read from where the body ends.
local function test_a_body_left_unread_is_dropped_before_the_next_request(tmp: string)
  serving(tmp, function(req: Http.Request): Http.Reply
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
local function test_a_malformed_request_is_answered_400(tmp: string)
  serving(tmp, echo, function(address: Net.Address)
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
local function test_a_reader_body_short_of_its_length_closes_the_connection(tmp: string)
  local troubles = serving(tmp, function(_req: Http.Request): Http.Reply
    return { status = 200, body = Stream.from_string("abc"), length = 10 }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, get("/"))
    assert(line(p) == "HTTP/1.1 200 OK")
    while more(p) do end
    assert(p.buf:find("\r\n\r\nabc$") ~= nil, p.buf)
  end)
  assert(#troubles == 1 and troubles[1]:find("ended 7 bytes short", 1, true) ~= nil, troubles[1])
end

--- A 304 carries neither a body nor a Content-Length.
local function test_a_304_carries_no_length(tmp: string)
  serving(tmp, function(_req: Http.Request): Http.Reply
    return { status = 304, headers = { ETag = '"v1"' } }
  end, function(address: Net.Address)
    local p <close> = peer(address)
    send(p, get("/") .. get("/"))
    local first = reply(p)
    assert(first.status == 304 and first.headers["content-length"] == nil)
    assert(first.headers["etag"] == '"v1"')
    assert(reply(p).status == 304)
  end)
end
