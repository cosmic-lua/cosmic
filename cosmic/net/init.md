# net

 Networking and socket utilities.
 Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.
 Addresses are typed (api-review-2): every public signature
 takes a dotted-quad string or an ip.Addr and returns ip.Addr — bare
 integers are not addresses. IPv4 only: IPv6 strings are rejected
 with an explicit "IPv6 not supported" error, and lands later as a
 new Addr family, not a new API.

## Types

### ListenOptions

 Socket options for listen_tcp: the hidden SO_REUSEADDR is now an
 opt-out, and SO_REUSEPORT an opt-in.

```teal
local record ListenOptions
  --  Set SO_REUSEADDR on the listener (default true: rebinding a
  --  just-closed address must not fail with EADDRINUSE).
  reuseaddr: boolean
  --  Set SO_REUSEPORT on the listener (default false): lets several
  --  processes bind the same addr:port and share the accept load.
  reuseport: boolean
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
  Interface: Interface
  socket: function(family?: integer, socktype?: integer, protocol?: integer): Socket | nil, string
  socketpair: function(family?: integer, socktype?: integer, protocol?: integer): Socket | nil, Socket, string
  listen_unix: function(path: string, backlog?: integer): Socket | nil, string
  listen_tcp: function(addr: Address, port: integer, backlog?: integer, opts?: ListenOptions): Socket | nil, integer, string
  connect_unix: function(path: string): Socket | nil, string
  connect_tcp: function(addr: Address, port: integer): Socket | nil, string
  dial: function(host: string, port: integer): Socket | nil, string
  nb_connect: function(s: Socket, addr: Address, port: integer, timeoutms?: integer): boolean, string
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
function socket(family?: integer, socktype?: integer, protocol?: integer): Socket | nil, string
```

 Create a new socket.

**Parameters:**

- `family` (integer) - Address family (AF_INET, AF_UNIX). Default: AF_INET
- `socktype` (integer) - Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
- `protocol` (integer) - Protocol (IPPROTO_TCP, IPPROTO_UDP). Default: 0

**Returns:**

- Socket - | nil Socket handle
- string - Error message on failure

### socketpair

```teal
function socketpair(family?: integer, socktype?: integer, protocol?: integer): Socket | nil, Socket, string
```

 Create a pair of connected sockets.

**Parameters:**

- `family` (integer) - Address family (AF_UNIX). Default: AF_UNIX
- `socktype` (integer) - Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
- `protocol` (integer) - Protocol. Default: 0

**Returns:**

- Socket - | nil First socket of the pair
- Socket - Second socket of the pair
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
function connect_tcp(addr: Address, port: integer): Socket | nil, string
```

 Create a TCP socket and connect to an address and port.
 The address may be a dotted-quad string ("127.0.0.1") or an ip.Addr.
 IPv6 is not supported. For hostname resolution use dial().

**Parameters:**

- `addr` (Address) - Remote IPv4 address
- `port` (integer) - Remote port

**Returns:**

- Socket - | nil Connected socket
- string - Error message on failure

### dial

```teal
function dial(host: string, port: integer): Socket | nil, string
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

**Returns:**

- Socket - | nil Connected socket
- string - Error message on failure

### listen_tcp

```teal
function listen_tcp(addr: Address, port: integer, backlog?: integer, opts?: ListenOptions): Socket | nil, integer, string
```

 Create a TCP socket, bind it to addr:port, and start listening.
 Passing port 0 lets the OS assign an ephemeral port; the actual port is
 returned as the second value so callers never need a separate getsockname
 call. The address may be a dotted-quad string, a raw integer, or an
 ip.Addr (0 binds all interfaces). IPv6 is not supported.
 Example — listen on an OS-assigned port:
   local net = require("cosmic.net")
   local srv, port, err = net.listen_tcp("127.0.0.1", 0)
   -- port is now the OS-assigned port, e.g. 54321
   local client = net.connect_tcp("127.0.0.1", port)
 Recorded decision (api-review-2): the (Socket, port, err) return
 order — the bound port between the value and the error slot — is
 deliberate port-0 ergonomics, kept as-is rather than reshuffled to the
 usual value-then-error order.

**Parameters:**

- `addr` (Address) - Local IPv4 address to bind ("127.0.0.1", "0.0.0.0" for all)
- `port` (integer) - Local port to bind; use 0 for an OS-assigned ephemeral port
- `backlog` (integer) - Maximum pending connections (default 128)
- `opts` (ListenOptions?) - Socket options (reuseaddr default true, reuseport default false)

**Returns:**

- Socket - | nil Listening socket ready to accept
- integer - Actual bound port (useful when port 0 was requested)
- string - Error message on failure

### nb_connect

```teal
function nb_connect(s: Socket, addr: Address, port: integer, timeoutms?: integer): boolean, string
```

 Connect with a bounded wait instead of blocking indefinitely.
 Switches the socket to non-blocking mode (via Socket:set_nonblocking),
 starts the connect, and polls for completion up to timeoutms. The
 socket remains in non-blocking mode afterwards; call
 s:set_nonblocking(false) to restore blocking I/O.

**Parameters:**

- `s` (Socket) - The socket to connect
- `addr` (Address) - Remote IPv4 address
- `port` (integer) - Remote port
- `timeoutms` (integer) - Timeout in milliseconds (default 10000)

**Returns:**

- boolean - True on success
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
