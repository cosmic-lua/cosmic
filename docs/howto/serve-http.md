# Serve HTTP by hand

steps for answering HTTP/1.1 over a `cosmic.net` socket and calling it
with `cosmic.fetch`, for a reader who knows sockets.

there is no HTTP server module. at this scale HTTP/1.1 is a request
line, a header drain, and a `Content-Length` you compute. serve it by
hand over a `net` socket, and let `cosmic.fetch` be the client: it has
retries, redirects and streaming. `cosmic --docs http` does not find
this page. its matches are proxy internals and `time.format_http`, and
none of them is a server.

## serve one request

1. listen with `net.listen_tcp("127.0.0.1", 0)`. port 0 asks the OS
   for a free port; read it back from `srv:local_endpoint().port`.
2. print `READY <port>`, so a parent process can block on the line.
3. accept a connection. `accept`'s error is in slot 2.
4. read the request line. a `net.Socket` is a `stream.Reader`, so
   `stream.lines(conn)` reads lines. it splits on `\n` and leaves
   HTTP's `\r` on the end; strip it yourself.
5. drain the headers. the blank line ends them.
6. send the response with `send_all`. compute `Content-Length` from
   the body, send `Connection: close`, then close the socket.
7. return the send result. the close result is not the verdict.

```teal
local check = require("cosmic.check")
local net = require("cosmic.net")
local stream = require("cosmic.stream")

-- serve one request: read the request line, drain headers, answer
-- with a computed Content-Length. loop it for a real server.
local function serve_one(srv: net.Socket): boolean, string
  local conn, accept_err = srv:accept()
  if not conn then
    return false, accept_err
  end
  -- stream.lines splits on "\n" and leaves HTTP's "\r" on the end.
  local next_line = stream.lines(conn)
  local function crlf_line(): string | nil
    local line = next_line()
    if line == nil then return nil end
    return (line:gsub("\r$", ""))
  end
  local request_line = crlf_line()
  local path = "/"
  if request_line is string then
    path = request_line:match("^%u+%s+(%S+)") or "/"
  end
  while true do
    local header = crlf_line()
    if not header or header == "" then break end -- blank line ends headers
  end
  local body = "hello from " .. path .. "\n"
  local ok, send_err = conn:send_all("HTTP/1.1 200 OK\r\n"
    .. "Content-Length: " .. #body .. "\r\n"
    .. "Connection: close\r\n\r\n" .. body)
  local _ok, _err = conn:close() -- the send result is the verdict
  return ok, send_err
end

local srv = check.must(net.listen_tcp("127.0.0.1", 0))
print("READY " .. check.must(srv:local_endpoint()).port)
assert(serve_one(srv))
assert(srv:close())
```

## call it with `cosmic.fetch`

`fetch.fetch(url, {allow_private = true})` makes the request in one
call. the returned record carries `status`, `body` and `headers`.
`allow_private` opts out of the guard that otherwise refuses loopback
and private addresses. this example forks the server half instead of
spawning it:

```teal example=cosmic/fetch/init_example.tl#Example_get
local check = require("cosmic.check")
local fetch = require("cosmic.fetch")
local net = require("cosmic.net")
local proc = require("cosmic.proc")

local srv = net.listen_tcp("127.0.0.1", 0)
local s = check.must(srv)
local port = check.must(s:local_endpoint()).port
local pid = check.must(proc.fork())
if pid == 0 then
  local conn = check.must(s:accept())
  assert(conn:recv(4096))
  assert(conn:send("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"))
  assert(conn:close())
  os.exit(0)
end
assert(s:close())

local result = check.must(fetch.fetch(
    "http://127.0.0.1:" .. math.tointeger(port) .. "/",
    {allow_private = true}))
assert(proc.wait(pid))
print(result.status, result.body, result:is_success())
-- Output:
-- 200	hello	true
```

## test the pair end to end

1. build the server binary. `--make test` builds binaries before tests
   run.
2. from the test, spawn `o/bin/<name>` with `child.start`.
3. block on the `READY <port>` line. `cosmic --docs howto.spawn-child`
   has that step.
4. call `fetch.fetch("http://127.0.0.1:<port>/", {allow_private = true})`
   and assert on `status` and `body`.
5. stop the child and wait for it.

the test sandbox grants loopback TCP and exec. bind port 0 and use the
assigned port; never hardcode one. `cosmic --docs howto.test` has the
sandbox's rules.

## the TCP echo pair

the same socket calls without HTTP framing. listen on an OS-assigned
port, dial, accept, then `send` and `recv`:

```teal example=cosmic/net/init_example.tl#Example_echo
local net = require("cosmic.net")
local check = require("cosmic.check")
local srv = check.must(net.listen_tcp("127.0.0.1", 0))
local port = check.must(srv:local_endpoint()).port
assert(port > 0)

local client = check.must(net.dial("127.0.0.1", port))

-- accept's error is in slot 2, so must() forwards it directly.
local conn = check.must(srv:accept())

assert(client:send("hello"))
local msg = check.must(conn:recv())
assert(conn:send("echo: " .. msg))
print(check.must(client:recv()))

assert(client:close())
assert(conn:close())
assert(srv:close())
-- Output:
-- echo: hello
```

`recv` returns bare nil when the peer closes the connection. `""` only
ever means a zero-byte datagram:

```teal example=cosmic/net/init_example.tl#Example_recv_eof
local net = require("cosmic.net")
local check = require("cosmic.check")
local srv = check.must(net.listen_tcp("127.0.0.1", 0))
local port = check.must(srv:local_endpoint()).port

local client = check.must(net.dial("127.0.0.1", port))
local conn = check.must(srv:accept())

assert(client:close())
local data, recv_err = conn:recv()
assert(recv_err == nil)
print(data == nil and "eof" or "data")

assert(conn:close())
assert(srv:close())
-- Output:
-- eof
```

`cosmic --docs cosmic.net`, `cosmic --docs cosmic.fetch` and
`cosmic --docs cosmic.stream` have the signatures.
