--- Socket implementation for the networking module.
--- Contains the Socket constructor and all Socket method implementations.
--- Addresses are typed: methods accept a dotted-quad
--- string or an ip.Addr, and return ip.Addr — bare integers are not part
--- of the public surface (wrap C-boundary integers with ip.from_int()).
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").format
local errno_is = require("cosmic.errno").is_code
local ip = require("cosmic.ip")
local poll = require("cosmic.poll")

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

--- A local or peer endpoint (local_endpoint/peer_endpoint).
local record Endpoint
  addr: ip.Addr
  port: integer
end

--- One received datagram from recv_from: payload plus sender endpoint.
local record Datagram
  data: string
  addr: ip.Addr
  port: integer
end

--- Options for Socket:accept.
local record AcceptOptions
  --- Bound the wait: fail with "accept: timed out" after this many
  --- milliseconds instead of blocking until a client arrives. Bounding
  --- the accept alone, rather than reaching for set_timeout_ms on the
  --- listener, which would also bound every send and recv on it.
  timeout_ms: integer
  --- Raw accept4(2) flags for the accepted socket (SOCK_NONBLOCK,
  --- SOCK_CLOEXEC).
  flags: integer
end

--- Socket handle for network I/O.
--- Sockets are BLOCKING by default: recv and accept wait until data or a
--- connection arrives. Blocking calls interrupted by a signal are retried
--- automatically (the signal-safety wave; policy in cosmic.stream)
--- — except connect, see its doc. Use set_timeout_ms or poll for
--- interruptible waits. Supports Lua 5.4's to-be-closed via __close.
local stream = require("cosmic.stream")

local record Socket is stream.Reader, stream.Writer
  metamethod __close: function(self: Socket)
  --- The underlying file descriptor, or -1 once closed — the same
  --- shape fd.Handle reports, so a -1 is never registered with a
  --- Poller by accident.
  fd: function(self: Socket): integer
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
  send_all: function(self: Socket, data: string, flags?: integer): boolean, string
  --- Send a datagram to addr:port; returns bytes sent, or nil + error.
  send_to: function(self: Socket, data: string, addr: Address, port: integer, flags?: integer): integer | nil, string
  --- Receive up to max_bytes bytes (blocks until data arrives).
  --- Returns bare nil (no error) when the peer closed the connection —
  --- end of stream, matching the stream contract (cosmic.stream). ""
  --- is only ever a zero-byte datagram on message sockets. Returns
  --- nil + error message on failure. max_bytes must be positive when
  --- given (default 65536): 0 or negative is an honest error, not a
  --- zero-byte read that would otherwise be misread as peer-closed.
  recv: function(self: Socket, max_bytes?: integer, flags?: integer): string | nil, string
  --- stream.Reader: alias for recv (chunk; bare nil at end of stream;
  --- nil + error on failure).
  read: function(self: Socket, n?: integer): string | nil, string
  --- Receive exactly n bytes from a stream socket, blocking until they
  --- arrive. Returns nil + error if the peer closes the connection
  --- first (bytes read before the close are discarded).
  recv_exact: function(self: Socket, n: integer, flags?: integer): string | nil, string
  --- Receive a datagram: payload plus sender endpoint, error in slot 2.
  recv_from: function(self: Socket, max_bytes?: integer, flags?: integer): Datagram | nil, string
  --- Local endpoint; use after bind for the OS-assigned port.
  local_endpoint: function(self: Socket): Endpoint | nil, string
  --- Peer endpoint.
  peer_endpoint: function(self: Socket): Endpoint | nil, string
  --- Bind to a local addr:port (default all interfaces, OS-assigned port).
  bind: function(self: Socket, addr?: Address, port?: integer): boolean, string
  --- Bind to a unix-domain socket path.
  bind_unix: function(self: Socket, path: string): boolean, string
  --- Start listening for connections.
  listen: function(self: Socket, backlog?: integer): boolean, string
  --- Accept one connection (blocks until a client connects, unless
  --- opts.timeout_ms bounds the wait). Returns the socket alone, error
  --- in slot 2; the peer's endpoint is a peer_endpoint() away.
  accept: function(self: Socket, opts?: AcceptOptions): Socket | nil, string
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
  set_timeout_ms: function(self: Socket, timeout_ms?: integer): boolean, string
end

