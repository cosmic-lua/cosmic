--- Networking and socket utilities.
--- Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.
--- IPv4 only: string addresses must be strict dotted quads; IPv6 is
--- rejected with an explicit "IPv6 not supported" error.
local unix = require("cosmo.unix")
local ip = require("cosmic.ip")
local net_socket = require("cosmic.net.socket")

--- Socket handle for network I/O (see cosmic.net.socket for the methods).
--- Supports Lua 5.4's to-be-closed via __close metamethod.
local type Socket = net_socket.Socket

local make_socket = net_socket.make_socket

--- An address a TCP helper accepts: a dotted-quad string ("127.0.0.1"),
--- a raw integer (0x7f000001), or a typed ip.Addr.
local type Address = string | number | ip.Addr

--- Resolve an Address union to a raw integer IP.
--- @param addr Address The address in any accepted form
--- @return integer | nil The IP as an integer, or nil on error
--- @return string Error message on failure
local function resolve_addr(addr: Address): integer | nil, string
  if addr is string then
    return ip.parse(addr)
  end
  local n: number
  if addr is number then
    n = addr
  else
    n = (addr as ip.Addr):int()
  end
  local i = math.tointeger(n)
  if not i then
    return nil, "invalid IP integer: " .. tostring(n)
  end
  return i
end

--- Create a new socket.
--- @param family number Address family (AF_INET, AF_UNIX). Default: AF_INET
--- @param socktype number Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
--- @param protocol number Protocol (IPPROTO_TCP, IPPROTO_UDP). Default: 0
--- @return Socket | nil Socket handle
--- @return string Error message on failure
local function socket(family?: number, socktype?: number, protocol?: number): Socket | nil, string
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
--- @return Socket | nil First socket of the pair
--- @return Socket Second socket of the pair
--- @return string Error message on failure
local function socketpair(family?: number, socktype?: number, protocol?: number): Socket | nil, Socket, string
  family = family or unix.AF_UNIX
  socktype = socktype or unix.SOCK_STREAM
  protocol = protocol or 0
  local fd1, fd2 = unix.socketpair(family, socktype, protocol)
  if not fd1 then
    return nil, nil, "socketpair creation failed"
  end
  return make_socket(fd1), make_socket(fd2)
end

--- Create a Unix domain socket, bind it to a path, and start listening.
--- @param path string Filesystem path for the socket
--- @param backlog number Maximum pending connections (default 128)
--- @return Socket | nil Listening socket
--- @return string Error message on failure
local function listen_unix(path: string, backlog?: number): Socket | nil, string
  local sock, err = socket(unix.AF_UNIX, unix.SOCK_STREAM, 0)
  if not sock then
    return nil, err
  end
  local s = sock as Socket
  local ok, bind_err = s:bind_unix(path)
  if not ok then
    s:close()
    return nil, bind_err
  end
  local lok, listen_err = s:listen(backlog)
  if not lok then
    s:close()
    return nil, listen_err
  end
  return s
end

--- Create a Unix domain socket and connect to a path.
--- @param path string Filesystem path of the socket to connect to
--- @return Socket | nil Connected socket
--- @return string Error message on failure
local function connect_unix(path: string): Socket | nil, string
  local sock, err = socket(unix.AF_UNIX, unix.SOCK_STREAM, 0)
  if not sock then
    return nil, err
  end
  local s = sock as Socket
  local ok, conn_err = s:connect_unix(path)
  if not ok then
    s:close()
    return nil, conn_err
  end
  return s
end

--- Create a TCP socket and connect to an address and port.
--- The address may be a dotted-quad string ("127.0.0.1"), a raw integer
--- (0x7f000001), or an ip.Addr. IPv6 is not supported.
--- @param addr Address Remote IPv4 address
--- @param port number Remote port
--- @return Socket | nil Connected socket
--- @return string Error message on failure
local function connect_tcp(addr: Address, port: number): Socket | nil, string
  local ipn, aerr = resolve_addr(addr)
  if not ipn then
    return nil, aerr
  end
  local sock, err = socket(unix.AF_INET, unix.SOCK_STREAM, 0)
  if not sock then
    return nil, err
  end
  local s = sock as Socket
  local ok, conn_err = s:connect(ipn, port)
  if not ok then
    s:close()
    return nil, conn_err
  end
  return s
