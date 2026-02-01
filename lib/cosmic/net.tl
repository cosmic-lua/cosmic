--- Networking and socket utilities.
--- Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.
local unix = require("cosmo.unix")

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
  listen: function(self: Socket, backlog?: number): boolean, string
  accept: function(self: Socket, flags?: number): Socket, number, number, string
  connect: function(self: Socket, ip: number, port: number): boolean, string
  getsockopt: function(self: Socket, level: number, optname: number): number | boolean, string
  setsockopt: function(self: Socket, level: number, optname: number, value: number | boolean): boolean, string
end


--- Create a socket handle from a file descriptor.
--- @param fd number The file descriptor
--- @return Socket The socket handle
local function make_socket(fd: number): Socket
  local sock: Socket = {fd = fd}

  --- Close the socket.
  --- Idempotent: safe to call multiple times.
  --- @return boolean True on success
  function sock:close(): boolean
    if self.fd then
      local ok = unix.close(self.fd)
      self.fd = nil
      return ok
    end
    return true
  end

  --- Check if the socket is closed.
  --- @return boolean True if closed
  function sock:closed(): boolean
    return self.fd == nil
  end

  --- Partially close the socket.
  --- @param how number SHUT_RD (0), SHUT_WR (1), or SHUT_RDWR (2). Defaults to SHUT_RDWR.
  --- @return boolean True on success
  --- @return string Error message on failure
  function sock:shutdown(how?: number): boolean, string
    how = how or unix.SHUT_RDWR
    local ok = unix.shutdown(self.fd, how)
    if not ok then
      return false, "shutdown failed"
    end
    return true
  end

  --- Send data on a connected socket.
  --- @param data string The data to send
  --- @param flags number Optional send flags (MSG_*)
  --- @return number Number of bytes sent
  --- @return string Error message on failure
  function sock:send(data: string, flags?: number): number, string
    local n = unix.send(self.fd, data, flags or 0)
    if not n then
      return nil, "send failed"
    end
    return n
  end

  --- Send data to a specific address (for UDP).
  --- @param data string The data to send
  --- @param ip number The destination IP address
  --- @param port number The destination port
  --- @param flags number Optional send flags (MSG_*)
  --- @return number Number of bytes sent
  --- @return string Error message on failure
  function sock:sendto(data: string, ip: number, port: number, flags?: number): number, string
    local n = unix.sendto(self.fd, data, ip, port, flags or 0)
    if not n then
      return nil, "sendto failed"
    end
    return n
  end

  --- Receive data from a connected socket.
  --- @param bufsiz number Maximum bytes to receive (default 65536)
  --- @param flags number Optional receive flags (MSG_*)
  --- @return string The received data
  --- @return string Error message on failure
  function sock:recv(bufsiz?: number, flags?: number): string, string
    local data = unix.recv(self.fd, bufsiz or 65536, flags or 0)
    if not data then
      return nil, "recv failed"
    end
    return data
  end

  --- Receive data with sender address (for UDP).
  --- @param bufsiz number Maximum bytes to receive (default 65536)
  --- @param flags number Optional receive flags (MSG_*)
  --- @return string The received data
  --- @return number Sender IP address
  --- @return number Sender port
  --- @return string Error message on failure
  function sock:recvfrom(bufsiz?: number, flags?: number): string, number, number, string
    local data, ip, port = unix.recvfrom(self.fd, bufsiz or 65536, flags or 0)
    if not data then
      return nil, nil, nil, "recvfrom failed"
    end
    return data, ip, port
  end

  --- Get the local address of the socket.
  --- @return number Local IP address
  --- @return number Local port
  --- @return string Error message on failure
  function sock:getsockname(): number, number, string
    local ip, port = unix.getsockname(self.fd)
    if not ip then
      return nil, nil, "getsockname failed"
    end
    return ip, port
  end

  --- Get the remote address of a connected socket.
  --- @return number Remote IP address
  --- @return number Remote port
  --- @return string Error message on failure
  function sock:getpeername(): number, number, string
    local ip, port = unix.getpeername(self.fd)
    if not ip then
      return nil, nil, "getpeername failed"
    end
    return ip, port
  end

  --- Bind the socket to a local address.
  --- @param ip number Local IP address (default 0 = all interfaces)
  --- @param port number Local port (default 0 = ephemeral port)
  --- @return boolean True on success
  --- @return string Error message on failure
  function sock:bind(ip?: number, port?: number): boolean, string
    local ok = unix.bind(self.fd, ip or 0, port or 0)
    if not ok then
      return false, "bind failed"
    end
    return true
  end

  --- Start listening for incoming connections.
  --- @param backlog number Maximum pending connections (default 128)
  --- @return boolean True on success
  --- @return string Error message on failure
  function sock:listen(backlog?: number): boolean, string
    local ok = unix.listen(self.fd, backlog or 128)
    if not ok then
      return false, "listen failed"
    end
    return true
  end

  --- Accept an incoming connection.
  --- @param flags number Optional flags (SOCK_CLOEXEC, SOCK_NONBLOCK)
  --- @return Socket New client socket
  --- @return number Client IP address
  --- @return number Client port
  --- @return string Error message on failure
  function sock:accept(flags?: number): Socket, number, number, string
    local clientfd, ip, port = unix.accept(self.fd, flags or 0)
    if not clientfd then
      return nil, nil, nil, "accept failed"
    end
    return make_socket(clientfd), ip, port
  end

  --- Connect to a remote address.
  --- @param ip number Remote IP address
  --- @param port number Remote port
  --- @return boolean True on success
  --- @return string Error message on failure
  function sock:connect(ip: number, port: number): boolean, string
    local ok = unix.connect(self.fd, ip, port)
    if not ok then
      return false, "connect failed"
    end
    return true
  end

  --- Get a socket option value.
  --- @param level number Option level (SOL_SOCKET, SOL_TCP, etc.)
  --- @param optname number Option name (SO_REUSEADDR, TCP_NODELAY, etc.)
  --- @return number|boolean Option value
  --- @return string Error message on failure
  function sock:getsockopt(level: number, optname: number): number | boolean, string
    local val = unix.getsockopt(self.fd, level, optname)
    if val == nil then
      return nil, "getsockopt failed"
    end
    return val
  end

  --- Set a socket option value.
  --- @param level number Option level (SOL_SOCKET, SOL_TCP, etc.)
  --- @param optname number Option name (SO_REUSEADDR, TCP_NODELAY, etc.)
  --- @param value number|boolean Option value
  --- @return boolean True on success
  --- @return string Error message on failure
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

