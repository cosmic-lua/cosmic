--- Socket implementation for the networking module.
--- Contains the Socket constructor and all Socket method implementations.
--- Addresses are typed (api-review-2): methods accept a dotted-quad
--- string or an ip.Addr, and return ip.Addr — bare integers are not part
--- of the public surface (wrap C-boundary integers with ip.from_int()).
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").wrap
local errno_is = require("cosmic.errno").is
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
    return a:int()
  end
  return addr:int()
end

--- A local or peer endpoint (getsockname/getpeername), error in slot 2.
local record Endpoint
  addr: ip.Addr
  port: integer
end

--- One received datagram recvfrom: payload plus sender endpoint.
local record Datagram
  data: string
  addr: ip.Addr
  port: integer
end

--- Socket handle for network I/O.
--- Sockets are BLOCKING by default: recv and accept wait until data or a
--- connection arrives. Blocking calls interrupted by a signal are retried
--- automatically (the signal-safety wave; policy in cosmic.stream)
--- — except connect, see its doc. Use set_timeout or poll for
--- interruptible waits. Supports Lua 5.4's to-be-closed via __close.
local stream = require("cosmic.stream")

local record Socket is stream.Reader, stream.Writer
  metamethod __close: function(self: Socket)
  --- The underlying file descriptor.
  fd: integer
  --- Close the socket. Idempotent; reports the close(2) error.
  close: function(self: Socket): boolean, string
  --- True when the socket has been closed.
  closed: function(self: Socket): boolean
  --- Shut down reading and/or writing (unix.SHUT_RD/WR/RDWR).
  shutdown: function(self: Socket, how?: integer): boolean, string
  --- Send data; returns bytes sent, or nil + error. offset skips that
  --- many leading bytes of data (0-based), so partial-send loops can
  --- window the buffer without copying it via data:sub.
  send: function(self: Socket, data: string, flags?: integer, offset?: integer): integer | nil, string
  --- stream.Writer: alias for send (bytes written, or nil + error).
  write: function(self: Socket, data: string): integer | nil, string
  --- Send all of data, retrying partial writes until done.
  --- Returns false + error if any write fails; bytes already sent
  --- before the failure stay sent.
  sendall: function(self: Socket, data: string, flags?: integer): boolean, string
  --- Send a datagram to addr:port; returns bytes sent, or nil + error.
  sendto: function(self: Socket, data: string, addr: Address, port: integer, flags?: integer): integer | nil, string
  --- Receive up to bufsiz bytes (blocks until data arrives).
  --- Returns bare nil (no error) when the peer closed the connection —
  --- end of stream, matching the stream contract (cosmic.stream). ""
  --- is only ever a zero-byte datagram on message sockets. Returns
  --- nil + error message on failure. bufsiz must be positive when
  --- given (default 65536): 0 or negative is an honest error, not a
  --- zero-byte read that would otherwise be misread as peer-closed.
  recv: function(self: Socket, bufsiz?: integer, flags?: integer): string | nil, string
  --- stream.Reader: alias for recv (chunk; bare nil at end of stream;
  --- nil + error on failure).
  read: function(self: Socket, n?: integer): string | nil, string
  --- Receive exactly n bytes from a stream socket, blocking until they
  --- arrive. Returns nil + error if the peer closes the connection
  --- first (bytes read before the close are discarded).
  recv_exact: function(self: Socket, n: integer, flags?: integer): string | nil, string
  --- Read one line from a stream socket, blocking until a "\n" arrives.
  --- The trailing "\n" (and a "\r" before it) is consumed but not
  --- returned. At end of stream a final unterminated line is returned
  --- as-is; after that (or on an empty stream) returns bare nil, matching
  --- the stream contract. With max set, returns at most max bytes even
  --- if no newline was seen (the rest stays readable), like fgets.
  readline: function(self: Socket, max?: integer): string | nil, string
  --- Receive a datagram: payload plus sender endpoint, error in slot 2.
  recvfrom: function(self: Socket, bufsiz?: integer, flags?: integer): Datagram | nil, string
  --- Local endpoint; use after bind for the OS-assigned port.
  getsockname: function(self: Socket): Endpoint | nil, string
  --- Peer endpoint.
  getpeername: function(self: Socket): Endpoint | nil, string
  --- Bind to a local addr:port (default all interfaces, OS-assigned port).
  bind: function(self: Socket, addr?: Address, port?: integer): boolean, string
  --- Bind to a unix-domain socket path.
  bind_unix: function(self: Socket, path: string): boolean, string
  --- Start listening for connections.
  listen: function(self: Socket, backlog?: integer): boolean, string
  --- Accept one connection (blocks until a client connects). Returns
  --- the socket alone, error in slot 2; the peer's endpoint is a
  --- getpeername() away when wanted.
  accept: function(self: Socket, flags?: integer): Socket | nil, string
  --- Connect to addr:port. The one blocking call NOT retried on EINTR:
  --- POSIX keeps the connection attempt going in the background after a
  --- signal, so a blind retry would fail with EALREADY. On EINTR, poll
  --- the socket for writability to learn the outcome.
  connect: function(self: Socket, addr: Address, port: integer): boolean, string
  --- Connect to a unix-domain socket path.
  connect_unix: function(self: Socket, path: string): boolean, string
  --- Read a socket option value.
  getsockopt: function(self: Socket, level: integer, optname: integer): integer | boolean | nil, string
  --- Set a socket option value.
  setsockopt: function(self: Socket, level: integer, optname: integer, value: integer | boolean): boolean, string
  --- Switch O_NONBLOCK on (default) or off for this socket.
  set_nonblocking: function(self: Socket, enable?: boolean): boolean, string
  --- Set a timeout in milliseconds for blocking sends and receives
  --- (SO_RCVTIMEO + SO_SNDTIMEO). Timed-out operations fail with an
  --- EAGAIN error. nil or 0 clears the timeout (block forever).
  set_timeout: function(self: Socket, ms?: integer): boolean, string
