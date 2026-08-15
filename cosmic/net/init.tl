--- Networking and socket utilities.
--- Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.
--- Addresses are typed: every public signature takes a dotted-quad
--- string or an ip.Addr and returns ip.Addr — bare integers are not
--- addresses. The address family status (IPv4 only for now, and what
--- IPv6 will change) is stated once, in cosmic.ip.
local unix = require("cosmo.unix")
local ip = require("cosmic.ip")
local net_socket = require("cosmic.net.socket")
local errstr = require("cosmic.errno").format

--- Socket handle for network I/O (see cosmic.net.socket for the methods).
--- Supports Lua 5.4's to-be-closed via __close metamethod.
local type Socket = net_socket.Socket

--- An address a helper accepts: a dotted-quad string ("127.0.0.1") or a
--- typed ip.Addr. Wrap C-boundary integers with ip.from_int().
local type Address = net_socket.Address

local make_socket = net_socket.make_socket

--- Options for socket() and socket_pair().
local record SocketOptions
  --- AF_INET (socket default), AF_UNIX (socket_pair default).
  family: integer
  --- SOCK_STREAM (default) or SOCK_DGRAM, optionally OR-ed with flags
  --- like SOCK_NONBLOCK/SOCK_CLOEXEC.
  socket_type: integer
  --- IPPROTO_* (default 0: the family's standard protocol).
  protocol: integer
end

--- Create a new socket.
--- @param opts SocketOptions? family (default AF_INET), socket_type (default SOCK_STREAM), protocol (default 0)
--- @return Socket | nil Socket handle
--- @return string Error message on failure
local function socket(opts?: SocketOptions): Socket | nil, string
  local family = opts and opts.family or unix.AF_INET
  local socket_type = opts and opts.socket_type or unix.SOCK_STREAM
  local protocol = opts and opts.protocol or 0
  local fd, err = unix.socket(family, socket_type, protocol)
  if not fd then
    return nil, errstr(err, "socket")
  end
  return make_socket(fd)
end

--- A connected socket pair, as returned by socket_pair(). A record
--- rather than (Socket, Socket, err) returns: the old shape typed slot
--- 2 as a non-nil Socket while returning nil there on failure, and put
--- the error in slot 3 where `local a, b = ...` silently lost it.
local record SocketPair
  a: Socket
  b: Socket
end

--- Create a pair of connected sockets.
--- @param opts SocketOptions? family (default AF_UNIX), socket_type (default SOCK_STREAM), protocol (default 0)
--- @return SocketPair | nil Both sockets, on success
--- @return string Error message on failure
local function socket_pair(opts?: SocketOptions): SocketPair | nil, string
  local family = opts and opts.family or unix.AF_UNIX
  local socket_type = opts and opts.socket_type or unix.SOCK_STREAM
  local protocol = opts and opts.protocol or 0
  local fd1, fd2 = unix.socketpair(family, socket_type, protocol)
  if not fd1 then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot, where the second fd would have been.
    return nil, errstr(fd2, "socketpair")
  end
  return {a = make_socket(fd1), b = make_socket(fd2)}
end

--- Options for listen_tcp and listen_unix.
local record ListenOptions
  --- Maximum pending connections (default 128). Both families.
  backlog: integer
  --- Set SO_REUSEADDR on the listener (default true: rebinding a
  --- just-closed address must not fail with EADDRINUSE). Address reuse
  --- is a TCP concept: listen_unix binds a filesystem path and sets
  --- this only when you ask for it explicitly.
  reuse_addr: boolean
  --- Set SO_REUSEPORT on the listener (default false): lets several
  --- processes bind the same addr:port and share the accept load.
  --- TCP, on the same terms as reuse_addr.
  reuse_port: boolean
end

--- Apply the two reuse options to a fresh listener. tcp_defaults picks
--- the family's posture: TCP turns SO_REUSEADDR on unless asked not
--- to, a unix path bind sets neither unless asked to.
local function apply_reuse(s: Socket, opts: ListenOptions, tcp_defaults: boolean): boolean, string
  local want_addr = tcp_defaults and opts.reuse_addr ~= false or opts.reuse_addr == true
  if want_addr then
    local ok, err = s:setsockopt(unix.SOL_SOCKET, unix.SO_REUSEADDR, true)
    if not ok then
      return false, err
    end
  end
  if opts.reuse_port then
    local ok, err = s:setsockopt(unix.SOL_SOCKET, unix.SO_REUSEPORT, true)
    if not ok then
      return false, err
    end
  end
  return true
end

--- Create a Unix domain socket, bind it to a path, and start listening.
--- @param path string Filesystem path for the socket
--- @param opts ListenOptions? backlog (default 128); the reuse options apply only when set
--- @return Socket | nil Listening socket
--- @return string Error message on failure
local function listen_unix(path: string, opts?: ListenOptions): Socket | nil, string
  opts = opts or {}
  local sock, err = socket({family = unix.AF_UNIX})
  if not sock then
    return nil, err
  end
  local s = sock
  local rok, reuse_err = apply_reuse(s, opts, false)
  if not rok then
    local _ok, _err = s:close()
    return nil, reuse_err
  end
  local ok, bind_err = s:bind_unix(path)
  if not ok then
    local _ok, _err = s:close()
    return nil, bind_err
  end
  local lok, listen_err = s:listen(opts.backlog)
  if not lok then
    local _ok, _err = s:close()
    return nil, listen_err
  end
  return s
end

-- The timeout connect paths live in the connect shard.
local net_connect = require("cosmic.net.connect")
local connect_with_timeout = net_connect.with_timeout
local unix_connect_with_timeout = net_connect.unix_with_timeout

--- Options for dial and dial_unix.
local record ConnectOptions
  --- Bound the connect attempt: fail with an error after this many
  --- milliseconds instead of waiting on the kernel's own (much longer)
  --- timeout. The returned socket is BLOCKING either way.
  timeout_ms: integer
end

--- Connect a fresh socket, honouring ConnectOptions.timeout_ms, and
--- close it on any failure so no descriptor leaks out of a failed dial.
--- @param s Socket The socket to connect
--- @param connect function(): (boolean, string) The blocking connect to run
--- @param bounded function(integer): (boolean, string) The bounded variant
--- @param opts ConnectOptions? timeout_ms selects bounded
--- @return Socket | nil The connected socket
--- @return string Error message on failure
local function finish_connect(s: Socket, connect: function(): (boolean, string),
    bounded: function(integer): (boolean, string), opts?: ConnectOptions): Socket | nil, string
  if opts and opts.timeout_ms then
    local ok, conn_err = bounded(opts.timeout_ms)
    if not ok then
      local _ok, _err = s:close()
      return nil, conn_err
    end
    -- The timeout path connects non-blocking; hand back a normal socket.
    local bok, berr = s:set_nonblocking(false)
    if not bok then
      local _ok, _err = s:close()
      return nil, berr
    end
    return s
  end
  local ok, conn_err = connect()
  if not ok then
    local _ok, _err = s:close()
    return nil, conn_err
  end
  return s
end

--- Open a TCP connection to host:port. This name and shape are the
--- stable dial contract: host is a dotted-quad literal, a typed
--- ip.Addr, or a DNS name — resolution happens inside — and the result
--- is a connected Socket. Future address families and richer endpoint
--- forms extend the values dial accepts, never the signature.
--- @param host Address Host to connect to: dotted-quad literal, ip.Addr, or DNS name
--- @param port integer Remote TCP port
--- @param opts ConnectOptions? timeout_ms bounds the connect attempt
--- @return Socket | nil Connected socket
--- @return string Error message on failure
local function dial(host: Address, port: integer, opts?: ConnectOptions): Socket | nil, string
  local a: ip.Addr
  if host is string then
    local parsed, perr = ip.parse(host)
    if parsed then
      a = parsed
    elseif host:find(":", 1, true) then
      -- A colon marks an address literal, not a DNS name: report why the
      -- literal was rejected instead of failing a pointless lookup.
      return nil, "dial " .. host .. ": " .. tostring(perr)
    else
      local looked, lerr = ip.resolve(host)
      if not looked then
        return nil, "dial " .. host .. ": " .. tostring(lerr)
      end
      a = looked
    end
  else
    a = host
  end
  local sock, err = socket()
  if not sock then
    return nil, err
  end
  local s = sock
  return finish_connect(s,
    function(): boolean, string return s:connect(a, port) end,
    function(ms: integer): boolean, string
      return connect_with_timeout(s, a, port, ms)
    end, opts)
end

--- Open a connection to a Unix domain socket path.
--- @param path string Filesystem path of the socket to connect to
--- @param opts ConnectOptions? timeout_ms bounds the connect attempt
--- @return Socket | nil Connected socket
--- @return string Error message on failure
local function dial_unix(path: string, opts?: ConnectOptions): Socket | nil, string
  local sock, err = socket({family = unix.AF_UNIX})
  if not sock then
    return nil, err
  end
  local s = sock
  return finish_connect(s,
    function(): boolean, string return s:connect_unix(path) end,
    function(ms: integer): boolean, string
      return unix_connect_with_timeout(s, path, ms)
    end, opts)
end

--- Create a TCP socket, bind it to addr:port, and start listening.
--- Passing port 0 lets the OS assign an ephemeral port; read it with
--- local_endpoint().port. The address may be a dotted-quad string or an
--- ip.Addr ("0.0.0.0" binds all interfaces).
---
--- Example — listen on an OS-assigned port:
---   local net = require("cosmic.net")
---   local srv = assert(net.listen_tcp("127.0.0.1", 0))
---   local port = assert(srv:local_endpoint()).port
---   local client = net.dial("127.0.0.1", port)
---
--- @param addr Address Local IPv4 address to bind ("127.0.0.1", "0.0.0.0" for all)
--- @param port integer Local port to bind; use 0 for an OS-assigned ephemeral port
--- @param opts ListenOptions? backlog (default 128), reuse_addr (default true), reuse_port (default false)
--- @return Socket | nil Listening socket ready to accept; when port 0
--- was requested, read the OS-assigned port with `s:local_endpoint().port`
--- @return string Error message on failure
local function listen_tcp(addr: Address, port: integer, opts?: ListenOptions): Socket | nil, string
  opts = opts or {}
  local sock, serr = socket()
  if not sock then
    return nil, serr
  end
  local s = sock
  local rok, reuse_err = apply_reuse(s, opts, true)
  if not rok then
    local _ok, _err = s:close()
    return nil, reuse_err
  end
  local bok, bind_err = s:bind(addr, port)
  if not bok then
    local _ok, _err = s:close()
    return nil, bind_err
  end
  local lok, listen_err = s:listen(opts.backlog)
  if not lok then
    local _ok, _err = s:close()
    return nil, listen_err
  end
  return s
end

--- The local hostname.
--- @return string | nil The hostname
--- @return string Error message on failure
local function hostname(): string | nil, string
  local name, err = unix.gethostname()
  if not name then
    return nil, errstr(err, "gethostname")
  end
  return name
end

--- Network interface information.
local record Interface
  name: string
  ip: ip.Addr
end

--- List network interfaces and their IPv4 addresses.
--- @return {Interface} | nil List of interfaces
--- @return string Error message on failure
local function interfaces(): {Interface} | nil, string
  local raw, err = unix.siocgifconf()
  if not raw then
    return nil, errstr(err, "siocgifconf")
  end
  -- The binding returns {unix.IfAddr} since the 2026.08.15 pin
  -- (whilp/cosmopolitan#256), so the blob casts this loop carried are
  -- gone: the fields are typed at the source.
  local list: {Interface} = {}
  for i, entry in ipairs(raw) do
    list[i] = {
      name = entry.name,
      ip = ip.from_int(entry.ip),
    }
  end
  return list
end

local record NetModule
  type Socket = Socket
  type Address = Address
  type ListenOptions = ListenOptions
  type Interface = Interface
  type Endpoint = net_socket.Endpoint
  type Datagram = net_socket.Datagram
  type AcceptOptions = net_socket.AcceptOptions
  type SocketPair = SocketPair
  type SocketOptions = SocketOptions
  socket: function(opts?: SocketOptions): Socket | nil, string
  socket_pair: function(opts?: SocketOptions): SocketPair | nil, string
  listen_unix: function(path: string, opts?: ListenOptions): Socket | nil, string
  listen_tcp: function(addr: Address, port: integer, opts?: ListenOptions): Socket | nil, string
  type ConnectOptions = ConnectOptions
  dial: function(host: Address, port: integer, opts?: ConnectOptions): Socket | nil, string
  dial_unix: function(path: string, opts?: ConnectOptions): Socket | nil, string
  hostname: function(): string | nil, string
  interfaces: function(): {Interface} | nil, string
  AF_INET: integer
  AF_UNIX: integer
  AF_UNSPEC: integer
  SOCK_STREAM: integer
  SOCK_DGRAM: integer
  SOCK_RAW: integer
  SOCK_RDM: integer
  SOCK_SEQPACKET: integer
  SOCK_CLOEXEC: integer
  SOCK_NONBLOCK: integer
  IPPROTO_TCP: integer
  IPPROTO_UDP: integer
  IPPROTO_IP: integer
  IPPROTO_ICMP: integer
  IPPROTO_RAW: integer
  SOL_SOCKET: integer
  SOL_TCP: integer
  SOL_UDP: integer
  SOL_IP: integer
  SO_REUSEADDR: integer
  SO_REUSEPORT: integer
  SO_KEEPALIVE: integer
  SO_BROADCAST: integer
  SO_LINGER: integer
  SO_RCVBUF: integer
  SO_SNDBUF: integer
  SO_RCVTIMEO: integer
  SO_SNDTIMEO: integer
  SO_ERROR: integer
  SO_TYPE: integer
  SO_ACCEPTCONN: integer
  SO_DEBUG: integer
  SO_DONTROUTE: integer
  SO_RCVLOWAT: integer
  SO_SNDLOWAT: integer
  TCP_NODELAY: integer
  TCP_CORK: integer
  TCP_KEEPIDLE: integer
  TCP_KEEPINTVL: integer
  TCP_KEEPCNT: integer
  TCP_MAXSEG: integer
  TCP_SYNCNT: integer
  TCP_DEFER_ACCEPT: integer
  TCP_FASTOPEN: integer
  TCP_FASTOPEN_CONNECT: integer
  TCP_QUICKACK: integer
  TCP_NOTSENT_LOWAT: integer
  TCP_WINDOW_CLAMP: integer
  TCP_SAVE_SYN: integer
  TCP_SAVED_SYN: integer
  SHUT_RD: integer
  SHUT_WR: integer
  SHUT_RDWR: integer
  MSG_PEEK: integer
  MSG_WAITALL: integer
  MSG_OOB: integer
  MSG_DONTROUTE: integer
  MSG_NOSIGNAL: integer
end

local M: NetModule = {
  socket = socket,
  socket_pair = socket_pair,
  listen_unix = listen_unix,
  listen_tcp = listen_tcp,
  dial = dial,
  dial_unix = dial_unix,
  hostname = hostname,
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
  MSG_PEEK = unix.MSG_PEEK,
  MSG_WAITALL = unix.MSG_WAITALL,
  MSG_OOB = unix.MSG_OOB,
  MSG_DONTROUTE = unix.MSG_DONTROUTE,
  MSG_NOSIGNAL = unix.MSG_NOSIGNAL,
}

return M