end

--- Create a TCP socket, bind it to addr:port, and start listening.
--- Passing port 0 lets the OS assign an ephemeral port; the actual port is
--- returned as the second value so callers never need a separate getsockname
--- call. The address may be a dotted-quad string, a raw integer, or an
--- ip.Addr (0 binds all interfaces). IPv6 is not supported.
---
--- Example — listen on an OS-assigned port:
---   local net = require("cosmic.net")
---   local srv, port, err = net.listen_tcp("127.0.0.1", 0)
---   -- port is now the OS-assigned port, e.g. 54321
---   local client = net.connect_tcp("127.0.0.1", port)
---
--- @param addr Address Local IPv4 address to bind ("127.0.0.1", 0 for all)
--- @param port number Local port to bind; use 0 for an OS-assigned ephemeral port
--- @param backlog number Maximum pending connections (default 128)
--- @return Socket | nil Listening socket ready to accept
--- @return number Actual bound port (useful when port 0 was requested)
--- @return string Error message on failure
local function listen_tcp(addr: Address, port: number, backlog?: number): Socket | nil, number, string
  local ipn, aerr = resolve_addr(addr)
  if not ipn then
    return nil, nil, aerr
  end
  local sock, serr = socket(unix.AF_INET, unix.SOCK_STREAM, 0)
  if not sock then
    return nil, nil, serr
  end
  local s = sock as Socket
  local ok, setopt_err = s:setsockopt(unix.SOL_SOCKET, unix.SO_REUSEADDR, true)
  if not ok then
    s:close()
    return nil, nil, setopt_err
  end
  local bok, bind_err = s:bind(ipn, port)
  if not bok then
    s:close()
    return nil, nil, bind_err
  end
  local _, bound_port, name_err = s:getsockname()
  if not bound_port then
    s:close()
    return nil, nil, name_err
  end
  local lok, listen_err = s:listen(backlog)
  if not lok then
    s:close()
    return nil, nil, listen_err
  end
  return s, bound_port
end

--- Connect with a bounded wait instead of blocking indefinitely.
--- Switches the socket to non-blocking mode (via Socket:set_nonblocking),
--- starts the connect, and polls for completion up to timeoutms. The
--- socket remains in non-blocking mode afterwards; call
--- s:set_nonblocking(false) to restore blocking I/O.
--- @param s Socket The socket to connect
--- @param addr Address Remote IPv4 address
--- @param port number Remote port
--- @param timeoutms number Timeout in milliseconds (default 10000)
--- @return boolean True on success
--- @return string Error message on failure
local function nb_connect(s: Socket, addr: Address, port: number, timeoutms?: number): boolean, string
  timeoutms = timeoutms or 10000
  local ipn, aerr = resolve_addr(addr)
  if not ipn then
    return false, aerr
  end
  local nb_ok, nb_err = s:set_nonblocking()
  if not nb_ok then
    return false, nb_err
  end
  local ok, conn_err = s:connect(ipn, port)
  if ok then return true end
  local fds: {number: number} = {[s.fd] = unix.POLLOUT}
  local revents = unix.poll(fds, timeoutms)
  if not revents then
    return false, "nb_connect: poll failed"
  end
  local ev = (revents as {number: number})[s.fd] or 0
  if ev == 0 then return false, "nb_connect: connect timed out" end
  if ev & unix.POLLERR ~= 0 then
    local so_err = s:getsockopt(unix.SOL_SOCKET, unix.SO_ERROR)
    return false, "nb_connect: connect error: " .. tostring(so_err or conn_err)
  end
  if ev & unix.POLLOUT ~= 0 then
    local so_err = s:getsockopt(unix.SOL_SOCKET, unix.SO_ERROR)
    if so_err and so_err ~= 0 then
      return false, "nb_connect: connect failed: SO_ERROR=" .. tostring(so_err)
    end
    return true
  end
  return false, "nb_connect: unexpected poll events=" .. tostring(ev)
end

--- Get the local hostname.
--- @return string | nil The hostname
--- @return string Error message on failure
local function gethostname(): string | nil, string
  local name = unix.gethostname()
  if not name then
    return nil, "gethostname failed"
  end
  return name
