# net

 Networking and socket utilities.
 Wraps cosmo.unix socket functions for TCP/UDP and Unix domain sockets.

## Types

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
  --  Interface name (e.g., "eth0", "lo").
  name: string
  --  IPv4 address as a number.
  ip: number
end
```

### NetModule

```teal
local record NetModule
  socket: function(family?: number, socktype?: number, protocol?: number): Socket, string
  socketpair: function(family?: number, socktype?: number, protocol?: number): Socket, Socket, string
  listen_unix: function(path: string, backlog?: number): Socket, string
  connect_unix: function(path: string): Socket, string
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
  MSG_MORE: number
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

### poll

```teal
function poll(fds: {number: number}, timeoutms?: number): {number: number}, string
```

 Poll file descriptors for events.
 The fds table maps file descriptor numbers to event masks (POLLIN, POLLOUT, etc.).
 Returns a table with the same keys but containing revents for each fd.

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

### sock:close

```teal
function sock:close(): boolean
```

 Close the socket.
 Idempotent: safe to call multiple times.

**Returns:**

- boolean - True on success

### sock:closed

```teal
function sock:closed(): boolean
```

 Check if the socket is closed.

**Returns:**

- boolean - True if closed

### sock:shutdown

```teal
function sock:shutdown(how?: number): boolean, string
```

 Partially close the socket.

**Parameters:**

- `how` (number) - SHUT_RD (0), SHUT_WR (1), or SHUT_RDWR (2). Defaults to SHUT_RDWR.

**Returns:**

- boolean - True on success
- string - Error message on failure

### sock:send

```teal
function sock:send(data: string, flags?: number): number, string
```

 Send data on a connected socket.

**Parameters:**

- `data` (string) - The data to send
- `flags` (number) - Optional send flags (MSG_*)

**Returns:**

- number - Number of bytes sent
- string - Error message on failure

### sock:sendto

```teal
function sock:sendto(data: string, ip: number, port: number, flags?: number): number, string
```

 Send data to a specific address (for UDP).

**Parameters:**

- `data` (string) - The data to send
- `ip` (number) - The destination IP address
- `port` (number) - The destination port
- `flags` (number) - Optional send flags (MSG_*)

**Returns:**

- number - Number of bytes sent
- string - Error message on failure

### sock:recv

```teal
function sock:recv(bufsiz?: number, flags?: number): string, string
```

 Receive data from a connected socket.

**Parameters:**

- `bufsiz` (number) - Maximum bytes to receive (default 65536)
- `flags` (number) - Optional receive flags (MSG_*)

**Returns:**

- string - The received data
- string - Error message on failure

### sock:recvfrom

```teal
function sock:recvfrom(bufsiz?: number, flags?: number): string, number, number, string
```

 Receive data with sender address (for UDP).

**Parameters:**

- `bufsiz` (number) - Maximum bytes to receive (default 65536)
- `flags` (number) - Optional receive flags (MSG_*)

**Returns:**

- string - The received data
- number - Sender IP address
- number - Sender port
- string - Error message on failure

### sock:getsockname

```teal
function sock:getsockname(): number, number, string
```

 Get the local address of the socket.

**Returns:**

- number - Local IP address
- number - Local port
- string - Error message on failure

### sock:getpeername

```teal
function sock:getpeername(): number, number, string
```

 Get the remote address of a connected socket.

**Returns:**

- number - Remote IP address
- number - Remote port
- string - Error message on failure

### sock:bind

```teal
function sock:bind(ip?: number, port?: number): boolean, string
```

 Bind the socket to a local address.

**Parameters:**

- `ip` (number) - Local IP address (default 0 = all interfaces)
- `port` (number) - Local port (default 0 = ephemeral port)

**Returns:**

- boolean - True on success
- string - Error message on failure

### sock:bind_unix

```teal
function sock:bind_unix(path: string): boolean, string
```

 Bind the socket to a Unix domain socket path.

**Parameters:**

- `path` (string) - Filesystem path for the socket

**Returns:**

- boolean - True on success
- string - Error message on failure

### sock:listen

```teal
function sock:listen(backlog?: number): boolean, string
```

 Start listening for incoming connections.

**Parameters:**

- `backlog` (number) - Maximum pending connections (default 128)

**Returns:**

- boolean - True on success
- string - Error message on failure

### sock:accept

```teal
function sock:accept(flags?: number): Socket, number, number, string
```

 Accept an incoming connection.

**Parameters:**

- `flags` (number) - Optional flags (SOCK_CLOEXEC, SOCK_NONBLOCK)

**Returns:**

- Socket - New client socket
- number - Client IP address
- number - Client port
- string - Error message on failure

### sock:connect

```teal
function sock:connect(ip: number, port: number): boolean, string
```

 Connect to a remote address.

**Parameters:**

- `ip` (number) - Remote IP address
- `port` (number) - Remote port

**Returns:**

- boolean - True on success
- string - Error message on failure

### sock:connect_unix

```teal
function sock:connect_unix(path: string): boolean, string
```

 Connect to a Unix domain socket path.

**Parameters:**

- `path` (string) - Filesystem path of the socket to connect to

**Returns:**

- boolean - True on success
- string - Error message on failure

### sock:getsockopt

```teal
function sock:getsockopt(level: number, optname: number): number | boolean, string
```

 Get a socket option value.

**Parameters:**

- `level` (number) - Option level (SOL_SOCKET, SOL_TCP, etc.)
- `optname` (number) - Option name (SO_REUSEADDR, TCP_NODELAY, etc.)

**Returns:**

- number|boolean - Option value
- string - Error message on failure

### sock:setsockopt

```teal
function sock:setsockopt(level: number, optname: number, value: number | boolean): boolean, string
```

 Set a socket option value.

**Parameters:**

- `level` (number) - Option level (SOL_SOCKET, SOL_TCP, etc.)
- `optname` (number) - Option name (SO_REUSEADDR, TCP_NODELAY, etc.)
- `value` (number|boolean) - Option value

**Returns:**

- boolean - True on success
- string - Error message on failure
