--- Examples for the cosmic.fetch module.
--- Demonstrates HTTP requests, redirects, retry, and streaming — all
--- against a forked loopback server, so the output is deterministic and
--- no external host is contacted. allow_private opts out of the SSRF
--- guard, which otherwise blocks requests to loopback/private addresses.

-- Example_get demonstrates a simple HTTP GET request against a local
-- server: fork a child to answer one request, then fetch from it.
local function Example_get()
  local check = require("cosmic.check")
  local fetch = require("cosmic.fetch")
  local net = require("cosmic.net")
  local proc = require("cosmic.proc")

  local srv, port = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv)
  local pid = check.must(proc.fork())
  if pid == 0 then
    local conn = check.must((s:accept()))
    conn:recv(4096)
    conn:send("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
    conn:close()
    os.exit(0)
  end
  s:close()

  local result = fetch.fetch("http://127.0.0.1:" .. math.tointeger(port) .. "/",
    {allow_private = true})
  proc.wait(pid)
  print(result.status, result.body, result:is_success())
  -- Output:
  -- 200	hello	true
end

-- Example_retry demonstrates the default retry policy: transport errors
-- (dns/connect/timeout) and 429/502/503/504 responses are retried for
-- idempotent methods, with full-jitter exponential backoff. Here the
-- server answers 503 once, then 200; max_attempts = 2 rides it out.
local function Example_retry()
  local check = require("cosmic.check")
  local fetch = require("cosmic.fetch")
  local net = require("cosmic.net")
  local proc = require("cosmic.proc")

  local srv, port = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv)
  local pid = check.must(proc.fork())
  if pid == 0 then
    local responses = {
      "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
    }
    for _, resp in ipairs(responses) do
      local conn = check.must((s:accept()))
      conn:recv(4096)
      conn:send(resp)
      conn:close()
    end
    os.exit(0)
  end
  s:close()

  local result = fetch.fetch("http://127.0.0.1:" .. math.tointeger(port) .. "/", {
      allow_private = true,
      max_attempts = 2,
      base_delay = 0.01, -- keep the example fast; default is 0.5s
    })
  proc.wait(pid)
  print(result.status, result.body)
  -- Output:
  -- 200	ok
end

-- Example_stream_lines demonstrates streaming a response and iterating
-- its lines incrementally instead of buffering the whole body.
local function Example_stream_lines()
  local check = require("cosmic.check")
  local fetch = require("cosmic.fetch")
  local net = require("cosmic.net")
  local proc = require("cosmic.proc")

  local srv, port = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv)
  local pid = check.must(proc.fork())
  if pid == 0 then
    local body = "alpha\nbeta\ngamma\n"
    local conn = check.must((s:accept()))
    conn:recv(4096)
    conn:send("HTTP/1.1 200 OK\r\nContent-Length: " .. #body
      .. "\r\nConnection: close\r\n\r\n" .. body)
    conn:close()
    os.exit(0)
  end
  s:close()

  local result = fetch.stream("http://127.0.0.1:" .. math.tointeger(port) .. "/",
    {allow_private = true})
  for line in result.reader:lines() do
    print(line)
  end
  result.reader:close()
  proc.wait(pid)
  -- Output:
  -- alpha
  -- beta
  -- gamma
end

-- Suppress unused warnings for examples
local _ = {Example_get, Example_retry, Example_stream_lines}
