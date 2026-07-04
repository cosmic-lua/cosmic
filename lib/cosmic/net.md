# net

 Networking and socket utilities.
 Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.

## Types

### NetSocket

```teal
local record NetSocket
  make_socket: function(fd: number): Socket
end
```

### Socket

 Socket handle for network I/O.
 Supports Lua 5.4's to-be-closed via __close metamethod.

```teal
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
```

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
  Socket: Socket
  Interface: Interface
  socket: function(family?: number, socktype?: number, protocol?: number): Socket, string
  socketpair: function(family?: number, socktype?: number, protocol?: number): Socket, Socket, string
  listen_unix: function(path: string, backlog?: number): Socket, string
  listen_tcp: function(ip: number, port: number, backlog?: number): Socket, number, string
  connect_unix: function(path: string): Socket, string
  connect_tcp: function(ip: number, port: number): Socket, string
  nb_connect: function(s: Socket, ip: number, port: number, timeoutms?: number): boolean, string
  poll: function(fds: {number: number}, timeoutms?: number): {number: number}, string
  gethostname: function(): string, string
  parseip: function(str: string): number, string
  formatip: function(ip: number): string
  interfaces: function(): {Interface}, string
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
function socket(family?: number, socktype?: number, protocol?: number): Socket, string
```

 Create a new socket.

**Parameters:**

- `family` (number) - Address family (AF_INET, AF_UNIX). Default: AF_INET
- `socktype` (number) - Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
- `protocol` (number) - Protocol (IPPROTO_TCP, IPPROTO_UDP). Default: 0

**Returns:**

- Socket - Socket handle
- string - Error message on failure

### socketpair

```teal
function socketpair(family?: number, socktype?: number, protocol?: number): Socket, Socket, string
```

 Create a pair of connected sockets.

**Parameters:**

- `family` (number) - Address family (AF_UNIX). Default: AF_UNIX
- `socktype` (number) - Socket type (SOCK_STREAM, SOCK_DGRAM). Default: SOCK_STREAM
- `protocol` (number) - Protocol. Default: 0

**Returns:**

- Socket - First socket of the pair
- Socket - Second socket of the pair
- string - Error message on failure

### listen_unix

```teal
function listen_unix(path: string, backlog?: number): Socket, string
```

 Create a Unix domain socket, bind it to a path, and start listening.

**Parameters:**

- `path` (string) - Filesystem path for the socket
- `backlog` (number) - Maximum pending connections (default 128)

**Returns:**

- Socket - Listening socket
- string - Error message on failure

### connect_unix

```teal
function connect_unix(path: string): Socket, string
```

 Create a Unix domain socket and connect to a path.

**Parameters:**

- `path` (string) - Filesystem path of the socket to connect to

**Returns:**

- Socket - Connected socket
- string - Error message on failure

### connect_tcp

```teal
function connect_tcp(ip: number, port: number): Socket, string
```

 Create a TCP socket and connect to an IP address and port.
 The IP is an integer (e.g. 0x7f000001 for 127.0.0.1). To convert a
 dotted-quad string, use cosmic.ip:
   local ip = require("cosmic.ip")
   local addr = ip.parse("127.0.0.1")  -- 0x7f000001

**Parameters:**

- `ip` (number) - Remote IP address
- `port` (number) - Remote port

**Returns:**

- Socket - Connected socket
- string - Error message on failure

### listen_tcp

```teal
function listen_tcp(ip: number, port: number, backlog?: number): Socket, number, string
```

 Create a TCP socket, bind it to host:port, and start listening.
 Passing port 0 lets the OS assign an ephemeral port; the actual port is
 returned as the second value so callers never need a separate getsockname
 call. The IP is an integer; convert strings with
 require("cosmic.ip").parse("127.0.0.1").
 Example — listen on an OS-assigned port:
   local net = require("cosmic.net")
   local srv, port, err = net.listen_tcp(0x7f000001, 0)
   -- port is now the OS-assigned port, e.g. 54321
   local client = net.connect_tcp(0x7f000001, port)

**Parameters:**

- `ip` (number) - Local IP address to bind (e.g. 0x7f000001 for 127.0.0.1, 0 for all)
- `port` (number) - Local port to bind; use 0 for an OS-assigned ephemeral port
- `backlog` (number) - Maximum pending connections (default 128)

**Returns:**

- Socket - Listening socket ready to accept
- number - Actual bound port (useful when port 0 was requested)
- string - Error message on failure

### nb_connect

```teal
function nb_connect(s: Socket, ip: number, port: number, timeoutms?: number): boolean, string
```

 Perform a non-blocking connect on a socket.

**Parameters:**

- `s` (Socket) - The non-blocking socket to connect
- `ip` (number) - Remote IP address
- `port` (number) - Remote port
- `timeoutms` (number) - Timeout in milliseconds (default 10000)

**Returns:**

- boolean - True on success
- string - Error message on failure

### poll

```teal
function poll(fds: {number: number}, timeoutms?: number): {number: number}, string
```

 Poll file descriptors for events.

**Parameters:**

- `fds` ({number:number}) - Map of fd to events to poll for
- `timeoutms` (number) - Timeout in milliseconds (-1 for infinite, 0 for non-blocking)

**Returns:**

- {number:number} - Map of fd to revents
- string - Error message on failure

### gethostname

```teal
function gethostname(): string, string
```

 Get the local hostname.

**Returns:**

- string - The hostname
- string - Error message on failure

### parseip

```teal
function parseip(str: string): number, string
```

 Parse an IP address string to numeric form.

**Parameters:**

- `str` (string) - IP address in dotted notation (e.g., "127.0.0.1")

**Returns:**

- number - Numeric IP address
- string - Error message on failure

### formatip

```teal
function formatip(ip: number): string
```

 Format a numeric IP address to string.

**Parameters:**

- `ip` (number) - Numeric IP address

**Returns:**

- string - IP address in dotted notation

### interfaces

```teal
function interfaces(): {Interface}, string
```

 List network interfaces and their IPv4 addresses.

**Returns:**

- {Interface} - List of interfaces
- string - Error message on failure
