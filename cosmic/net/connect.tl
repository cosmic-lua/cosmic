--- The bounded-connect path behind net.ConnectOptions.timeout_ms
--- (an internal shard of cosmic.net; require cosmic.net, not this).
local unix = require("cosmo.unix")
local net_socket = require("cosmic.net.socket")
local errstr = require("cosmic.errno").format
local errno_is = require("cosmic.errno").is_code

local type Socket = net_socket.Socket
local type Address = net_socket.Address

-- Wait for a started non-blocking connect to resolve, up to timeout_ms.
-- Shared by the inet and unix paths, which differ only in the connect(2)
-- call that starts them.
local function await(s: Socket, fd: integer, timeout_ms: integer,
    ok: boolean, err: string, eno: integer): boolean, string
  if ok then return true end
  -- A nonblocking connect that returns EINPROGRESS (or is interrupted,
  -- EINTR) is still pending — poll for the outcome. Any other errno is a
  -- synchronous failure (ECONNREFUSED, ENETUNREACH, ...) and must return
  -- immediately, not be misread as "still connecting".
  if not (errno_is(eno, "EINPROGRESS") or errno_is(eno, "EINTR")) then
    return false, errstr(err, "connect: failed")
  end
  local fds: {integer: integer} = {[fd] = unix.POLLOUT}
  local revents, perr, peno = unix.poll(fds, timeout_ms)
  while revents == nil and errno_is(peno, "EINTR") do
    revents, perr, peno = unix.poll(fds, timeout_ms)
  end
  if not revents then
    return false, errstr(perr, "connect: poll failed")
  end
  local ev = (revents)[fd] or 0
  if ev == 0 then return false, "connect: timed out" end
  if ev & unix.POLLERR ~= 0 then
    local so_err = s:getsockopt(unix.SOL_SOCKET, unix.SO_ERROR)
    return false, "connect: error: " .. tostring(so_err or err)
  end
  if ev & unix.POLLOUT ~= 0 then
    local so_err = s:getsockopt(unix.SOL_SOCKET, unix.SO_ERROR)
    if so_err and so_err ~= 0 then
      return false, "connect: failed: SO_ERROR=" .. tostring(so_err)
    end
    return true
  end
  return false, "connect: unexpected poll events=" .. tostring(ev)
end

-- Switch the socket non-blocking so the connect(2) below returns
-- immediately, and hand back the descriptor to start it on. Leaves the
-- socket non-blocking; dial restores blocking mode on success.
local function begin(s: Socket): integer | nil, string
  local fd = s:fd()
  if fd < 0 then return nil, "socket closed" end
  local nb_ok, nb_err = s:set_nonblocking()
  if not nb_ok then
    return nil, nb_err
  end
  return fd
end

--- The ConnectOptions.timeout_ms path for an inet address.
--- @param s Socket The socket to connect
--- @param addr Address Remote address
--- @param port integer Remote port
--- @param timeout_ms integer? Bound on the attempt (default 10000)
--- @return boolean True once connected
--- @return string Error message on failure
local function with_timeout(s: Socket, addr: Address, port: integer, timeout_ms?: integer): boolean, string
  local fd, ferr = begin(s)
  if not fd then
    return false, ferr
  end
  local raw, aerr = net_socket.resolve_addr(addr)
  if not raw then
    return false, aerr
  end
  -- Bypass Socket:connect to keep the numeric errno, which is what tells
  -- "still connecting" from a synchronous failure.
  local ok, err, eno = unix.connect(fd, raw, port)
  return await(s, fd, timeout_ms or 10000, ok, err, eno)
end

--- The ConnectOptions.timeout_ms path for a unix-domain path.
--- @param s Socket The socket to connect
--- @param path string Filesystem path of the socket
--- @param timeout_ms integer? Bound on the attempt (default 10000)
--- @return boolean True once connected
--- @return string Error message on failure
local function unix_with_timeout(s: Socket, path: string, timeout_ms?: integer): boolean, string
  local fd, ferr = begin(s)
  if not fd then
    return false, ferr
  end
  -- cast: function shape (unix-path overload, errno kept)
  local uconnect = unix.connect as function(number, string): (boolean, string, integer)
  local ok, err, eno = uconnect(fd, path)
  return await(s, fd, timeout_ms or 10000, ok, err, eno)
end

local record NetConnectModule
  with_timeout: function(s: Socket, addr: Address, port: integer, timeout_ms?: integer): boolean, string
  unix_with_timeout: function(s: Socket, path: string, timeout_ms?: integer): boolean, string
end

local M: NetConnectModule = {
  with_timeout = with_timeout,
  unix_with_timeout = unix_with_timeout,
}

return M
