--- Socket implementation for the networking module.
--- Contains the Socket constructor and all Socket method implementations.
--- Addresses are typed (api-review-2, #588): methods accept a dotted-quad
--- string or an ip.Addr, and return ip.Addr — bare integers are not part
--- of the public surface (wrap C-boundary integers with ip.addr()).
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str
local ip = require("cosmic.ip")

--- An address the socket layer accepts: a dotted-quad string
--- ("127.0.0.1") or a typed ip.Addr.
local type Address = string | ip.Addr

--- Resolve an Address to the raw integer the C bindings take.
--- @param addr Address The address in any accepted form
--- @return integer | nil The IP as an integer, or nil on error
--- @return string Error message on failure
local function resolve_addr(addr: Address): integer | nil, string
  if addr is string then
    local a, err = ip.parse(addr)
    if not a then
      return nil, err
    end
    return math.tointeger((a as ip.Addr):int())
  end
  return math.tointeger((addr as ip.Addr):int())
end

--- Socket handle for network I/O.
--- Sockets are BLOCKING by default: recv and accept wait until data or a
--- connection arrives. Supports Lua 5.4's to-be-closed via __close.
local record Socket
  --- The underlying file descriptor.
  fd: number
  --- Close the socket.
  close: function(self: Socket): boolean
  --- True when the socket has been closed.
  closed: function(self: Socket): boolean
  --- Shut down reading and/or writing (unix.SHUT_RD/WR/RDWR).
  shutdown: function(self: Socket, how?: number): boolean, string
  --- Send data; returns bytes sent, or nil + error.
  send: function(self: Socket, data: string, flags?: number): number | nil, string
  --- Send a datagram to addr:port; returns bytes sent, or nil + error.
  sendto: function(self: Socket, data: string, addr: Address, port: number, flags?: number): number | nil, string
  --- Receive up to bufsiz bytes (blocks until data arrives).
  --- Returns bare nil (no error) when the peer closed the connection —
  --- end of stream, matching the stream contract (cosmic.stream). ""
  --- is only ever a zero-byte datagram on message sockets. Returns
  --- nil + error message on failure. bufsiz must be positive when
  --- given (default 65536).
  recv: function(self: Socket, bufsiz?: number, flags?: number): string | nil, string
  --- Receive a datagram; returns data, sender Addr, sender port.
  recvfrom: function(self: Socket, bufsiz?: number, flags?: number): string | nil, ip.Addr, number, string
  --- Local address as (Addr, port); use after bind for the real port.
  getsockname: function(self: Socket): ip.Addr | nil, number, string
  --- Peer address as (Addr, port).
  getpeername: function(self: Socket): ip.Addr | nil, number, string
  --- Bind to a local addr:port (default all interfaces, OS-assigned port).
  bind: function(self: Socket, addr?: Address, port?: number): boolean, string
  --- Bind to a unix-domain socket path.
  bind_unix: function(self: Socket, path: string): boolean, string
  --- Start listening for connections.
  listen: function(self: Socket, backlog?: number): boolean, string
  --- Accept one connection (blocks until a client connects).
  --- Returns the connection socket, peer Addr, peer port.
  accept: function(self: Socket, flags?: number): Socket | nil, ip.Addr, number, string
  --- Connect to addr:port.
  connect: function(self: Socket, addr: Address, port: number): boolean, string
  --- Connect to a unix-domain socket path.
  connect_unix: function(self: Socket, path: string): boolean, string
  --- Read a socket option value.
  getsockopt: function(self: Socket, level: number, optname: number): number | boolean | nil, string
  --- Set a socket option value.
  setsockopt: function(self: Socket, level: number, optname: number, value: number | boolean): boolean, string
  --- Switch O_NONBLOCK on (default) or off for this socket.
  set_nonblocking: function(self: Socket, enable?: boolean): boolean, string
end

--- Create a socket handle from a file descriptor.
--- @param fd number The file descriptor
--- @return Socket The socket handle
local function make_socket(fd: number): Socket
  local sock: Socket = {fd = fd}

  -- macOS honors SO_NOSIGPIPE, not MSG_NOSIGNAL, on send(); set it once at
  -- creation so writes there get EPIPE instead of a fatal SIGPIPE. The
  -- constant is 0 on platforms that use MSG_NOSIGNAL instead (Linux,
  -- OpenBSD, Windows), so the guard skips them.
  if unix.SO_NOSIGPIPE ~= nil and unix.SO_NOSIGPIPE ~= 0 then
    unix.setsockopt(fd, unix.SOL_SOCKET, unix.SO_NOSIGPIPE, true)
  end

  function sock:close(): boolean
    if self.fd then
      local ok = unix.close(self.fd)
      self.fd = nil
      return ok
    end
    return true
  end

  function sock:closed(): boolean
    return self.fd == nil
  end

  function sock:shutdown(how?: number): boolean, string
    if not self.fd then return false, "socket closed" end
    how = how or unix.SHUT_RDWR
    local ok, err = unix.shutdown(self.fd, how)
    if not ok then
      return false, errstr(err, "shutdown")
    end
    return true
  end

  -- Always suppress SIGPIPE on writes: a peer that disconnects mid-response
  -- would otherwise kill the whole process (exit 141) instead of returning an
  -- EPIPE error the caller can handle. cosmo maps MSG_NOSIGNAL to the native
  -- per-OS flag, so ORing it in is portable.
  function sock:send(data: string, flags?: number): number | nil, string
    if not self.fd then return nil, "socket closed" end
    local n, err = unix.send(self.fd, data, (flags or 0) | unix.MSG_NOSIGNAL)
    if not n then
      return nil, errstr(err, "send")
    end
    return n
  end

  function sock:sendto(data: string, addr: Address, port: number, flags?: number): number | nil, string
    if not self.fd then return nil, "socket closed" end
    local raw, aerr = resolve_addr(addr)
    if not raw then
      return nil, aerr
    end
    local n, err = unix.sendto(self.fd, data, raw, port, (flags or 0) | unix.MSG_NOSIGNAL)
    if not n then
      return nil, errstr(err, "sendto")
    end
    return n
  end

  -- Whether this socket is a message (datagram) socket; resolved on the
  -- first empty recv and cached, so the common stream path pays nothing.
  local dgram: boolean = nil

  function sock:recv(bufsiz?: number, flags?: number): string | nil, string
    if not self.fd then return nil, "socket closed" end
    local data, err = unix.recv(self.fd, bufsiz or 65536, flags or 0)
    if not data then
      return nil, errstr(err, "recv")
    end
    if data == "" then
      if dgram == nil then
        dgram = self:getsockopt(unix.SOL_SOCKET, unix.SO_TYPE) == unix.SOCK_DGRAM
      end
      if not dgram then
        return nil -- peer closed: end of stream (api-review-2, #589)
      end
    end
    return data
  end

  function sock:recvfrom(bufsiz?: number, flags?: number): string | nil, ip.Addr, number, string
    if not self.fd then return nil, nil, nil, "socket closed" end
    local data, sender, port = unix.recvfrom(self.fd, bufsiz or 65536, flags or 0)
    if not data then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the sender ip would have been.
      return nil, nil, nil, errstr(sender, "recvfrom")
    end
    return data, ip.addr(sender), port
  end

  function sock:getsockname(): ip.Addr | nil, number, string
    if not self.fd then return nil, nil, "socket closed" end
    local raw, port = unix.getsockname(self.fd)
    if not raw then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the port would have been.
      return nil, nil, errstr(port, "getsockname")
    end
    return ip.addr(raw), port
  end

  function sock:getpeername(): ip.Addr | nil, number, string
    if not self.fd then return nil, nil, "socket closed" end
    local raw, port = unix.getpeername(self.fd)
    if not raw then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the port would have been.
      return nil, nil, errstr(port, "getpeername")
    end
    return ip.addr(raw), port
  end

  function sock:bind(addr?: Address, port?: number): boolean, string
    if not self.fd then return false, "socket closed" end
    local raw: integer = 0
    if addr ~= nil then
      local r, aerr = resolve_addr(addr)
      if not r then
        return false, aerr
      end
      raw = r
    end
    local ok, err = unix.bind(self.fd, raw, port or 0)
    if not ok then
      return false, errstr(err, "bind")
    end
    return true
  end

  function sock:bind_unix(path: string): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok, err = (unix.bind as function(number, string): (boolean, string))(self.fd, path)
    if not ok then
      return false, errstr(err, "bind_unix: " .. path)
    end
    return true
  end

  function sock:listen(backlog?: number): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok, err = unix.listen(self.fd, backlog or 128)
    if not ok then
      return false, errstr(err, "listen")
    end
    return true
  end

  function sock:accept(flags?: number): Socket | nil, ip.Addr, number, string
    if not self.fd then return nil, nil, nil, "socket closed" end
    local clientfd, peer, port = unix.accept(self.fd, flags or 0)
    if not clientfd then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the peer ip would have been.
      return nil, nil, nil, errstr(peer, "accept")
    end
    return make_socket(clientfd), ip.addr(peer), port
  end

  function sock:connect(addr: Address, port: number): boolean, string
    if not self.fd then return false, "socket closed" end
    local raw, aerr = resolve_addr(addr)
    if not raw then
      return false, aerr
    end
    local ok, err = unix.connect(self.fd, raw, port)
    if not ok then
      return false, errstr(err, "connect")
    end
    return true
  end

  function sock:connect_unix(path: string): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok, err = (unix.connect as function(number, string): (boolean, any))(self.fd, path)
    if not ok then
      return false, errstr(err, "connect_unix")
    end
    return true
  end

  function sock:getsockopt(level: number, optname: number): number | boolean | nil, string
    if not self.fd then return nil, "socket closed" end
    local val, err = unix.getsockopt(self.fd, level, optname)
    if val == nil then
      return nil, errstr(err, "getsockopt")
    end
    return val
  end

  function sock:set_nonblocking(enable?: boolean): boolean, string
    if not self.fd then return false, "socket closed" end
    -- unix.fcntl coerces F_GETFL's result to a boolean, so the current
    -- flags cannot be read back. Sockets carry no other fcntl status
    -- flag worth preserving, so set the flag word absolutely.
    local want: integer = 0
    if enable ~= false then
      want = unix.O_NONBLOCK as integer
    end
    local ok, serr = unix.fcntl(self.fd, unix.F_SETFL, want)
    if not ok then
      return false, errstr(serr, "set_nonblocking")
    end
    return true
  end

  function sock:setsockopt(level: number, optname: number, value: number | boolean): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok, err = unix.setsockopt(self.fd, level, optname, value)
    if not ok then
      return false, errstr(err, "setsockopt")
    end
    return true
  end

  return setmetatable(sock, {
      __close = function(self: Socket) self:close() end
    }) as Socket
end

local record NetSocketModule
  type Socket = Socket
  type Address = Address
  make_socket: function(fd: number): Socket
end

local M: NetSocketModule = {
  make_socket = make_socket,
}

return M
