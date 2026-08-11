--- Streaming HTTP line-iteration against a loopback server.
--- A forked child serves one large multi-line HTTP/1.1 body; the scenario
--- times fetch.stream() + Reader:lines() consuming every line — the path SSE
--- clients drive. The body is big enough that the reader's line-buffering
--- cost (not the loopback transfer) dominates. The check pins the line count
--- and the last line's content, so a buffering bug that drops or corrupts
--- lines fails instead of winning.

local net = require("cosmic.net")
local fetch = require("cosmic.fetch")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local pt = require("_perf.perf_types")

local LOCALHOST = "127.0.0.1"
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

local server_pid: integer
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
    off = off + n
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
      local cc = conn
      if read_request(cc) then
        send_all(cc, RESPONSE)
      end
      local _ok, _err = cc:close()
    end
  end
end

local function scenarios(): {pt.Scenario}, string
  local srv, lerr = net.listen_tcp(LOCALHOST, 0)
  if srv == nil then
    return nil, "listen_tcp: " .. tostring(lerr)
  end
  local lsock = srv
  local ep, eperr = lsock:local_endpoint()
  if ep == nil then
    return nil, "getsockname: " .. tostring(eperr)
  end
  local port = ep.port
  listener = lsock
  local pid, ferr = proc.fork()
  if pid == 0 then
    serve_loop(srv)
    os.exit(0)
  end
  if pid == nil or pid < 0 then
    return nil, "fork failed: " .. tostring(ferr)
  end
  server_pid = pid
  -- allow_private opts out of the SSRF guard so the loopback server is
  -- reachable directly, with no proxy to point at it.
  local url = "http://127.0.0.1:" .. port .. "/"

  return {
    {
      name = "stream_lines_iterate",
      fn = function(_: any): any
        local res, serr = fetch.stream(url, {allow_private = true})
        if res == nil then
          return {count = -1, last = tostring(serr)}
        end
        local reader = res.reader
        local count = 0
        local last: string = nil
        for line in reader:lines() do
          count = count + 1
          last = line
        end
        local _ok, _err = reader:close()
        local stats: LineStats = {count = count, last = last}
        return stats
      end,
      check = function(_: any, result: any): boolean, string
        local s = result as LineStats -- cast: from any
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
    local _ok, _err = signal.kill(server_pid, signal.SIGKILL)
    local _ok, _err = proc.wait(server_pid)
    server_pid = nil
  end
  if listener then
    local _ok, _err = listener:close()
    listener = nil
  end
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