--- Create a new socket.
--- @param family number Address family (AF_INET, AF_UNIX). Default: AF_INET
--- @param socktype number Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
--- @param protocol number Protocol (IPPROTO_TCP, IPPROTO_UDP). Default: 0
--- @return Socket Socket handle
--- @return string Error message on failure
local function socket(family?: number, socktype?: number, protocol?: number): Socket, string
  family = family or unix.AF_INET
  socktype = socktype or unix.SOCK_STREAM
  protocol = protocol or 0
  local fd = unix.socket(family, socktype, protocol)
  if not fd then
    return nil, "socket creation failed"
  end
  return make_socket(fd)
end

--- Create a pair of connected sockets.
--- @param family number Address family (AF_UNIX). Default: AF_UNIX
--- @param socktype number Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
--- @param protocol number Protocol. Default: 0
--- @return Socket First socket of the pair
--- @return Socket Second socket of the pair
--- @return string Error message on failure
local function socketpair(family?: number, socktype?: number, protocol?: number): Socket, Socket, string
  family = family or unix.AF_UNIX
  socktype = socktype or unix.SOCK_STREAM
  protocol = protocol or 0
  local fd1, fd2 = unix.socketpair(family, socktype, protocol)
  if not fd1 then
    return nil, nil, "socketpair creation failed"
  end
  return make_socket(fd1), make_socket(fd2)
end

--- Poll file descriptors for events.
--- The fds table maps file descriptor numbers to event masks (POLLIN, POLLOUT, etc.).
--- Returns a table with the same keys but containing revents for each fd.
--- @param fds {number:number} Map of fd to events to poll for
--- @param timeoutms number Timeout in milliseconds (-1 for infinite, 0 for non-blocking)
--- @return {number:number} Map of fd to revents
--- @return string Error message on failure
local function poll(fds: {number:number}, timeoutms?: number): {number:number}, string
  local result = unix.poll(fds, timeoutms or -1)
  if not result then
    return nil, "poll failed"
  end
  return result
end

--- Get the local hostname.
--- @return string The hostname
--- @return string Error message on failure
local function gethostname(): string, string
  local name = unix.gethostname()
  if not name then
    return nil, "gethostname failed"
  end
  return name
end

