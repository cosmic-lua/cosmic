--- HTTP streaming throughput against a loopback server.
--- http_fetch_get is small-response latency and stream_lines_iterate
--- is line-splitting; neither measures bulk chunked reads. A forked
--- child serves a 1 MiB body; the scenario times fetch.stream() plus
--- the Reader chunk loop and materializes the body — the shape of a
--- real download. The check compares the whole body byte-for-byte, so
--- a reader that drops, reorders, or corrupts a chunk fails instead
--- of winning.

local net = require("cosmic.net")
local fetch = require("cosmic.fetch")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local pt = require("_perf.perf_types")

local LOCALHOST = "127.0.0.1"
local CHUNK_LINES = 16384

--- Build the deterministic 1 MiB body: CHUNK_LINES lines of exactly
--- 64 bytes each.
--- @return string The body
local function build_body(): string
  local pad = string.rep("x", 50)
  local lines: {string} = {}
  for i = 1, CHUNK_LINES do
    lines[i] = string.format("chunk %06d %s\n", i, pad)
  end
  return table.concat(lines)
end

local BODY = build_body()
local RESPONSE = "HTTP/1.1 200 OK\r\n"
.. "Content-Type: application/octet-stream\r\n"
.. "Content-Length: " .. #BODY .. "\r\n"
.. "Connection: close\r\n\r\n"
.. BODY

local server_pid: integer
local listener: net.Socket

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

--- Accept loop run inside the forked server child. Never returns.
--- @param srv Socket The listening socket
local function serve_loop(srv: net.Socket)
  while true do
    local conn = srv:accept()
    if conn then
      local cc = conn
      if read_request(cc) then
        local _ok = send_all(cc, RESPONSE)
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
      name = "http_stream_read_1mb",
      fn = function(_: any): any
        local res, serr = fetch.stream(url, {allow_private = true})
        if res == nil then
          return "stream failed: " .. tostring(serr)
        end
        local reader = res.reader
        local parts: {string} = {}
        while true do
          local chunk, rerr = reader:read()
          if rerr then
            local _ok = reader:close()
            return "read failed: " .. tostring(rerr)
          end
          if chunk == nil then
            break
          end
          parts[#parts + 1] = chunk
        end
        local _ok = reader:close()
        return table.concat(parts)
      end,
      check = function(_: any, res: any): boolean, string
        local body = res as string -- cast: from any
        if body == nil then
          return false, "no result"
        end
        if #body ~= #BODY then
          return false, string.format("got %d bytes, want %d", #body, #BODY)
        end
        if body ~= BODY then
          return false, "body content mismatch"
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