end

--- Network interface information.
local record Interface
  name: string
  ip: number
end

--- List network interfaces and their IPv4 addresses.
--- @return {Interface} | nil List of interfaces
--- @return string Error message on failure
local function interfaces(): {Interface} | nil, string
  local raw = unix.siocgifconf()
  if not raw then
    return nil, "siocgifconf failed"
  end
  return raw as {Interface}
end

local record NetModule
  type Socket = Socket
  type Address = Address
  Interface: Interface
  socket: function(family?: number, socktype?: number, protocol?: number): Socket | nil, string
  socketpair: function(family?: number, socktype?: number, protocol?: number): Socket | nil, Socket, string
  listen_unix: function(path: string, backlog?: number): Socket | nil, string
  listen_tcp: function(addr: Address, port: number, backlog?: number): Socket | nil, number, string
  connect_unix: function(path: string): Socket | nil, string
  connect_tcp: function(addr: Address, port: number): Socket | nil, string
  nb_connect: function(s: Socket, addr: Address, port: number, timeoutms?: number): boolean, string
  gethostname: function(): string | nil, string
  interfaces: function(): {Interface} | nil, string
  AF_INET: number
  AF_UNIX: number
  AF_UNSPEC: number
  SOCK_STREAM: number
  SOCK_DGRAM: number
  SOCK_RAW: number
  SOCK_RDM: number
  SOCK_SEQPACKET: number
  SOCK_CLOEXEC: number
  SOCK_NONBLOCK: number
  IPPROTO_TCP: number
  IPPROTO_UDP: number
  IPPROTO_IP: number
  IPPROTO_ICMP: number
  IPPROTO_RAW: number
  SOL_SOCKET: number
  SOL_TCP: number
  SOL_UDP: number
  SOL_IP: number
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
  SHUT_RD: number
  SHUT_WR: number
  SHUT_RDWR: number
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
  MSG_PEEK: number
  MSG_WAITALL: number
  MSG_OOB: number
  MSG_DONTROUTE: number
  MSG_NOSIGNAL: number
end

local M: NetModule = {
  socket = socket,
  socketpair = socketpair,
  listen_unix = listen_unix,
  listen_tcp = listen_tcp,
  connect_unix = connect_unix,
  connect_tcp = connect_tcp,
  nb_connect = nb_connect,
  gethostname = gethostname,
  interfaces = interfaces,
  AF_INET = unix.AF_INET,
  AF_UNIX = unix.AF_UNIX,
  AF_UNSPEC = unix.AF_UNSPEC,
  SOCK_STREAM = unix.SOCK_STREAM,
  SOCK_DGRAM = unix.SOCK_DGRAM,
  SOCK_RAW = unix.SOCK_RAW,
  SOCK_RDM = unix.SOCK_RDM,
  SOCK_SEQPACKET = unix.SOCK_SEQPACKET,
  SOCK_CLOEXEC = unix.SOCK_CLOEXEC,
  SOCK_NONBLOCK = unix.SOCK_NONBLOCK,
  IPPROTO_TCP = unix.IPPROTO_TCP,
  IPPROTO_UDP = unix.IPPROTO_UDP,
  IPPROTO_IP = unix.IPPROTO_IP,
  IPPROTO_ICMP = unix.IPPROTO_ICMP,
  IPPROTO_RAW = unix.IPPROTO_RAW,
  SOL_SOCKET = unix.SOL_SOCKET,
  SOL_TCP = unix.SOL_TCP,
  SOL_UDP = unix.SOL_UDP,
  SOL_IP = unix.SOL_IP,
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
  SHUT_RD = unix.SHUT_RD,
  SHUT_WR = unix.SHUT_WR,
  SHUT_RDWR = unix.SHUT_RDWR,
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
  MSG_PEEK = unix.MSG_PEEK,
  MSG_WAITALL = unix.MSG_WAITALL,
  MSG_OOB = unix.MSG_OOB,
  MSG_DONTROUTE = unix.MSG_DONTROUTE,
  MSG_NOSIGNAL = unix.MSG_NOSIGNAL,
}

return M
