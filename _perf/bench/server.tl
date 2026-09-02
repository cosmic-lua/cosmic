--- Shared loopback-server helpers for the HTTP-shaped bench modules
--- (download_bench, http_bench, stream_bench): reading a request off an
--- accepted connection, writing a response back in full, and tearing
--- down the forked server child once a run is done.

local net = require("cosmic.net")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")

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

--- Kill the forked server child and close its listening socket; a nil pid
--- or listener (never set, or already cleared) is a no-op for that half.
--- @param pid integer | nil The forked server's pid, or nil if none was set
--- @param listener Socket | nil The listening socket, or nil if none was set
--- @return integer | nil Always nil, so the caller can reset its pid field
--- @return net.Socket | nil Always nil, so the caller can reset its listener field
local function cleanup(pid: integer | nil, listener: net.Socket | nil): integer | nil, net.Socket | nil
  if pid and pid > 0 then
    local _ok, _err = signal.kill(pid, signal.SIGKILL)
    local _ok, _err = proc.wait(pid)
  end
  if listener then
    local _ok, _err = listener:close()
  end
  return nil, nil
end

local record server
  read_request: function(net.Socket): boolean
  send_all: function(net.Socket, string): boolean
  cleanup: function(integer | nil, net.Socket | nil): integer | nil, net.Socket | nil
end

local M: server = {
  read_request = read_request,
  send_all = send_all,
  cleanup = cleanup,
}

return M
