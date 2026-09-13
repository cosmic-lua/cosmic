# http

 HTTP/1.1 server: listen, serve, and the Request/Response a handler sees.
 Wraps cosmo.http and cosmic.net.

 The module owns the socket and the loop; a caller writes one handler
 function and never touches framing. `cosmo.http`'s incremental parser
 reads the head, `cosmic.net` carries the bytes, and everything
 between — the request-target, the header views, `Content-Length`,
 `Date`, the keep-alive decision — is computed here.

 One connection at a time, keep-alive within it. `serve` accepts and
 serves until the listener is closed; `serve_one` does a single
 connection, which is what a test or a caller with its own accept loop
 wants. How more than one connection is served at once is a decision
 this module does not make, and the handler signature is what that
 decision must not change.

 Example — a two-route server:
   local http = require("cosmic.http")
   local srv = assert(http.listen("127.0.0.1", 8080))
   local _stopped, err = srv:serve(function(req: http.Request, res: http.Response)
       if req.path == "/health" then
         local _ok, _err = res:json({ok = true})
       else
         local _ok, _err = res:text("hello " .. req.path)
       end
     end)
   print("stopped: " .. err)

## Types

### ListenOptions

 Server limits, all of them defaults a caller may lower.

```teal
local record ListenOptions
  --  Bound every receive on an accepted connection (default 30000).
  --  A client that stops sending mid-request, or one that holds a
  --  keep-alive connection open without using it, is dropped rather
  --  than allowed to occupy the one connection the server serves.
  read_timeout_ms: integer
  --  Refuse a request body larger than this many bytes with 413
  --  (default 1048576). A declared `Content-Length` is refused before a
  --  byte of the body is read; a `Transfer-Encoding: chunked` body
  --  declares no length, so it is decoded up to this bound and refused
  --  the moment the payload passes it, still before the handler runs.
  --  A chunked body's framing overhead is bounded the same way while it
  --  arrives gradually, but a fast client that lands its whole body,
  --  terminator included, in one read is checked against the decoded
  --  payload only (`cosmic.http.request` has the detail).
  max_body_bytes: integer
  --  Refuse a request head larger than this many bytes with 431
  --  (default 32767, which is as large as a head can be at all:
  --  `ParseHttpMessage` refuses anything longer itself). Raising this
  --  past the default buys nothing — the parser gets the bytes first
  --  and answers a longer head with 400 — so 431 is what a caller who
  --  LOWERS the limit gets, and lowering it is the only useful move.
  max_head_bytes: integer
end
```

### Server

 A listening HTTP server.

```teal
local record Server
  --  Accept and serve connections until the listener fails.
  --  A closed listener — from a signal handler, or another call to
  --  `close` — is what ends this, so it never returns true.
  serve: function(self: Server, handler: Handler): boolean, string
  --  Accept one connection and serve it to completion, then close it.
  --  "To completion" is the whole keep-alive conversation, not one
  --  request: the connection is served until the client closes it, asks
  --  for no more, times out, or sends something unparseable.
  serve_one: function(self: Server, handler: Handler): boolean, string
  --  The port the server is listening on. Read this after listening on
  --  port 0 to learn the port the OS assigned.
  port: function(self: Server): integer
  --  Stop listening. Idempotent; reports the close(2) error.
  close: function(self: Server): boolean, string
end
```

### HttpModule

```teal
local record HttpModule
  listen: function(addr: net.Address, port: integer, opts?: ListenOptions): Server | nil, string
end
```

### Request

 One HTTP/1.1 request, as a handler sees it (see cosmic.http.request).

alias of `cosmic.http.request.Request` — field and method table: `cosmic --docs cosmic.http.request.Request`

### Response

 One HTTP/1.1 response, as a handler writes it (see cosmic.http.response).

alias of `cosmic.http.response.Response` — field and method table: `cosmic --docs cosmic.http.response.Response`

### Handler

 What a server hands every request to. A handler answers by calling a
 send verb on `res`; one that returns without sending gets a 500, and
 one that throws gets a 500 too — a throw is a Lua protocol, not a
 server failure, so the connection survives it.

alias of `function`

## Functions

### listen

```teal
function listen(addr: net.Address, port: integer, opts?: ListenOptions): Server | nil, string
```

 Listen for HTTP on addr:port.
 Port 0 asks the OS for an ephemeral port; `Server:port()` reports the
 one it assigned.
 Example — serve one request on an OS-assigned port:
   local http = require("cosmic.http")
   local srv = assert(http.listen("127.0.0.1", 0))
   print(srv:port())
   assert(srv:serve_one(function(_req: http.Request, res: http.Response)
     local _ok, _err = res:text("hello\n")
   end))

**Parameters:**

- `addr` (net.Address) - Local IPv4 address to bind ("127.0.0.1", "0.0.0.0" for all)
- `port` (integer) - Local port to bind; 0 for an OS-assigned ephemeral port
- `opts` (ListenOptions?) - read_timeout_ms, max_body_bytes, max_head_bytes

**Returns:**

- Server - | nil The listening server, ready to serve
- string - Error message on failure

### srv:port

```teal
function srv:port(): integer
```

### srv:close

```teal
function srv:close(): boolean, string
```

### srv:serve_one

```teal
function srv:serve_one(handler: Handler): boolean, string
```

### srv:serve

```teal
function srv:serve(handler: Handler): boolean, string
```
