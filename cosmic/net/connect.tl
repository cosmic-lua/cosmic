--- The bounded-connect path behind net.ConnectOptions.timeout_ms
--- (an internal shard of cosmic.net; require cosmic.net, not this).
local unix = require("cosmo.unix")
local net_socket = require("cosmic.net.socket")
local errstr = require("cosmic.errno").wrap
local errno_is = require("cosmic.errno").is

local type Socket = net_socket.Socket
local type Address = net_socket.Address

-- The ConnectOptions.timeout_ms path: switch the socket non-blocking,
-- start the connect, poll for the outcome up to timeout_ms (default
-- 10000). Leaves the socket non-blocking; connect_tcp restores
-- blocking mode on success.
local function with_timeout(s: Socket, addr: Address, port: integer, timeout_ms?: integer): boolean, string
  timeout_ms = timeout_ms or 10000
  if not s.fd then return false, "socket closed" end
  local nb_ok, nb_err = s:set_nonblocking()
  if not nb_ok then
    return false, nb_err
  end
  local raw, aerr = net_socket.resolve_addr(addr)
  if not raw then
    return false, aerr
  end
  -- Bypass Socket:connect to keep the numeric errno: a nonblocking connect
  -- that returns EINPROGRESS (or is interrupted, EINTR) is still pending —
  -- poll for the outcome. Any other errno is a synchronous failure
  -- (ECONNREFUSED, ENETUNREACH, ...) and must return immediately, not be
  -- misread as "still connecting".
  local ok, err, eno = unix.connect(s.fd, raw, port)
  if ok then return true end
  if not (errno_is(eno, "EINPROGRESS") or errno_is(eno, "EINTR")) then
    return false, errstr(err, "connect: failed")
  end
  local fds: {integer: integer} = {[s.fd] = unix.POLLOUT}
  local revents, perr, peno = unix.poll(fds, timeout_ms)
  while revents == nil and errno_is(peno, "EINTR") do
    revents, perr, peno = unix.poll(fds, timeout_ms)
  end
  if not revents then
    return false, errstr(perr, "connect: poll failed")
  end
  local ev = (revents as {integer: integer})[s.fd] or 0 -- cast: record union after guard
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

local record NetConnectModule
  with_timeout: function(s: Socket, addr: Address, port: integer, timeout_ms?: integer): boolean, string
end

local M: NetConnectModule = {
  with_timeout = with_timeout,
}

return M