--- Create a socket handle from a file descriptor.
--- The descriptor is a closure upvalue rather than a record field: it
--- goes to -1 on close, and :fd() is the only way to read it, so there
--- is no field left to hand a stale (or nil) descriptor to a caller.
--- @param fd integer The file descriptor
--- @return Socket The socket handle
local function make_socket(fd: integer): Socket
  local sock: Socket = {}

  -- macOS honors SO_NOSIGPIPE, not MSG_NOSIGNAL, on send(); set it once at
  -- creation so writes there get EPIPE instead of a fatal SIGPIPE. The
  -- constant is 0 on platforms that use MSG_NOSIGNAL instead (Linux,
  -- OpenBSD, Windows), so the guard skips them.
  if unix.SO_NOSIGPIPE ~= nil and unix.SO_NOSIGPIPE ~= 0 then
    unix.setsockopt(fd, unix.SOL_SOCKET, unix.SO_NOSIGPIPE, true)
  end

  function sock:fd(): integer
    return fd
  end

  function sock:close(): boolean, string
    if fd >= 0 then
      local ok, err = unix.close(fd)
      fd = -1
      if not ok then
        return false, errstr(err, "close")
      end
    end
    return true
  end

  function sock:closed(): boolean
    return fd < 0
  end

  function sock:shutdown(how?: integer): boolean, string
    if fd < 0 then return false, "socket closed" end
    how = how or unix.SHUT_RDWR
    local ok, err = unix.shutdown(fd, how)
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
    if fd < 0 then return nil, "socket closed" end
    local n, err, eno = unix.send(fd, data, (flags or 0) | unix.MSG_NOSIGNAL, offset)
    while n == nil and errno_is(eno, "EINTR") do
      n, err, eno = unix.send(fd, data, (flags or 0) | unix.MSG_NOSIGNAL, offset)
    end
    if not n then
      return nil, errstr(err, "send")
    end
    return n
  end

  function sock:send_all(data: string, flags?: integer): boolean, string
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

  function sock:send_to(data: string, addr: Address, port: integer, flags?: integer): integer | nil, string
    if fd < 0 then return nil, "socket closed" end
    local raw, aerr = resolve_addr(addr)
    if not raw then
      return nil, aerr
    end
    local n, err, eno = unix.sendto(fd, data, raw, port, (flags or 0) | unix.MSG_NOSIGNAL)
    while n == nil and errno_is(eno, "EINTR") do
      n, err, eno = unix.sendto(fd, data, raw, port, (flags or 0) | unix.MSG_NOSIGNAL)
    end
    if not n then
      return nil, errstr(err, "sendto")
    end
    return n
  end

  -- Whether this socket is a message (datagram) socket; resolved on the
  -- first empty recv and cached, so the common stream path pays nothing.
  local dgram: boolean = nil

  function sock:recv(max_bytes?: integer, flags?: integer): string | nil, string
    if fd < 0 then return nil, "socket closed" end
    if max_bytes and max_bytes <= 0 then
      return nil, "recv: max_bytes must be positive, got " .. max_bytes
    end
    local data, err, eno = unix.recv(fd, max_bytes or 65536, flags or 0)
    while data == nil and errno_is(eno, "EINTR") do
      data, err, eno = unix.recv(fd, max_bytes or 65536, flags or 0)
    end
    if not data then
      return nil, errstr(err, "recv")
    end
    if data == "" then
      if dgram == nil then
        dgram = self:getsockopt(unix.SOL_SOCKET, unix.SO_TYPE) == unix.SOCK_DGRAM
      end
      if not dgram then
        return nil -- peer closed: end of stream
      end
    end
    return data
  end

  -- The stream.Reader/Writer contract is exactly recv/send's: recv
  -- returns bare nil at end of stream and send returns bytes
  -- written. Alias rather than wrap.
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

  function sock:recv_from(max_bytes?: integer, flags?: integer): Datagram | nil, string
    if fd < 0 then return nil, "socket closed" end
    local data, sender, port = unix.recvfrom(fd, max_bytes or 65536, flags or 0)
    while data == nil and errno_is(port, "EINTR") do
      data, sender, port = unix.recvfrom(fd, max_bytes or 65536, flags or 0)
    end
    if not data then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the sender ip would have been.
      return nil, errstr(sender, "recvfrom")
    end
    return {data = data, addr = ip.from_int(sender), port = port}
  end

  function sock:local_endpoint(): Endpoint | nil, string
    if fd < 0 then return nil, "socket closed" end
    local raw, port = unix.getsockname(fd)
    if not raw then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the port would have been.
      return nil, errstr(port, "getsockname")
    end
    return {addr = ip.from_int(raw), port = port}
  end

  function sock:peer_endpoint(): Endpoint | nil, string
    if fd < 0 then return nil, "socket closed" end
    local raw, port = unix.getpeername(fd)
    if not raw then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the port would have been.
      return nil, errstr(port, "getpeername")
    end
    return {addr = ip.from_int(raw), port = port}
  end

  function sock:bind(addr?: Address, port?: integer): boolean, string
    if fd < 0 then return false, "socket closed" end
    local raw: integer = 0
    if addr ~= nil then
      local r, aerr = resolve_addr(addr)
      if not r then
        return false, aerr
      end
      raw = r
    end
    local ok, err = unix.bind(fd, raw, port or 0)
    if not ok then
      return false, errstr(err, "bind")
    end
    return true
  end

  function sock:bind_unix(path: string): boolean, string
    if fd < 0 then return false, "socket closed" end
    -- cast: function shape (unix-path overload)
    local ok, err = (unix.bind as function(number, string): (boolean, string))(fd, path)
    if not ok then
      return false, errstr(err, "bind_unix: " .. path)
    end
    return true
  end

  function sock:listen(backlog?: integer): boolean, string
    if fd < 0 then return false, "socket closed" end
    local ok, err = unix.listen(fd, backlog or 128)
    if not ok then
      return false, errstr(err, "listen")
    end
    return true
  end

  function sock:accept(opts?: AcceptOptions): Socket | nil, string
    if fd < 0 then return nil, "socket closed" end
    if opts and opts.timeout_ms then
      -- cosmic.poll owns the absolute-deadline retry, so repeated
      -- signals cannot stretch the wait past timeout_ms.
      local p = poll.new()
      local aok, aerr = p:add(fd, poll.POLLIN)
      if not aok then
        return nil, aerr
      end
      local ready, perr = p:wait(opts.timeout_ms)
      if not ready then
        return nil, perr
      end
      if ready[fd] == nil then
        return nil, "accept: timed out after " .. opts.timeout_ms .. "ms"
      end
    end
    local flags = opts and opts.flags or 0
    local clientfd, peer, port = unix.accept(fd, flags)
    while clientfd == nil and errno_is(port, "EINTR") do
      clientfd, peer, port = unix.accept(fd, flags)
    end
    if not clientfd then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the peer ip would have been.
      return nil, errstr(peer, "accept")
    end
    return make_socket(clientfd)
  end

  function sock:connect(addr: Address, port: integer): boolean, string
    if fd < 0 then return false, "socket closed" end
    local raw, aerr = resolve_addr(addr)
    if not raw then
      return false, aerr
    end
    local ok, err = unix.connect(fd, raw, port)
    if not ok then
      return false, errstr(err, "connect")
    end
    return true
  end

  function sock:connect_unix(path: string): boolean, string
    if fd < 0 then return false, "socket closed" end
    -- cast: function shape (unix-path overload)
    local ok, err = (unix.connect as function(number, string): (boolean, any))(fd, path)
    if not ok then
      return false, errstr(err, "connect_unix")
    end
    return true
  end

  function sock:getsockopt(level: integer, optname: integer): integer | boolean | nil, string
    if fd < 0 then return nil, "socket closed" end
    local val, err = unix.getsockopt(fd, level, optname)
    if val == nil then
      return nil, errstr(err, "getsockopt")
    end
    return val
  end

  function sock:set_nonblocking(enable?: boolean): boolean, string
    if fd < 0 then return false, "socket closed" end
    -- unix.fcntl coerces F_GETFL's result to a boolean, so the current
    -- flags cannot be read back. Sockets carry no other fcntl status
    -- flag worth preserving, so set the flag word absolutely.
    local want: integer = 0
    if enable ~= false then
      want = unix.O_NONBLOCK
    end
    local ok, serr = unix.fcntl(fd, unix.F_SETFL, want)
    if not ok then
      return false, errstr(serr, "set_nonblocking")
    end
    return true
  end

  function sock:set_timeout_ms(timeout_ms?: integer): boolean, string
    if fd < 0 then return false, "socket closed" end
    local ms = timeout_ms or 0
    local secs = math.floor(ms / 1000)
    local nanos = math.floor((ms % 1000) * 1000000)
    -- SO_RCVTIMEO/SO_SNDTIMEO take (secs, nanos); the declared
    -- setsockopt signature takes one value, so cast around it.
    -- cast: function shape (timeval overload)
    local sso = unix.setsockopt as function(number, number, number, number, number): (boolean, any)
    local ok, err = sso(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, secs, nanos)
    if not ok then
      return false, errstr(err, "set_timeout_ms")
    end
    ok, err = sso(fd, unix.SOL_SOCKET, unix.SO_SNDTIMEO, secs, nanos)
    if not ok then
      return false, errstr(err, "set_timeout_ms")
    end
    return true
  end

  function sock:setsockopt(level: integer, optname: integer, value: integer | boolean): boolean, string
    if fd < 0 then return false, "socket closed" end
    local ok, err = unix.setsockopt(fd, level, optname, value)
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
  type AcceptOptions = AcceptOptions
  make_socket: function(fd: integer): Socket
  resolve_addr: function(addr: Address): integer | nil, string
end

local M: NetSocketModule = {
  make_socket = make_socket,
  resolve_addr = resolve_addr,
}

return M
