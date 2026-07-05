--- Streaming HTTP line-iteration against a loopback server.
--- A forked child serves one large multi-line HTTP/1.1 body; the scenario
--- times fetch.stream() + Reader:lines() consuming every line — the path SSE
--- clients drive. The body is big enough that the reader's line-buffering
--- cost (not the loopback transfer) dominates. The check pins the line count
--- and the last line's content, so a buffering bug that drops or corrupts
--- lines fails instead of winning.

local net = require("cosmic.net")
local fetch = require("cosmic.fetch")
local child = require("cosmic.child")
local signal = require("cosmic.signal")
local pt = require("perf.perf_types")

local LOCALHOST = 0x7f000001
local NUM_LINES = 4000

--- Build a deterministic multi-line body, each line newline-terminated.
--- @return string The body
local function build_body(): string
  local lines: {string} = {}
  for i = 1, NUM_LINES do
    lines[i] = string.format(
      "line %05d: the quick brown fox jumps over the lazy dog", i)
  end
  return table.concat(lines, "\n") .. "\n"
end

local BODY = build_body()
local LAST_LINE = string.format(
  "line %05d: the quick brown fox jumps over the lazy dog", NUM_LINES)
local RESPONSE = "HTTP/1.1 200 OK\r\n"
.. "Content-Type: text/plain\r\n"
.. "Content-Length: " .. #BODY .. "\r\n"
.. "Connection: close\r\n\r\n"
.. BODY

local server_pid: number
local listener: net.Socket

--- A single line-iteration outcome, checked after timing.
local record LineStats
  count: integer
  last: string
end

--- Send every byte of data on conn, looping over short writes.
--- @param conn Socket The connection
--- @param data string The bytes to send
--- @return boolean True when all bytes were sent
local function send_all(conn: net.Socket, data: string): boolean
  local off = 1
  local total = #data
  while off <= total do
    local n, _ = conn:send(data:sub(off))
    if n == nil then
      return false
    end
    off = off + (n as integer)
  end
  return true
end

--- Read from a connection until the end of the request headers.
--- @param conn Socket The accepted connection
--- @return boolean True when a full request head was read
local function read_request(conn: net.Socket): boolean
  local buf = ""
  while not buf:find("\r\n\r\n", 1, true) do
    local data = conn:recv(4096)
    if data == nil or #data == 0 then
      return false
    end
    buf = buf .. data
  end
  return true
end

--- Accept loop run inside the forked server child. Never returns.
--- @param srv Socket The listening socket
local function serve_loop(srv: net.Socket)
  while true do
    local conn = srv:accept()
    if conn then
      if read_request(conn) then
        send_all(conn, RESPONSE)
      end
      conn:close()
    end
  end
end

local function scenarios(): {pt.Scenario}, string
  if not fetch.has_stream() then
    -- Streaming primitive absent in this build; nothing to measure.
    return {}
  end
  local srv, port, lerr = net.listen_tcp(LOCALHOST, 0)
  if srv == nil then
    return nil, "listen_tcp: " .. tostring(lerr)
  end
  listener = srv
  local pid = child.fork()
  if pid == 0 then
    serve_loop(srv)
    os.exit(0)
  end
  if pid == nil or pid < 0 then
    return nil, "fork failed"
  end
  server_pid = pid
  -- cosmo.Fetch/FetchStream refuse direct connections to private IPs
  -- (SSRF protection); proxied requests skip that check. Point the proxy
  -- at the loopback server so the full streaming path runs.
  local proxy = "http://127.0.0.1:" .. port
  local url = "http://bench.invalid/"

  return {
    {
      name = "stream_lines_iterate",
      fn = function(_: any): any
        local res = fetch.stream(url, {proxy = proxy})
        if not res.ok then
          return {count = -1, last = tostring(res.error)}
        end
        local reader = res.reader
        local count = 0
        local last: string = nil
        for line in reader:lines() do
          count = count + 1
          last = line
        end
        reader:close()
        local stats: LineStats = {count = count, last = last}
        return stats
      end,
      check = function(_: any, result: any): boolean, string
        local s = result as LineStats
        if s == nil then
          return false, "no result"
        end
        if s.count ~= NUM_LINES then
          return false, "line count " .. tostring(s.count) ..
          " != " .. tostring(NUM_LINES)
        end
        if s.last ~= LAST_LINE then
          return false, "wrong last line: " .. tostring(s.last)
        end
        return true
      end,
    },
  }
end

local function cleanup()
  if server_pid and server_pid > 0 then
    child.kill(server_pid, signal.SIGKILL)
    child.wait(server_pid)
    server_pid = nil
  end
  if listener then
    listener:close()
    listener = nil
  end
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
