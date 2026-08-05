# net

 Networking and socket utilities.
 Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.
 Addresses are typed (api-review-2): every public signature
 takes a dotted-quad string or an ip.Addr and returns ip.Addr — bare
 integers are not addresses. IPv4 only: IPv6 strings are rejected
 with an explicit "IPv6 not supported" error, and lands later as a
 new Addr family, not a new API.

## Types

### SocketOptions

 Options for socket() and socketpair(): named fields replace the old
 three positional magic ints (api-review-6).

```teal
local record SocketOptions
  --  AF_INET (socket default), AF_UNIX (socketpair default).
  family: integer
  --  SOCK_STREAM (default) or SOCK_DGRAM, optionally OR-ed with flags
  --  like SOCK_NONBLOCK/SOCK_CLOEXEC.
  socktype: integer
  --  IPPROTO_* (default 0: the family's standard protocol).
  protocol: integer
end
```

### Pair

 A connected socket pair, as returned by socketpair(). A record
 rather than (Socket, Socket, err) returns: the old shape typed slot
 2 as a non-nil Socket while returning nil there on failure, and put
 the error in slot 3 where `local a, b = ...` silently lost it.

```teal
local record Pair
  a: Socket
  b: Socket
end
```

### ConnectOptions

 Options for connect_tcp and dial.

```teal
local record ConnectOptions
  --  Bound the connect attempt: fail with an error after this many
  --  milliseconds instead of waiting on the kernel's own (much longer)
  --  timeout. The returned socket is BLOCKING either way (api-review-8:
  --  this option absorbs the old nb_connect, whose manually-managed
  --  socket + non-blocking aftermath was the module's sharpest edge).
  timeout_ms: integer
end
```

### ListenOptions

 Options for listen_tcp.

```teal
local record ListenOptions
  --  Maximum pending connections (default 128); the old positional
  --  between port and the options record, folded in (api-review-6).
  backlog: integer
  --  Set SO_REUSEADDR on the listener (default true: rebinding a
  --  just-closed address must not fail with EADDRINUSE).
  reuseaddr: boolean
  --  Set SO_REUSEPORT on the listener (default false): lets several
  --  processes bind the same addr:port and share the accept load.
  reuseport: boolean
  --  Create a TCP socket, bind it to addr:port, and start listening.
  --  Passing port 0 lets the OS assign an ephemeral port; read it with
  --  getsockname().port. The address may be a dotted-quad string, a raw
  --  integer, or an ip.Addr (0 binds all interfaces). IPv6 is not
  --  supported.
  --  Example — listen on an OS-assigned port:
  --    local net = require("cosmic.net")
  --    local srv = assert(net.listen_tcp("127.0.0.1", 0))
  --    local port = assert(srv:getsockname()).port
  --    local client = net.connect_tcp("127.0.0.1", port)
  --  Amends the api-review-2 recorded decision: the (Socket, port, err)
  --  triple's slot-3 error was invisible to `check.must` and to
  --  `local s, err = ...` — every misuse type-checked and crashed at
  --  runtime. Error-in-slot-2 wins over the port convenience.
  --  was requested, read the OS-assigned port with
  --  `s:getsockname().port` (the old (Socket, port, err) triple put the
  --  error in slot 3, where `check.must` and `local s, err = ...` lost it)
  addr: Address, port: integer, opts?: ListenOptions): Socket | nil, string
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
  socketpair: function(opts?: SocketOptions): Pair | nil, string
  listen_unix: function(path: string, backlog?: integer): Socket | nil, string
  listen_tcp: function(addr: Address, port: integer, opts?: ListenOptions): Socket | nil, string
  connect_unix: function(path: string): Socket | nil, string
  connect_tcp: function(addr: Address, port: integer, opts?: ConnectOptions): Socket | nil, string
  dial: function(host: string, port: integer, opts?: ConnectOptions): Socket | nil, string
  gethostname: function(): string | nil, string
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
  POLLIN: integer
  POLLOUT: integer
  POLLERR: integer
  POLLHUP: integer
  POLLNVAL: integer
  POLLPRI: integer
  POLLRDBAND: integer
  POLLRDHUP: integer
  POLLRDNORM: integer
  POLLWRBAND: integer
  POLLWRNORM: integer
  MSG_PEEK: integer
  MSG_WAITALL: integer
  MSG_OOB: integer
  MSG_DONTROUTE: integer
  MSG_NOSIGNAL: integer
end
```

