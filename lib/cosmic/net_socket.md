# net_socket

 Socket implementation for the networking module.
 Contains the Socket constructor and all Socket method implementations.

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
function sock:send(data: string, flags?: number): number, string
```

### sock:sendto

```teal
function sock:sendto(data: string, ip: number, port: number, flags?: number): number, string
```

### sock:recv

```teal
function sock:recv(bufsiz?: number, flags?: number): string, string
```

### sock:recvfrom

```teal
function sock:recvfrom(bufsiz?: number, flags?: number): string, number, number, string
```

### sock:getsockname

```teal
function sock:getsockname(): number, number, string
```

### sock:getpeername

```teal
function sock:getpeername(): number, number, string
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
function sock:accept(flags?: number): Socket, number, number, string
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
function sock:getsockopt(level: number, optname: number): number | boolean, string
```

### sock:setsockopt

```teal
function sock:setsockopt(level: number, optname: number, value: number | boolean): boolean, string
```