--- Parse an IP address string to numeric form.
--- @param str string IP address in dotted notation (e.g., "127.0.0.1")
--- @return number Numeric IP address
--- @return string Error message on failure
local function parseip(str: string): number, string
  local a, b, c, d = str:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return nil, "invalid IP address format"
  end
  local na, nb, nc, nd = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if na > 255 or nb > 255 or nc > 255 or nd > 255 then
    return nil, "IP address octet out of range"
  end
  return (na << 24) | (nb << 16) | (nc << 8) | nd
end

--- Format a numeric IP address to string.
--- @param ip number Numeric IP address
--- @return string IP address in dotted notation
local function formatip(ip: number): string
  return string.format("%d.%d.%d.%d",
    (ip >> 24) & 0xff,
    (ip >> 16) & 0xff,
    (ip >> 8) & 0xff,
    ip & 0xff)
end

local record NetModule
  -- Socket creation
  socket: function(family?: number, socktype?: number, protocol?: number): Socket, string
  socketpair: function(family?: number, socktype?: number, protocol?: number): Socket, Socket, string

  -- Polling
  poll: function(fds: {number:number}, timeoutms?: number): {number:number}, string

  -- Utility
  gethostname: function(): string, string
  parseip: function(str: string): number, string
  formatip: function(ip: number): string

  -- Address families
  AF_INET: number
  AF_UNIX: number
  AF_UNSPEC: number

  -- Socket types
  SOCK_STREAM: number
  SOCK_DGRAM: number
  SOCK_RAW: number
  SOCK_RDM: number
  SOCK_SEQPACKET: number
  SOCK_CLOEXEC: number
  SOCK_NONBLOCK: number

  -- Protocols
  IPPROTO_TCP: number
  IPPROTO_UDP: number
  IPPROTO_IP: number
  IPPROTO_ICMP: number
  IPPROTO_RAW: number

  -- Socket levels
  SOL_SOCKET: number
  SOL_TCP: number
  SOL_UDP: number
  SOL_IP: number

  -- Socket options
  SO_REUSEADDR: number
  SO_REUSEPORT: number
  SO_KEEPALIVE: number
  SO_BROADCAST: number
  SO_LINGER: number
  SO_RCVBUF: number
  SO_SNDBUF: number
  SO_RCVTIMEO: number
  SO_SNDTIMEO: number
  SO_ERROR: number
  SO_TYPE: number
  SO_ACCEPTCONN: number
  SO_DEBUG: number
  SO_DONTROUTE: number
  SO_RCVLOWAT: number
  SO_SNDLOWAT: number

  -- TCP options
  TCP_NODELAY: number
  TCP_CORK: number
  TCP_KEEPIDLE: number
  TCP_KEEPINTVL: number
  TCP_KEEPCNT: number
  TCP_MAXSEG: number
  TCP_SYNCNT: number
  TCP_DEFER_ACCEPT: number
  TCP_FASTOPEN: number
  TCP_FASTOPEN_CONNECT: number
  TCP_QUICKACK: number
  TCP_NOTSENT_LOWAT: number
  TCP_WINDOW_CLAMP: number
  TCP_SAVE_SYN: number
  TCP_SAVED_SYN: number

  -- Shutdown modes
  SHUT_RD: number
  SHUT_WR: number
  SHUT_RDWR: number

  -- Poll events
  POLLIN: number
  POLLOUT: number
  POLLERR: number
  POLLHUP: number
  POLLNVAL: number
  POLLPRI: number
  POLLRDBAND: number
  POLLRDHUP: number
  POLLRDNORM: number
  POLLWRBAND: number
  POLLWRNORM: number

  -- Message flags
  MSG_PEEK: number
  MSG_WAITALL: number
  MSG_OOB: number
  MSG_DONTROUTE: number
  MSG_MORE: number
  MSG_NOSIGNAL: number
end

