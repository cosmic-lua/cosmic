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
local server = require("_perf.bench.server")
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

local server_pid: integer | nil
local listener: net.Socket | nil

--- The accept loop; see `_perf/bench/server.tl`.
local function serve_loop(srv: net.Socket)
  while true do
    local conn = srv:accept()
    if conn then
      local cc = conn
      if server.read_request(cc) then
        local _ok = server.send_all(cc, RESPONSE)
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
        if not (res is string) then
          return false, "http_stream_read_1mb: result is not a string"
        end
        local body = res
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
  server_pid, listener = server.cleanup(server_pid, listener)
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
