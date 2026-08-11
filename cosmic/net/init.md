# net

 Networking and socket utilities.
 Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.
 Addresses are typed: every public signature takes a dotted-quad
 string or an ip.Addr and returns ip.Addr — bare integers are not
 addresses. The address family status (IPv4 only for now, and what
 IPv6 will change) is stated once, in cosmic.ip.

## Types

### SocketOptions

 Options for socket() and socket_pair().

```teal
local record SocketOptions
  --  AF_INET (socket default), AF_UNIX (socket_pair default).
  family: integer
  --  SOCK_STREAM (default) or SOCK_DGRAM, optionally OR-ed with flags
  --  like SOCK_NONBLOCK/SOCK_CLOEXEC.
  socket_type: integer
  --  IPPROTO_* (default 0: the family's standard protocol).
  protocol: integer
end
```

### SocketPair

 A connected socket pair, as returned by socket_pair(). A record
 rather than (Socket, Socket, err) returns: the old shape typed slot
 2 as a non-nil Socket while returning nil there on failure, and put
 the error in slot 3 where `local a, b = ...` silently lost it.

```teal
local record SocketPair
  a: Socket
  b: Socket
end
```

### ListenOptions

 Options for listen_tcp and listen_unix.

```teal
local record ListenOptions
  --  Maximum pending connections (default 128). Both families.
  backlog: integer
  --  Set SO_REUSEADDR on the listener (default true: rebinding a
  --  just-closed address must not fail with EADDRINUSE). Address reuse
  --  is a TCP concept: listen_unix binds a filesystem path and sets
  --  this only when you ask for it explicitly.
  reuse_addr: boolean
  --  Set SO_REUSEPORT on the listener (default false): lets several
  --  processes bind the same addr:port and share the accept load.
  --  TCP, on the same terms as reuse_addr.
  reuse_port: boolean
end
```

### ConnectOptions

 Options for dial and dial_unix.

```teal
local record ConnectOptions
  --  Bound the connect attempt: fail with an error after this many
  --  milliseconds instead of waiting on the kernel's own (much longer)
  --  timeout. The returned socket is BLOCKING either way.
  timeout_ms: integer
end
```

### Interface

 Network interface information.

```teal
local record Interface
  name: string
  ip: ip.Addr
end
```

### NetModule

```teal
local record NetModule
  socket: function(opts?: SocketOptions): Socket | nil, string
  socket_pair: function(opts?: SocketOptions): SocketPair | nil, string
  listen_unix: function(path: string, opts?: ListenOptions): Socket | nil, string
  listen_tcp: function(addr: Address, port: integer, opts?: ListenOptions): Socket | nil, string
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
```

### Socket

 Socket handle for network I/O (see cosmic.net.socket for the methods).
 Supports Lua 5.4's to-be-closed via __close metamethod.

alias of `cosmic.net.socket.Socket` — field and method table: `cosmic --docs cosmic.net.socket.Socket`

### Address

 An address a helper accepts: a dotted-quad string ("127.0.0.1") or a
 typed ip.Addr. Wrap C-boundary integers with ip.from_int().

alias of `cosmic.net.socket.Address` — field and method table: `cosmic --docs cosmic.net.socket.Address`

## Functions

### socket

```teal
function socket(opts?: SocketOptions): Socket | nil, string
```

 Create a new socket.

**Parameters:**

- `opts` (SocketOptions?) - family (default AF_INET), socket_type (default SOCK_STREAM), protocol (default 0)

**Returns:**

- Socket - | nil Socket handle
- string - Error message on failure

### socket_pair

```teal
function socket_pair(opts?: SocketOptions): SocketPair | nil, string
```

 Create a pair of connected sockets.

**Parameters:**

- `opts` (SocketOptions?) - family (default AF_UNIX), socket_type (default SOCK_STREAM), protocol (default 0)

**Returns:**

- SocketPair - | nil Both sockets, on success
- string - Error message on failure

### listen_unix

```teal
function listen_unix(path: string, opts?: ListenOptions): Socket | nil, string
```

 Create a Unix domain socket, bind it to a path, and start listening.

**Parameters:**

- `path` (string) - Filesystem path for the socket
- `opts` (ListenOptions?) - backlog (default 128); the reuse options apply only when set

**Returns:**

- Socket - | nil Listening socket
- string - Error message on failure

### dial

```teal
function dial(host: Address, port: integer, opts?: ConnectOptions): Socket | nil, string
```

 Open a TCP connection to host:port. This name and shape are the
 stable dial contract: host is a dotted-quad literal, a typed
 ip.Addr, or a DNS name — resolution happens inside — and the result
 is a connected Socket. Future address families and richer endpoint
 forms extend the values dial accepts, never the signature.

**Parameters:**

- `host` (Address) - Host to connect to: dotted-quad literal, ip.Addr, or DNS name
- `port` (integer) - Remote TCP port
- `opts` (ConnectOptions?) - timeout_ms bounds the connect attempt

**Returns:**

- Socket - | nil Connected socket
- string - Error message on failure

### dial_unix

```teal
function dial_unix(path: string, opts?: ConnectOptions): Socket | nil, string
```

 Open a connection to a Unix domain socket path.

**Parameters:**

- `path` (string) - Filesystem path of the socket to connect to
- `opts` (ConnectOptions?) - timeout_ms bounds the connect attempt

**Returns:**

- Socket - | nil Connected socket
- string - Error message on failure

### listen_tcp

```teal
function listen_tcp(addr: Address, port: integer, opts?: ListenOptions): Socket | nil, string
```

 Create a TCP socket, bind it to addr:port, and start listening.
 Passing port 0 lets the OS assign an ephemeral port; read it with
 local_endpoint().port. The address may be a dotted-quad string or an
 ip.Addr ("0.0.0.0" binds all interfaces).
 Example — listen on an OS-assigned port:
   local net = require("cosmic.net")
   local srv = assert(net.listen_tcp("127.0.0.1", 0))
   local port = assert(srv:local_endpoint()).port
   local client = net.dial("127.0.0.1", port)
 was requested, read the OS-assigned port with `s:local_endpoint().port`

**Parameters:**

- `addr` (Address) - Local IPv4 address to bind ("127.0.0.1", "0.0.0.0" for all)
- `port` (integer) - Local port to bind; use 0 for an OS-assigned ephemeral port
- `opts` (ListenOptions?) - backlog (default 128), reuse_addr (default true), reuse_port (default false)

**Returns:**

- Socket - | nil Listening socket ready to accept; when port 0
- string - Error message on failure

### hostname

```teal
function hostname(): string | nil, string
```

 The local hostname.

**Returns:**

- string - | nil The hostname
- string - Error message on failure

### interfaces

```teal
function interfaces(): {Interface} | nil, string
```

 List network interfaces and their IPv4 addresses.

**Returns:**

- {Interface} - | nil List of interfaces
- string - Error message on failure