end

--- Create a socket handle from a file descriptor.
--- @param fd integer The file descriptor
--- @return Socket The socket handle
local function make_socket(fd: integer): Socket
  local sock: Socket = {fd = fd}

  -- macOS honors SO_NOSIGPIPE, not MSG_NOSIGNAL, on send(); set it once at
  -- creation so writes there get EPIPE instead of a fatal SIGPIPE. The
  -- constant is 0 on platforms that use MSG_NOSIGNAL instead (Linux,
  -- OpenBSD, Windows), so the guard skips them.
  if unix.SO_NOSIGPIPE ~= nil and unix.SO_NOSIGPIPE ~= 0 then
    unix.setsockopt(fd, unix.SOL_SOCKET, unix.SO_NOSIGPIPE, true)
  end

  function sock:close(): boolean, string
    if self.fd then
      local ok, err = unix.close(self.fd)
      self.fd = nil
      if not ok then
        return false, errstr(err, "close")
      end
    end
    return true
  end

  function sock:closed(): boolean
    return self.fd == nil
  end

  function sock:shutdown(how?: integer): boolean, string
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
  function sock:send(data: string, flags?: integer, offset?: integer): integer | nil, string
    if not self.fd then return nil, "socket closed" end
    local n, err, eno = unix.send(self.fd, data, (flags or 0) | unix.MSG_NOSIGNAL, offset)
    while n == nil and errno_is(eno, "EINTR") do
      n, err, eno = unix.send(self.fd, data, (flags or 0) | unix.MSG_NOSIGNAL, offset)
    end
    if not n then
      return nil, errstr(err, "send")
    end
    return n
  end

  function sock:sendall(data: string, flags?: integer): boolean, string
    local off: integer = 0
    while off < #data do
      local n, err = self:send(data, flags, off)
      if not n then
        return false, err
      end
      off = off + n
    end
    return true
  end

  function sock:sendto(data: string, addr: Address, port: integer, flags?: integer): integer | nil, string
    if not self.fd then return nil, "socket closed" end
    local raw, aerr = resolve_addr(addr)
    if not raw then
      return nil, aerr
    end
    local n, err, eno = unix.sendto(self.fd, data, raw, port, (flags or 0) | unix.MSG_NOSIGNAL)
    while n == nil and errno_is(eno, "EINTR") do
      n, err, eno = unix.sendto(self.fd, data, raw, port, (flags or 0) | unix.MSG_NOSIGNAL)
    end
    if not n then
      return nil, errstr(err, "sendto")
    end
    return n
  end

  -- Whether this socket is a message (datagram) socket; resolved on the
  -- first empty recv and cached, so the common stream path pays nothing.
  local dgram: boolean = nil

  function sock:recv(bufsiz?: integer, flags?: integer): string | nil, string
    if not self.fd then return nil, "socket closed" end
    if bufsiz and bufsiz <= 0 then
      return nil, "recv: bufsiz must be positive, got " .. bufsiz
    end
    local data, err, eno = unix.recv(self.fd, bufsiz or 65536, flags or 0)
    while data == nil and errno_is(eno, "EINTR") do
      data, err, eno = unix.recv(self.fd, bufsiz or 65536, flags or 0)
    end
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

  -- The stream.Reader/Writer contract is exactly recv/send's: recv
  -- returns bare nil at end of stream (api-review-2) and send
  -- returns bytes written. Alias rather than wrap.
  sock.read = sock.recv
  sock.write = sock.send

  function sock:recv_exact(n: integer, flags?: integer): string | nil, string
    local parts: {string} = {}
    local got = 0
    while got < n do
      local chunk, err = self:recv(n - got, flags)
      if not chunk then
        if err then
          return nil, err
        end
        return nil, "recv_exact: connection closed after " .. got .. " of " .. n .. " bytes"
      end
      parts[#parts + 1] = chunk
      got = got + #chunk
    end
    return table.concat(parts)
  end

  function sock:readline(max?: integer): string | nil, string
    if not self.fd then return nil, "socket closed" end
    local parts: {string} = {}
    local total = 0
    local saw_newline = false
    while true do
      -- Peek without consuming, then consume exactly through the newline,
      -- so bytes past the line stay readable by recv/recv_exact.
      local data, err, eno = unix.recv(self.fd, 4096, unix.MSG_PEEK)
      while data == nil and errno_is(eno, "EINTR") do
        data, err, eno = unix.recv(self.fd, 4096, unix.MSG_PEEK)
      end
      if not data then
        return nil, errstr(err, "readline")
      end
      local d = data
      if d == "" then
        -- End of stream: hand back a final unterminated line if any.
        if total == 0 then
          return nil
        end
        break
      end
      local nl = string.find(d, "\n", 1, true)
      local take: integer = nl or #d
      if max and total + take > max then
        take = max - total
        nl = nil
      end
      if take > 0 then
        local chunk, cerr = self:recv_exact(take)
        if not chunk then
          return nil, cerr
        end
        parts[#parts + 1] = chunk
        total = total + take
      end
      if nl then
        saw_newline = true
        break
      end
      if max and total >= max then
        break
      end
    end
    local line = table.concat(parts)
    if saw_newline then
      line = line:sub(1, -2)
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
    end
    return line
  end

  function sock:recvfrom(bufsiz?: integer, flags?: integer): Datagram | nil, string
    if not self.fd then return nil, "socket closed" end
    local data, sender, port = unix.recvfrom(self.fd, bufsiz or 65536, flags or 0)
    while data == nil and errno_is(port, "EINTR") do
      data, sender, port = unix.recvfrom(self.fd, bufsiz or 65536, flags or 0)
    end
    if not data then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the sender ip would have been.
      return nil, errstr(sender, "recvfrom")
    end
    return {data = data, addr = ip.from_int(sender), port = port}
  end

  function sock:getsockname(): Endpoint | nil, string
    if not self.fd then return nil, "socket closed" end
    local raw, port = unix.getsockname(self.fd)
    if not raw then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the port would have been.
      return nil, errstr(port, "getsockname")
    end
    return {addr = ip.from_int(raw), port = port}
  end

  function sock:getpeername(): Endpoint | nil, string
    if not self.fd then return nil, "socket closed" end
    local raw, port = unix.getpeername(self.fd)
    if not raw then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the port would have been.
      return nil, errstr(port, "getpeername")
    end
    return {addr = ip.from_int(raw), port = port}
  end

  function sock:bind(addr?: Address, port?: integer): boolean, string
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
    -- cast: function shape (unix-path overload)
    local ok, err = (unix.bind as function(number, string): (boolean, string))(self.fd, path)
    if not ok then
      return false, errstr(err, "bind_unix: " .. path)
    end
    return true
  end

  function sock:listen(backlog?: integer): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok, err = unix.listen(self.fd, backlog or 128)
    if not ok then
      return false, errstr(err, "listen")
    end
    return true
  end

  function sock:accept(flags?: integer): Socket | nil, string
    if not self.fd then return nil, "socket closed" end
    local clientfd, peer, port = unix.accept(self.fd, flags or 0)
    while clientfd == nil and errno_is(port, "EINTR") do
      clientfd, peer, port = unix.accept(self.fd, flags or 0)
    end
    if not clientfd then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the peer ip would have been.
      return nil, errstr(peer, "accept")
    end
    return make_socket(clientfd)
  end

  function sock:connect(addr: Address, port: integer): boolean, string
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
    -- cast: function shape (unix-path overload)
    local ok, err = (unix.connect as function(number, string): (boolean, any))(self.fd, path)
    if not ok then
      return false, errstr(err, "connect_unix")
    end
    return true
  end

  function sock:getsockopt(level: integer, optname: integer): integer | boolean | nil, string
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
      want = unix.O_NONBLOCK
    end
    local ok, serr = unix.fcntl(self.fd, unix.F_SETFL, want)
    if not ok then
      return false, errstr(serr, "set_nonblocking")
    end
    return true
  end

  function sock:set_timeout(ms?: integer): boolean, string
    if not self.fd then return false, "socket closed" end
    ms = ms or 0
    local secs = math.floor(ms / 1000)
    local nanos = math.floor((ms % 1000) * 1000000)
    -- SO_RCVTIMEO/SO_SNDTIMEO take (secs, nanos); the declared
    -- setsockopt signature takes one value, so cast around it.
    -- cast: function shape (timeval overload)
    local sso = unix.setsockopt as function(number, number, number, number, number): (boolean, any)
    local ok, err = sso(self.fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, secs, nanos)
    if not ok then
      return false, errstr(err, "set_timeout")
    end
    ok, err = sso(self.fd, unix.SOL_SOCKET, unix.SO_SNDTIMEO, secs, nanos)
    if not ok then
      return false, errstr(err, "set_timeout")
    end
    return true
  end

  function sock:setsockopt(level: integer, optname: integer, value: integer | boolean): boolean, string
    if not self.fd then return false, "socket closed" end
    local ok, err = unix.setsockopt(self.fd, level, optname, value)
    if not ok then
      return false, errstr(err, "setsockopt")
    end
    return true
  end

  return setmetatable(sock, {
      __close = function(self: Socket) local _ok, _err = self:close() end
    })
end

local record NetSocketModule
  type Socket = Socket
  type Address = Address
  type Endpoint = Endpoint
  type Datagram = Datagram
  make_socket: function(fd: integer): Socket
  resolve_addr: function(addr: Address): integer | nil, string
end

local M: NetSocketModule = {
  make_socket = make_socket,
  resolve_addr = resolve_addr,
}

return M
