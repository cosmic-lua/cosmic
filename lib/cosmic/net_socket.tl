--- Socket implementation for the networking module.
--- Contains the Socket constructor and all Socket method implementations.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

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
  send: function(self: Socket, data: string, flags?: number): number, string
  --- Send a datagram to ip:port; returns bytes sent, or nil + error.
  sendto: function(self: Socket, data: string, ip: number, port: number, flags?: number): number, string
  --- Receive up to bufsiz bytes (blocks until data arrives).
  --- Returns "" (empty string) with no error when the peer closed the
  --- connection (EOF); returns nil + error message on failure.
  recv: function(self: Socket, bufsiz?: number, flags?: number): string, string
  --- Receive a datagram; returns data, sender ip, sender port.
  recvfrom: function(self: Socket, bufsiz?: number, flags?: number): string, number, number, string
  --- Local address as (ip, port); use after bind(0) for the real port.
  getsockname: function(self: Socket): number, number, string
  --- Peer address as (ip, port).
  getpeername: function(self: Socket): number, number, string
  --- Bind to a local ip:port (integers; port 0 = OS-assigned).
  bind: function(self: Socket, ip?: number, port?: number): boolean, string
  --- Bind to a unix-domain socket path.
  bind_unix: function(self: Socket, path: string): boolean, string
  --- Start listening for connections.
  listen: function(self: Socket, backlog?: number): boolean, string
  --- Accept one connection (blocks until a client connects).
  --- Returns the connection socket, peer ip, peer port.
  accept: function(self: Socket, flags?: number): Socket, number, number, string
  --- Connect to ip:port (integers; see cosmic.ip.parse for strings).
  connect: function(self: Socket, ip: number, port: number): boolean, string
  --- Connect to a unix-domain socket path.
  connect_unix: function(self: Socket, path: string): boolean, string
  --- Read a socket option value.
  getsockopt: function(self: Socket, level: number, optname: number): number | boolean, string
  --- Set a socket option value.
  setsockopt: function(self: Socket, level: number, optname: number, value: number | boolean): boolean, string
end

--- Create a socket handle from a file descriptor.
--- @param fd number The file descriptor
--- @return Socket The socket handle
local function make_socket(fd: number): Socket
  local sock: Socket = {fd = fd}

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
    local ok = unix.shutdown(self.fd, how)
    if not ok then
      return false, "shutdown failed"
    end
    return true
  end

  -- Always suppress SIGPIPE on writes: a peer that disconnects mid-response
  -- would otherwise kill the whole process (exit 141) instead of returning an
  -- EPIPE error the caller can handle. cosmo maps MSG_NOSIGNAL to the native
  -- per-OS flag, so ORing it in is portable.
  function sock:send(data: string, flags?: number): number, string
    if not self.fd then return nil, "socket closed" end
    local n = unix.send(self.fd, data, (flags or 0) | unix.MSG_NOSIGNAL)
    if not n then
      return nil, "send failed"
    end
    return n
  end

  function sock:sendto(data: string, ip: number, port: number, flags?: number): number, string
    if not self.fd then return nil, "socket closed" end
    local n = unix.sendto(self.fd, data, ip, port, (flags or 0) | unix.MSG_NOSIGNAL)
    if not n then
      return nil, "sendto failed"
    end
    return n
  end

  function sock:recv(bufsiz?: number, flags?: number): string, string
    if not self.fd then return nil, "socket closed" end
    local data = unix.recv(self.fd, bufsiz or 65536, flags or 0)
    if not data then
      return nil, "recv failed"
    end
    return data
  end

  function sock:recvfrom(bufsiz?: number, flags?: number): string, number, number, string
    if not self.fd then return nil, nil, nil, "socket closed" end
    local data, ip, port = unix.recvfrom(self.fd, bufsiz or 65536, flags or 0)
    if not data then
      return nil, nil, nil, "recvfrom failed"
    end
    return data, ip, port
  end

  function sock:getsockname(): number, number, string
    if not self.fd then return nil, nil, "socket closed" end
    local ip, port = unix.getsockname(self.fd)
    if not ip then
      return nil, nil, "getsockname failed"
    end
    return ip, port
  end

  function sock:getpeername(): number, number, string
    if not self.fd then return nil, nil, "socket closed" end
    local ip, port = unix.getpeername(self.fd)
    if not ip then
      return nil, nil, "getpeername failed"
    end
    return ip, port
  end

  function sock:bind(ip?: number, port?: number): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok = unix.bind(self.fd, ip or 0, port or 0)
    if not ok then
      return false, "bind failed"
    end
    return true
  end

  function sock:bind_unix(path: string): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok = (unix.bind as function(number, string): boolean)(self.fd, path)
    if not ok then
      return false, "bind_unix failed"
    end
    return true
  end

  function sock:listen(backlog?: number): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok = unix.listen(self.fd, backlog or 128)
    if not ok then
      return false, "listen failed"
    end
    return true
  end

  function sock:accept(flags?: number): Socket, number, number, string
    if not self.fd then return nil, nil, nil, "socket closed" end
    local clientfd, ip, port = unix.accept(self.fd, flags or 0)
    if not clientfd then
      return nil, nil, nil, "accept failed"
    end
    return make_socket(clientfd), ip, port
  end

  function sock:connect(ip: number, port: number): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok, err = unix.connect(self.fd, ip, port)
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

  function sock:getsockopt(level: number, optname: number): number | boolean, string
    if not self.fd then return nil, "socket closed" end
    local val = unix.getsockopt(self.fd, level, optname)
    if val == nil then
      return nil, "getsockopt failed"
    end
    return val
  end

  function sock:setsockopt(level: number, optname: number, value: number | boolean): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok = unix.setsockopt(self.fd, level, optname, value)
    if not ok then
      return false, "setsockopt failed"
    end
    return true
  end

  return setmetatable(sock, {
      __close = function(self: Socket) self:close() end
    }) as Socket
end

local record NetSocketModule
  make_socket: function(fd: number): Socket
end

local M: NetSocketModule = {
  make_socket = make_socket,
}

return M