local M: NetModule = {
  -- Socket creation
  socket = socket,
  socketpair = socketpair,

  -- Polling
  poll = poll,

  -- Utility
  gethostname = gethostname,
  parseip = parseip,
  formatip = formatip,

  -- Address families
  AF_INET = unix.AF_INET,
  AF_UNIX = unix.AF_UNIX,
  AF_UNSPEC = unix.AF_UNSPEC,

  -- Socket types
  SOCK_STREAM = unix.SOCK_STREAM,
  SOCK_DGRAM = unix.SOCK_DGRAM,
  SOCK_RAW = unix.SOCK_RAW,
  SOCK_RDM = unix.SOCK_RDM,
  SOCK_SEQPACKET = unix.SOCK_SEQPACKET,
  SOCK_CLOEXEC = unix.SOCK_CLOEXEC,
  SOCK_NONBLOCK = unix.SOCK_NONBLOCK,

  -- Protocols
  IPPROTO_TCP = unix.IPPROTO_TCP,
  IPPROTO_UDP = unix.IPPROTO_UDP,
  IPPROTO_IP = unix.IPPROTO_IP,
  IPPROTO_ICMP = unix.IPPROTO_ICMP,
  IPPROTO_RAW = unix.IPPROTO_RAW,

  -- Socket levels
  SOL_SOCKET = unix.SOL_SOCKET,
  SOL_TCP = unix.SOL_TCP,
  SOL_UDP = unix.SOL_UDP,
  SOL_IP = unix.SOL_IP,

  -- Socket options
  SO_REUSEADDR = unix.SO_REUSEADDR,
  SO_REUSEPORT = unix.SO_REUSEPORT,
  SO_KEEPALIVE = unix.SO_KEEPALIVE,
  SO_BROADCAST = unix.SO_BROADCAST,
  SO_LINGER = unix.SO_LINGER,
  SO_RCVBUF = unix.SO_RCVBUF,
  SO_SNDBUF = unix.SO_SNDBUF,
  SO_RCVTIMEO = unix.SO_RCVTIMEO,
  SO_SNDTIMEO = unix.SO_SNDTIMEO,
  SO_ERROR = unix.SO_ERROR,
  SO_TYPE = unix.SO_TYPE,
  SO_ACCEPTCONN = unix.SO_ACCEPTCONN,
  SO_DEBUG = unix.SO_DEBUG,
  SO_DONTROUTE = unix.SO_DONTROUTE,
  SO_RCVLOWAT = unix.SO_RCVLOWAT,
  SO_SNDLOWAT = unix.SO_SNDLOWAT,

  -- TCP options
  TCP_NODELAY = unix.TCP_NODELAY,
  TCP_CORK = unix.TCP_CORK,
  TCP_KEEPIDLE = unix.TCP_KEEPIDLE,
  TCP_KEEPINTVL = unix.TCP_KEEPINTVL,
  TCP_KEEPCNT = unix.TCP_KEEPCNT,
  TCP_MAXSEG = unix.TCP_MAXSEG,
  TCP_SYNCNT = unix.TCP_SYNCNT,
  TCP_DEFER_ACCEPT = unix.TCP_DEFER_ACCEPT,
  TCP_FASTOPEN = unix.TCP_FASTOPEN,
  TCP_FASTOPEN_CONNECT = unix.TCP_FASTOPEN_CONNECT,
  TCP_QUICKACK = unix.TCP_QUICKACK,
  TCP_NOTSENT_LOWAT = unix.TCP_NOTSENT_LOWAT,
  TCP_WINDOW_CLAMP = unix.TCP_WINDOW_CLAMP,
  TCP_SAVE_SYN = unix.TCP_SAVE_SYN,
  TCP_SAVED_SYN = unix.TCP_SAVED_SYN,

  -- Shutdown modes
  SHUT_RD = unix.SHUT_RD,
  SHUT_WR = unix.SHUT_WR,
  SHUT_RDWR = unix.SHUT_RDWR,

  -- Poll events
  POLLIN = unix.POLLIN,
  POLLOUT = unix.POLLOUT,
  POLLERR = unix.POLLERR,
  POLLHUP = unix.POLLHUP,
  POLLNVAL = unix.POLLNVAL,
  POLLPRI = unix.POLLPRI,
  POLLRDBAND = unix.POLLRDBAND,
  POLLRDHUP = unix.POLLRDHUP,
  POLLRDNORM = unix.POLLRDNORM,
  POLLWRBAND = unix.POLLWRBAND,
  POLLWRNORM = unix.POLLWRNORM,

  -- Message flags
  MSG_PEEK = unix.MSG_PEEK,
  MSG_WAITALL = unix.MSG_WAITALL,
  MSG_OOB = unix.MSG_OOB,
  MSG_DONTROUTE = unix.MSG_DONTROUTE,
  MSG_MORE = unix.MSG_MORE,
  MSG_NOSIGNAL = unix.MSG_NOSIGNAL,
}

return M