## Functions

### socket

```teal
function socket(opts?: SocketOptions): Socket | nil, string
```

 Create a new socket.

**Parameters:**

- `opts` (SocketOptions?) - family (default AF_INET), socktype (default SOCK_STREAM), protocol (default 0)

**Returns:**

- Socket - | nil Socket handle
- string - Error message on failure

### socketpair

```teal
function socketpair(opts?: SocketOptions): Pair | nil, string
```

 Create a pair of connected sockets.

**Parameters:**

- `opts` (SocketOptions?) - family (default AF_UNIX), socktype (default SOCK_STREAM), protocol (default 0)

**Returns:**

- Pair - | nil Both sockets, on success
- string - Error message on failure

### listen_unix

```teal
function listen_unix(path: string, backlog?: integer): Socket | nil, string
```

 Create a Unix domain socket, bind it to a path, and start listening.

**Parameters:**

- `path` (string) - Filesystem path for the socket
- `backlog` (integer) - Maximum pending connections (default 128)

**Returns:**

- Socket - | nil Listening socket
- string - Error message on failure

### connect_unix

```teal
function connect_unix(path: string): Socket | nil, string
```

 Create a Unix domain socket and connect to a path.

**Parameters:**

- `path` (string) - Filesystem path of the socket to connect to

**Returns:**

- Socket - | nil Connected socket
- string - Error message on failure

### connect_tcp

```teal
function connect_tcp(addr: Address, port: integer, opts?: ConnectOptions): Socket | nil, string
```

 Create a TCP socket and connect to an address and port.
 The address may be a dotted-quad string ("127.0.0.1") or an ip.Addr.
 IPv6 is not supported. For hostname resolution use dial().

**Parameters:**

- `addr` (Address) - Remote IPv4 address
- `port` (integer) - Remote port
- `opts` (ConnectOptions?) - timeout_ms bounds the attempt

**Returns:**

- Socket - | nil Connected socket
- string - Error message on failure

### dial

```teal
function dial(host: string, port: integer, opts?: ConnectOptions): Socket | nil, string
```

 Open a TCP connection to host:port. This name and shape are the
 stable dial contract (api-review-2, and reserved since): host
 is a dotted-quad literal or a DNS name — resolution happens inside —
 and the result is a connected Socket. Future address families and
 richer endpoint forms extend the values dial accepts, never the
 signature.

**Parameters:**

- `host` (string) - Host to connect to: dotted-quad literal or DNS name
- `port` (integer) - Remote TCP port
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
 getsockname().port. The address may be a dotted-quad string, a raw
 integer, or an ip.Addr (0 binds all interfaces). IPv6 is not
 supported.
 Example — listen on an OS-assigned port:
   local net = require("cosmic.net")
   local srv = assert(net.listen_tcp("127.0.0.1", 0))
   local port = assert(srv:getsockname()).port
   local client = net.connect_tcp("127.0.0.1", port)
 Amends the api-review-2 recorded decision: the (Socket, port, err)
 triple's slot-3 error was invisible to `check.must` and to
 `local s, err = ...` — every misuse type-checked and crashed at
 runtime. Error-in-slot-2 wins over the port convenience.
 was requested, read the OS-assigned port with
 `s:getsockname().port` (the old (Socket, port, err) triple put the
 error in slot 3, where `check.must` and `local s, err = ...` lost it)

**Parameters:**

- `addr` (Address) - Local IPv4 address to bind ("127.0.0.1", "0.0.0.0" for all)
- `port` (integer) - Local port to bind; use 0 for an OS-assigned ephemeral port
- `opts` (ListenOptions?) - backlog (default 128), reuseaddr (default true), reuseport (default false)

**Returns:**

- Socket - | nil Listening socket ready to accept; when port 0
- string - Error message on failure

### gethostname

```teal
function gethostname(): string | nil, string
```

 Get the local hostname.

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
