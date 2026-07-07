# net

 Networking and socket utilities.
 Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.
 IPv4 only: string addresses must be strict dotted quads; IPv6 is
 rejected with an explicit "IPv6 not supported" error.

## Types

### Interface

 Network interface information.

```teal
local record Interface
  name: string
  ip: number
end
```

### NetModule

```teal
local record NetModule
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
```

## Functions

### socket

```teal
function socket(family?: number, socktype?: number, protocol?: number): Socket | nil, string
```

 Create a new socket.

**Parameters:**

- `family` (number) - Address family (AF_INET, AF_UNIX). Default: AF_INET
- `socktype` (number) - Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
- `protocol` (number) - Protocol (IPPROTO_TCP, IPPROTO_UDP). Default: 0

**Returns:**

- Socket - | nil Socket handle
- string - Error message on failure

### socketpair

```teal
function socketpair(family?: number, socktype?: number, protocol?: number): Socket | nil, Socket, string
```

 Create a pair of connected sockets.

**Parameters:**

- `family` (number) - Address family (AF_UNIX). Default: AF_UNIX
- `socktype` (number) - Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
- `protocol` (number) - Protocol. Default: 0

**Returns:**

- Socket - | nil First socket of the pair
- Socket - Second socket of the pair
- string - Error message on failure

### listen_unix

```teal
function listen_unix(path: string, backlog?: number): Socket | nil, string
```

 Create a Unix domain socket, bind it to a path, and start listening.

**Parameters:**

- `path` (string) - Filesystem path for the socket
- `backlog` (number) - Maximum pending connections (default 128)

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
function connect_tcp(addr: Address, port: number): Socket | nil, string
```

 Create a TCP socket and connect to an address and port.
 The address may be a dotted-quad string ("127.0.0.1"), a raw integer
 (0x7f000001), or an ip.Addr. IPv6 is not supported.

**Parameters:**

- `addr` (Address) - Remote IPv4 address
- `port` (number) - Remote port

**Returns:**

- Socket - | nil Connected socket
- string - Error message on failure

### listen_tcp

```teal
function listen_tcp(addr: Address, port: number, backlog?: number): Socket | nil, number, string
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

**Parameters:**

- `addr` (Address) - Local IPv4 address to bind ("127.0.0.1", 0 for all)
- `port` (number) - Local port to bind; use 0 for an OS-assigned ephemeral port
- `backlog` (number) - Maximum pending connections (default 128)

**Returns:**

- Socket - | nil Listening socket ready to accept
- number - Actual bound port (useful when port 0 was requested)
- string - Error message on failure

### nb_connect

```teal
function nb_connect(s: Socket, addr: Address, port: number, timeoutms?: number): boolean, string
```

 Connect with a bounded wait instead of blocking indefinitely.
 Switches the socket to non-blocking mode (via Socket:set_nonblocking),
 starts the connect, and polls for completion up to timeoutms. The
 socket remains in non-blocking mode afterwards; call
 s:set_nonblocking(false) to restore blocking I/O.

**Parameters:**

- `s` (Socket) - The socket to connect
- `addr` (Address) - Remote IPv4 address
- `port` (number) - Remote port
- `timeoutms` (number) - Timeout in milliseconds (default 10000)

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
