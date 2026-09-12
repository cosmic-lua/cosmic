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
  --- (default 1048576). The refusal happens on the declared
  --- `Content-Length`, before a byte of the body is read.
  max_body_bytes: integer
  --- Refuse a request head larger than this many bytes with 431
  --- (default 32768, `ParseHttpMessage`'s own SHRT_MAX ceiling).
  max_head_bytes: integer
end

local DEFAULTS: ListenOptions = {
  read_timeout_ms = 30000,
  max_body_bytes = 1048576,
  max_head_bytes = 32768,
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
--- @param conn net.Socket The connection to answer on
--- @param status integer The status code to send
local function refuse(conn: net.Socket, status: integer)
  local ex = response.new(conn, true)
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

  local function read_body(): string | nil, string
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
    if encoding:find("chunked", 1, true) then
      refuse(conn, 411)
      return
    end
    local declared = req:header("content-length")
    if declared ~= nil then
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

    local ex = response.new(conn, closes_connection(req))
    -- D30's first boundary: a handler is a Lua protocol whose error
    -- channel IS the throw, so a throwing handler is caught here,
    -- answered with 500, and the connection carries on.
    local ok, thrown = pcall(handler, req, ex.response)
    if not ok then
      log.error("http: handler threw",
        {method = req.method, path = req.path, error = tostring(thrown)})
    elseif not ex:is_finished() then
      log.error("http: handler sent no response",
        {method = req.method, path = req.path})
    end
    if not ex:is_finished() then
      ex.response.status = 500
      local _sok, _serr = ex.response:send("")
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
