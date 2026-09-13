--- HTTP/1.1 server: listen, serve, and the Request/Response a handler sees.
--- Wraps cosmo.http and cosmic.net.
---
--- The module owns the socket and the loop; a caller writes one handler
--- function and never touches framing. `cosmo.http`'s incremental parser
--- reads the head, `cosmic.net` carries the bytes, and everything
--- between — the request-target, the header views, `Content-Length`,
--- `Date`, the keep-alive decision — is computed here.
---
--- One connection at a time, keep-alive within it. `serve` accepts and
--- serves until the listener is closed; `serve_one` does a single
--- connection, which is what a test or a caller with its own accept loop
--- wants. How more than one connection is served at once is a decision
--- this module does not make, and the handler signature is what that
--- decision must not change.
---
--- Example — a two-route server:
---   local http = require("cosmic.http")
---   local srv = assert(http.listen("127.0.0.1", 8080))
---   local _stopped, err = srv:serve(function(req: http.Request, res: http.Response)
---       if req.path == "/health" then
---         local _ok, _err = res:json({ok = true})
---       else
---         local _ok, _err = res:text("hello " .. req.path)
---       end
---     end)
---   print("stopped: " .. err)

local http = require("cosmo.http")
local ip = require("cosmic.ip")
local log = require("cosmic.log")
local net = require("cosmic.net")
local request = require("cosmic.http.request")
local response = require("cosmic.http.response")

--- One HTTP/1.1 request, as a handler sees it (see cosmic.http.request).
local type Request = request.Request

--- One HTTP/1.1 response, as a handler writes it (see cosmic.http.response).
local type Response = response.Response

--- What a server hands every request to. A handler answers by calling a
--- send verb on `res`; one that returns without sending gets a 500, and
--- one that throws gets a 500 too — a throw is a Lua protocol, not a
--- server failure, so the connection survives it.
local type Handler = function(req: Request, res: Response)

--- Server limits, all of them defaults a caller may lower.
local record ListenOptions
  --- Bound every receive on an accepted connection (default 30000).
  --- A client that stops sending mid-request, or one that holds a
  --- keep-alive connection open without using it, is dropped rather
  --- than allowed to occupy the one connection the server serves.
  read_timeout_ms: integer
  --- Refuse a request body larger than this many bytes with 413
  --- (default 1048576). A declared `Content-Length` is refused before a
  --- byte of the body is read; a `Transfer-Encoding: chunked` body
  --- declares no length, so it is decoded up to this bound and refused
  --- the moment the payload passes it, still before the handler runs.
  --- A chunked body's framing overhead is bounded the same way while it
  --- arrives gradually, but a fast client that lands its whole body,
  --- terminator included, in one read is checked against the decoded
  --- payload only (`cosmic.http.request` has the detail).
  max_body_bytes: integer
  --- Refuse a request head larger than this many bytes with 431
  --- (default 32767, which is as large as a head can be at all:
  --- `ParseHttpMessage` refuses anything longer itself). Raising this
  --- past the default buys nothing — the parser gets the bytes first
  --- and answers a longer head with 400 — so 431 is what a caller who
  --- LOWERS the limit gets, and lowering it is the only useful move.
  max_head_bytes: integer
end

local DEFAULTS: ListenOptions = {
  read_timeout_ms = 30000,
  max_body_bytes = 1048576,
  max_head_bytes = 32767,
}

--- A listening HTTP server.
local record Server
  --- Accept and serve connections until the listener fails.
  --- A closed listener — from a signal handler, or another call to
  --- `close` — is what ends this, so it never returns true.
  --- @param handler Handler The function every request is handed to
  --- @return boolean Always false: the loop ends only on failure
  --- @return string The accept error that ended the loop
  serve: function(self: Server, handler: Handler): boolean, string
  --- Accept one connection and serve it to completion, then close it.
  --- "To completion" is the whole keep-alive conversation, not one
  --- request: the connection is served until the client closes it, asks
  --- for no more, times out, or sends something unparseable.
  --- @param handler Handler The function every request is handed to
  --- @return boolean True when the connection was served
  --- @return string Error message when the connection could not be accepted
  serve_one: function(self: Server, handler: Handler): boolean, string
  --- The port the server is listening on. Read this after listening on
  --- port 0 to learn the port the OS assigned.
  --- @return integer The bound port
  port: function(self: Server): integer
  --- Stop listening. Idempotent; reports the close(2) error.
  --- @return boolean True when the listener closed
  --- @return string Error message on failure
  close: function(self: Server): boolean, string
end

--- Answer with a bare status and no body, on a connection about to close.
--- Every refusal the loop makes before a handler runs goes out this way,
--- so the head is built by the one place that knows how to build a head.
--- The body is empty either way, so there is nothing here for HEAD's
--- body suppression to suppress.
--- @param conn net.Socket The connection to answer on
--- @param status integer The status code to send
local function refuse(conn: net.Socket, status: integer)
  -- 11 because the answer's status line says HTTP/1.1 in every case;
  -- a refusal carries a length and never streams, so the version this
  -- Response would pick a streaming framing from is never consulted.
  local ex = response.new(conn, 11, true, false)
  ex.response.status = status
  local _ok, _err = ex.response:send("")
