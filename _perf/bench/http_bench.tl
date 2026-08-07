--- HTTP client scenarios against a loopback server.
--- A forked child serves fixed HTTP/1.1 responses on 127.0.0.1; the
--- scenarios time the full client path: cosmic.fetch (the cosmo Fetch
--- C binding) and a raw cosmic.net TCP round trip for comparison.
--- The gap between the two is the fetch-layer overhead.

local net = require("cosmic.net")
local fetch = require("cosmic.fetch")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")
local pt = require("_perf.perf_types")

local LOCALHOST = "127.0.0.1"
local BODY = "hello from the perf harness server"
local RESPONSE = "HTTP/1.1 200 OK\r\n"
.. "Content-Type: text/plain\r\n"
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

--- Accept loop run inside the forked server child. Never returns.
--- @param srv Socket The listening socket
local function serve_loop(srv: net.Socket)
  while true do
    local conn = srv:accept()
    if conn then
      local cc = conn
      if read_request(cc) then
        local _ok, _err = cc:send(RESPONSE)
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
  local ep, eperr = lsock:getsockname()
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
      name = "http_fetch_get",
      fn = function(_: any): any
        local resp, err = fetch.fetch(url, {allow_private = true})
        if resp == nil then
          return "fetch failed: " .. tostring(err)
        end
        return resp
      end,
      check = function(_: any, res: any): boolean, string
        if res is string then
          return false, res
        end
        local r = res as fetch.Response -- cast: from any
        if r == nil then
          return false, "no result"
        end
        if r.status ~= 200 then
          return false, "status " .. tostring(r.status)
        end
        if r.body ~= BODY then
          return false, "wrong body"
        end
        return true
      end,
    },
    {
      -- Same request, but with headers set, so validate_headers/
      -- has_forbidden_byte actually run (http_fetch_get passes no
      -- headers, so that scenario never touches this code path at all).
      name = "http_fetch_get_with_headers",
      fn = function(_: any): any
        local resp, err = fetch.fetch(url, {
            allow_private = true,
            headers = {
              ["Accept"] = "application/json",
              ["X-Test"] = "a moderately realistic header value, not just a few bytes",
            },
          })
        if resp == nil then
          return "fetch failed: " .. tostring(err)
        end
        return resp
      end,
      check = function(_: any, res: any): boolean, string
        if res is string then
          return false, res
        end
        local r = res as fetch.Response -- cast: from any
        if r == nil then
          return false, "no result"
        end
        if r.status ~= 200 then
          return false, "status " .. tostring(r.status)
        end
        if r.body ~= BODY then
          return false, "wrong body"
        end
        return true
      end,
    },
    {
      name = "http_tcp_roundtrip",
      fn = function(_: any): any
        local sock, cerr = net.connect_tcp(LOCALHOST, port)
        assert(sock, cerr)
        local ss = sock
        local sent, serr = ss:send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        assert(sent, serr)
        local buf = ""
        while true do
          local data = ss:recv(4096)
          if data == nil or #data == 0 then
            break
          end
          buf = buf .. data
        end
        local _ok, _err = ss:close()
        return buf
      end,
      check = function(_: any, res: any): boolean, string
        local s = res as string -- cast: from any
        if s == nil or not s:find("200 OK", 1, true) then
          return false, "no 200 response"
        end
        if not s:find(BODY, 1, true) then
          return false, "body missing from response"
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
