# net_socket

 Socket implementation for the networking module.
 Contains the Socket constructor and all Socket method implementations.

## Types

### Socket

 Socket handle for network I/O.
 Sockets are BLOCKING by default: recv and accept wait until data or a
 connection arrives. Supports Lua 5.4's to-be-closed via __close.

```teal
local record Socket
  --  The underlying file descriptor.
  fd: number
  --  Close the socket.
  close: function(self: Socket): boolean
  --  True when the socket has been closed.
  closed: function(self: Socket): boolean
  --  Shut down reading and/or writing (unix.SHUT_RD/WR/RDWR).
  shutdown: function(self: Socket, how?: number): boolean, string
  --  Send data; returns bytes sent, or nil + error.
  send: function(self: Socket, data: string, flags?: number): number | nil, string
  --  Send a datagram to ip:port; returns bytes sent, or nil + error.
  sendto: function(self: Socket, data: string, ip: number, port: number, flags?: number): number | nil, string
  --  Receive up to bufsiz bytes (blocks until data arrives).
  --  Returns "" (empty string) with no error when the peer closed the
  --  connection (EOF); returns nil + error message on failure.
  recv: function(self: Socket, bufsiz?: number, flags?: number): string | nil, string
  --  Receive a datagram; returns data, sender ip, sender port.
  recvfrom: function(self: Socket, bufsiz?: number, flags?: number): string | nil, number, number, string
  --  Local address as (ip, port); use after bind(0) for the real port.
  getsockname: function(self: Socket): number | nil, number, string
  --  Peer address as (ip, port).
  getpeername: function(self: Socket): number | nil, number, string
  --  Bind to a local ip:port (integers; port 0 = OS-assigned).
  bind: function(self: Socket, ip?: number, port?: number): boolean, string
  --  Bind to a unix-domain socket path.
  bind_unix: function(self: Socket, path: string): boolean, string
  --  Start listening for connections.
  listen: function(self: Socket, backlog?: number): boolean, string
  --  Accept one connection (blocks until a client connects).
  --  Returns the connection socket, peer ip, peer port.
  accept: function(self: Socket, flags?: number): Socket | nil, number, number, string
  --  Connect to ip:port (integers; see cosmic.ip.parse for strings).
  connect: function(self: Socket, ip: number, port: number): boolean, string
  --  Connect to a unix-domain socket path.
  connect_unix: function(self: Socket, path: string): boolean, string
  --  Read a socket option value.
  getsockopt: function(self: Socket, level: number, optname: number): number | boolean | nil, string
  --  Set a socket option value.
  setsockopt: function(self: Socket, level: number, optname: number, value: number | boolean): boolean, string
end
```

### NetSocketModule

```teal
local record NetSocketModule
  make_socket: function(fd: number): Socket
end
```

## Functions

### make_socket

```teal
function make_socket(fd: number): Socket
```

 Create a socket handle from a file descriptor.

**Parameters:**

- `fd` (number) - The file descriptor

**Returns:**

- Socket - The socket handle

### sock:close

```teal
function sock:close(): boolean
```

### sock:closed

```teal
function sock:closed(): boolean
```

### sock:shutdown

```teal
function sock:shutdown(how?: number): boolean, string
```

### sock:send

```teal
function sock:send(data: string, flags?: number): number | nil, string
```

### sock:sendto

```teal
function sock:sendto(data: string, ip: number, port: number, flags?: number): number | nil, string
```

### sock:recv

```teal
function sock:recv(bufsiz?: number, flags?: number): string | nil, string
```

### sock:recvfrom

```teal
function sock:recvfrom(bufsiz?: number, flags?: number): string | nil, number, number, string
```

### sock:getsockname

```teal
function sock:getsockname(): number | nil, number, string
```

### sock:getpeername

```teal
function sock:getpeername(): number | nil, number, string
```

### sock:bind

```teal
function sock:bind(ip?: number, port?: number): boolean, string
```

### sock:bind_unix

```teal
function sock:bind_unix(path: string): boolean, string
```

### sock:listen

```teal
function sock:listen(backlog?: number): boolean, string
```

### sock:accept

```teal
function sock:accept(flags?: number): Socket | nil, number, number, string
```

### sock:connect

```teal
function sock:connect(ip: number, port: number): boolean, string
```

### sock:connect_unix

```teal
function sock:connect_unix(path: string): boolean, string
```

### sock:getsockopt

```teal
function sock:getsockopt(level: number, optname: number): number | boolean | nil, string
```

### sock:setsockopt

```teal
function sock:setsockopt(level: number, optname: number, value: number | boolean): boolean, string
```