end

--- Whether the request rules out reusing the connection.
--- HTTP/1.1 keeps a connection alive unless asked not to; HTTP/1.0 and
--- the version-less HTTP/0.9 close unless the client asked for keep-alive.
--- @param req Request The request to read the intent from
--- @return boolean True when this must be the connection's last exchange
local function closes_connection(req: Request): boolean
  local intent = (req:header("connection") or ""):lower()
  if req.version >= 11 then
    return intent:find("close", 1, true) ~= nil
  end
  return intent:find("keep-alive", 1, true) == nil
end

--- Serve one accepted connection until it is done.
--- The connection is always the loop's to finish: every exit here is a
--- reason to stop reading from this client, never a reason to stop the
--- server, so this reports failure only through the responses it sends.
--- @param conn net.Socket The accepted connection
--- @param peer ip.Addr The client's address
--- @param handler Handler The function every request is handed to
--- @param limits ListenOptions The resolved server limits
local function serve_conn(conn: net.Socket, peer: ip.Addr, handler: Handler,
    limits: ListenOptions)
  local parser = http.parser("request")
  -- Everything received and not yet consumed. It spans requests: bytes
  -- that arrived behind one request's body are the next request's head.
  local buf = ""
  local want_body = 0
  local first = true
  -- A chunked body is decoded before the handler runs, because 413 is
  -- the server's answer and there is no sending one once a handler has
  -- written its own. What `body()` hands back is what was decoded then.
  local decoded_body: string = nil

  local function read_body(): string | nil, string
    if decoded_body ~= nil then
      return decoded_body
    end
    if want_body <= 0 then
      return ""
    end
    while #buf < want_body do
      local chunk, rerr = conn:recv()
      if chunk == nil then
        return nil, rerr or "http: connection closed before the body arrived"
      end
      buf = buf .. chunk
    end
    local body = buf:sub(1, want_body)
    buf = buf:sub(want_body + 1)
    want_body = 0
    return body
  end

  while true do
    decoded_body = nil
    if not first then
      -- One parser reads one head; reset is what makes it the
      -- connection's parser rather than the request's.
      parser:reset()
    end
    first = false

    -- Read until a head completes. parse returns 0 while the head is
    -- still arriving, its length once it is whole, and nil when the
    -- bytes are not an HTTP request at all.
    local head_len = 0
    while head_len == 0 do
      local n, _perr = parser:parse(buf)
      if n == nil then
        refuse(conn, 400)
        return
      end
      head_len = n
      if head_len == 0 then
        if #buf > limits.max_head_bytes then
          refuse(conn, 431)
          return
        end
        local chunk, _rerr = conn:recv()
        if chunk == nil then
          -- End of stream, a timeout, or a broken connection: either
          -- way there is no request here to answer.
          return
        end
        buf = buf .. chunk
      end
    end

    -- The growth check above catches a head that is still arriving; this
    -- one catches a head that arrived whole and is still too big.
    if head_len > limits.max_head_bytes then
      refuse(conn, 431)
      return
    end

    local message = parser:message(buf)
    buf = buf:sub(head_len + 1)

    local req, rerr = request.new(message, peer, read_body)
    if req == nil then
      log.error("http: unparseable request-target", {target = message.uri, error = rerr})
      refuse(conn, 400)
      return
    end

    -- Framing, before the handler: a body this server will not read is
    -- a refusal, and a connection whose framing is undecidable is one
    -- there is no safe next request on.
    local encoding = (req:header("transfer-encoding") or ""):lower()
    local declared = req:header("content-length")
    if encoding:find("chunked", 1, true) then
      if declared ~= nil then
        -- RFC 9112 §6.1: a request framed twice is a request two
        -- recipients may disagree about the length of, which is the
        -- smuggling shape. The server must not pick one of them.
        refuse(conn, 400)
        return
      end
      -- The bytes already buffered are the body's first bytes; anything
      -- past the terminating chunk comes back as the next head.
      local decoded, cerr = request.read_chunked(function(): (string | nil, string)
          return conn:recv()
        end, buf, limits.max_body_bytes)
      if decoded == nil then
        log.error("http: chunked request body", {path = req.path, error = cerr})
        refuse(conn, 400)
        return
      end
      if decoded.oversize then
        refuse(conn, 413)
        return
      end
      buf = decoded.carry
      decoded_body = decoded.body
    elseif declared ~= nil then
      -- RFC 9110 §8.6: Content-Length is 1*DIGIT and nothing else, and a
      -- recipient must treat any other spelling as invalid. `tonumber`
      -- alone would accept "0x5", "0x1p4", "1e2", "10.0" and "+5", and a
      -- proxy that reads one of those differently disagrees with this
      -- server about where the request ends — the request-smuggling
      -- shape. The optional whitespace around a field value is the
      -- parser's to strip and is already gone by here, so a legal
      -- `Content-Length:  5` still reads as "5".
      if declared:match("^%d+$") == nil then
        refuse(conn, 400)
        return
      end
      local length = math.tointeger(tonumber(declared))
      if length == nil or length < 0 then
        refuse(conn, 400)
        return
      end
      if length > limits.max_body_bytes then
        refuse(conn, 413)
        return
      end
      want_body = length
    end

    -- A HEAD answer reports everything a GET would and sends none of
    -- the body; the Response needs to know which it is being written to.
    local head_only = req.method == "HEAD"
    local ex = response.new(conn, req.version, closes_connection(req), head_only)
    -- D30's first boundary: a handler is a Lua protocol whose error
    -- channel IS the throw, so a throwing handler is caught here,
    -- answered with 500, and the connection carries on.
    local ok, thrown = pcall(handler, req, ex.response)
    if not ok then
      log.error("http: handler threw",
        {method = req.method, path = req.path, error = tostring(thrown)})
    elseif not ex:is_finished() then
      -- A refused header is a different bug from a forgotten send, and
      -- the one the handler cannot see unless it checked its send verb.
      log.error(ex:refusal() ~= nil and "http: response header refused"
        or "http: handler sent no response",
        {method = req.method, path = req.path, error = ex:refusal()})
    end
    if not ex:is_finished() then
      -- On a FRESH exchange, not the handler's: the handler's may be
      -- unsendable because a header it set was refused, and its headers
      -- have no business riding the server's own answer in any case.
      local fallback = response.new(conn, req.version, ex:will_close(), head_only)
      fallback.response.status = 500
      local _sok, _serr = fallback.response:send("")
    end

    -- Drain whatever the handler did not read: the next request starts
    -- after this body, and a body still on the wire would be read as one.
    local _drained, derr = req:body()
    if derr ~= nil then
      return
    end
    if ex:will_close() then
      return
    end
  end
