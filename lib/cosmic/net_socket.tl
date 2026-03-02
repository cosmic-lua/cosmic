--- Socket implementation for the networking module.
--- Contains the Socket constructor and all Socket method implementations.
local unix = require("cosmo.unix")
local Errno = require("cosmic.errno").Errno

--- Socket handle for network I/O.
--- Supports Lua 5.4's to-be-closed via __close metamethod.
local record Socket
  fd: number
  close: function(self: Socket): boolean
  closed: function(self: Socket): boolean
  shutdown: function(self: Socket, how?: number): boolean, string
  send: function(self: Socket, data: string, flags?: number): number, string
  sendto: function(self: Socket, data: string, ip: number, port: number, flags?: number): number, string
  recv: function(self: Socket, bufsiz?: number, flags?: number): string, string
  recvfrom: function(self: Socket, bufsiz?: number, flags?: number): string, number, number, string
  getsockname: function(self: Socket): number, number, string
  getpeername: function(self: Socket): number, number, string
  bind: function(self: Socket, ip?: number, port?: number): boolean, string
  bind_unix: function(self: Socket, path: string): boolean, string
  listen: function(self: Socket, backlog?: number): boolean, string
  accept: function(self: Socket, flags?: number): Socket, number, number, string
  connect: function(self: Socket, ip: number, port: number): boolean, string
  connect_unix: function(self: Socket, path: string): boolean, string
  getsockopt: function(self: Socket, level: number, optname: number): number | boolean, string
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
    how = how or unix.SHUT_RDWR
    local ok = unix.shutdown(self.fd, how)
    if not ok then
      return false, "shutdown failed"
    end
    return true
  end

  function sock:send(data: string, flags?: number): number, string
    local n = unix.send(self.fd, data, flags or 0)
    if not n then
      return nil, "send failed"
    end
    return n
  end

  function sock:sendto(data: string, ip: number, port: number, flags?: number): number, string
    local n = unix.sendto(self.fd, data, ip, port, flags or 0)
    if not n then
      return nil, "sendto failed"
    end
    return n
  end

  function sock:recv(bufsiz?: number, flags?: number): string, string
    local data = unix.recv(self.fd, bufsiz or 65536, flags or 0)
    if not data then
      return nil, "recv failed"
    end
    return data
  end

  function sock:recvfrom(bufsiz?: number, flags?: number): string, number, number, string
    local data, ip, port = unix.recvfrom(self.fd, bufsiz or 65536, flags or 0)
    if not data then
      return nil, nil, nil, "recvfrom failed"
    end
    return data, ip, port
  end

  function sock:getsockname(): number, number, string
    local ip, port = unix.getsockname(self.fd)
    if not ip then
      return nil, nil, "getsockname failed"
    end
    return ip, port
  end

  function sock:getpeername(): number, number, string
    local ip, port = unix.getpeername(self.fd)
    if not ip then
      return nil, nil, "getpeername failed"
    end
    return ip, port
  end

  function sock:bind(ip?: number, port?: number): boolean, string
    local ok = unix.bind(self.fd, ip or 0, port or 0)
    if not ok then
      return false, "bind failed"
    end
    return true
  end

  function sock:bind_unix(path: string): boolean, string
    local ok = (unix.bind as function(number, string): boolean)(self.fd, path)
    if not ok then
      return false, "bind_unix failed"
    end
    return true
  end

  function sock:listen(backlog?: number): boolean, string
    local ok = unix.listen(self.fd, backlog or 128)
    if not ok then
      return false, "listen failed"
    end
    return true
  end

  function sock:accept(flags?: number): Socket, number, number, string
    local clientfd, ip, port = unix.accept(self.fd, flags or 0)
    if not clientfd then
      return nil, nil, nil, "accept failed"
    end
    return make_socket(clientfd), ip, port
  end

  function sock:connect(ip: number, port: number): boolean, string
    local ok, err = unix.connect(self.fd, ip, port) as(boolean, any)
    if not ok then
      if err then
        local errno = err as Errno
        if errno.doc then
          return false, "connect: " .. errno:doc()
        end
        return false, "connect: " .. tostring(err)
      end
      return false, "connect failed"
    end
    return true
  end

  function sock:connect_unix(path: string): boolean, string
    local ok, err = (unix.connect as function(number, string): (boolean, any))(self.fd, path)
    if not ok then
      if err then
        local errno = err as Errno
        if errno.doc then
          return false, "connect_unix: " .. errno:doc()
        end
        return false, "connect_unix: " .. tostring(err)
      end
      return false, "connect_unix failed"
    end
    return true
  end

  function sock:getsockopt(level: number, optname: number): number | boolean, string
    local val = unix.getsockopt(self.fd, level, optname)
    if val == nil then
      return nil, "getsockopt failed"
    end
    return val
  end

  function sock:setsockopt(level: number, optname: number, value: number | boolean): boolean, string
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
