#!/usr/bin/env cosmic
--- Header normalization tests: repeated response
--- headers must surface as a joined string in result.headers and as an
--- ordered list in result.raw_headers, with lowercase names in both.
local check = require("cosmic.check")
local fetch = require("cosmic.fetch")
local net = require("cosmic.net")
local proc = require("cosmic.proc")

local RESPONSE = "HTTP/1.1 200 OK\r\n"
.. "Content-Type: text/plain\r\n"
.. "Vary: Accept\r\n"
.. "Vary: Origin\r\n"
.. "Content-Length: 2\r\n"
.. "Connection: close\r\n\r\nhi"

--- Fork a loopback server answering n requests with RESPONSE.
local function serve(n: integer): integer, integer
  local srv, port = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local pid = proc.fork()
  if pid == 0 then
    for _ = 1, n do
      local conn = s:accept()
      if conn then
        local c = check.must(conn)
        local buf = ""
        while not buf:find("\r\n\r\n", 1, true) do
          local data = c:recv(4096)
          if not data or #data == 0 then break end
          buf = buf .. data
        end
        c:send(RESPONSE)
        c:close()
      end
    end
    os.exit(0)
  end
  s:close()
  return math.tointeger(port), pid
end

local function test_fetch_repeated_headers_normalized()
  local port, pid = serve(1)
  local result = fetch.fetch("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  proc.wait(pid)
  assert(result.ok == true, "fetch should succeed: " .. tostring(result.error))

  -- headers: lowercase keys, repeats joined ", " — always a plain string
  assert(type(result.headers.vary) == "string",
    "headers.vary must be a string, got " .. type(result.headers.vary))
  assert(result.headers.vary == "Accept, Origin",
    "repeated Vary must join in order, got: " .. tostring(result.headers.vary))
  assert(result.headers["content-type"] == "text/plain",
    "names must be lowercase: content-type, got " .. tostring(result.headers["content-type"]))
  assert(result.headers["Content-Type"] == nil,
    "original-case names must not leak through")
  -- calling a string method on a header value must not crash (the old
  -- nested-table representation made this throw for repeated headers)
  assert(result.headers.vary:lower() == "accept, origin", "string methods must work")

  -- raw_headers: lowercase keys, every value in arrival order
  assert(#result.raw_headers.vary == 2,
    "raw_headers.vary must keep both values, got " .. tostring(#result.raw_headers.vary))
  assert(result.raw_headers.vary[1] == "Accept" and result.raw_headers.vary[2] == "Origin",
    "raw_headers.vary must preserve order")
  assert(#result.raw_headers["content-type"] == 1
    and result.raw_headers["content-type"][1] == "text/plain",
    "single-valued headers appear as one-element lists")
end
test_fetch_repeated_headers_normalized()

local function test_stream_repeated_headers_normalized()
  local port, pid = serve(1)
  local result = fetch.stream("http://127.0.0.1:" .. port .. "/", {allow_private = true})
  assert(result.ok == true, "stream should succeed: " .. tostring(result.error))
  assert(type(result.headers.vary) == "string",
    "stream headers.vary must be a string")
  assert(result.headers.vary == "Accept, Origin",
    "stream repeated Vary must join, got: " .. tostring(result.headers.vary))
  assert(#result.raw_headers.vary == 2, "stream raw_headers.vary must keep both values")
  -- drain and close so the server child can exit
  while result.reader:read() do end
  result.reader:close()
  proc.wait(pid)
end
test_stream_repeated_headers_normalized()