end

--- Listen for HTTP on addr:port.
--- Port 0 asks the OS for an ephemeral port; `Server:port()` reports the
--- one it assigned.
---
--- Example — serve one request on an OS-assigned port:
---   local http = require("cosmic.http")
---   local srv = assert(http.listen("127.0.0.1", 0))
---   print(srv:port())
---   assert(srv:serve_one(function(_req: http.Request, res: http.Response)
---     local _ok, _err = res:text("hello\n")
---   end))
---
--- @param addr net.Address Local IPv4 address to bind ("127.0.0.1", "0.0.0.0" for all)
--- @param port integer Local port to bind; 0 for an OS-assigned ephemeral port
--- @param opts ListenOptions? read_timeout_ms, max_body_bytes, max_head_bytes
--- @return Server | nil The listening server, ready to serve
--- @return string Error message on failure
local function listen(addr: net.Address, port: integer, opts?: ListenOptions): Server | nil, string
  local sock, lerr = net.listen_tcp(addr, port)
  if sock == nil then
    return nil, lerr
  end
  local listener = sock
  local endpoint, eerr = listener:local_endpoint()
  if endpoint == nil then
    local _ok, _err = listener:close()
    return nil, eerr
  end
  local bound = endpoint.port
  local limits: ListenOptions = {
    read_timeout_ms = opts and opts.read_timeout_ms or DEFAULTS.read_timeout_ms,
    max_body_bytes = opts and opts.max_body_bytes or DEFAULTS.max_body_bytes,
    max_head_bytes = opts and opts.max_head_bytes or DEFAULTS.max_head_bytes,
  }

  local srv: Server = {}

  function srv:port(): integer
    return bound
  end

  function srv:close(): boolean, string
    return listener:close()
  end

  function srv:serve_one(handler: Handler): boolean, string
    local accepted, aerr = listener:accept()
    if accepted == nil then
      return false, aerr
    end
    local conn = accepted
    local tok, terr = conn:set_timeout_ms(limits.read_timeout_ms)
    if not tok then
      local _ok, _err = conn:close()
      return false, terr
    end
    -- A peer whose address cannot be read is still a peer worth serving;
    -- the handler sees 0.0.0.0 rather than the connection being dropped.
    local client = ip.from_int(0)
    local remote = conn:peer_endpoint()
    if remote ~= nil then
      client = remote.addr
    end
    serve_conn(conn, client, handler, limits)
    local _ok, _err = conn:close()
    return true
  end

  function srv:serve(handler: Handler): boolean, string
    local last: string = nil
    while true do
      local ok, err = self:serve_one(handler)
      if not ok then
        last = err
        break
      end
    end
    return false, last
  end

  return srv
end

local record HttpModule
  --- Type aliases, not runtime values: a `Request: Request` field
  --- spelling would declare phantom fields that are nil at runtime.
  type Request = Request
  type Response = Response
  type Handler = Handler
  type ListenOptions = ListenOptions
  type Server = Server
  listen: function(addr: net.Address, port: integer, opts?: ListenOptions): Server | nil, string
end

local M: HttpModule = {
  listen = listen,
}

return M
