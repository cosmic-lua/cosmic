# ip

 IP address parsing, formatting, and classification utilities.

## Types

### Addr

 A typed IP address.
 Wraps the raw integer representation with convenience methods.

```teal
local record Addr
  _n: integer
  --  Get the raw integer representation.
  Socket: connect() or other APIs that take integer IPs.
  --  Get the raw integer representation.
  --  Use this when passing to net.Socket:connect() or other APIs that take integer IPs.
  int: function(Addr): integer
  --  Format as a dotted-quad string (e.g., "192.168.1.1").
  format: function(Addr): string
  --  Categorize the address (e.g., "LOOPBACK", "PRIVATE", "ARIN").
  categorize: function(Addr): string
  --  Check if this is a loopback address (127.x.x.x).
  is_loopback: function(Addr): boolean
  --  Check if this is a private address (10.x, 172.16-31.x, 192.168.x).
  is_private: function(Addr): boolean
  --  Check if this is a public/routable address.
  is_public: function(Addr): boolean
end
```

### IpModule

```teal
local record IpModule
  Addr: Addr
  addr: function(n: integer): Addr
  parse: function(str: string): integer
  format: function(ip: integer): string
  categorize: function(ip: integer): string
  is_loopback: function(ip: integer): boolean
  is_private: function(ip: integer): boolean
  is_public: function(ip: integer): boolean
  resolve: function(hostname: string): integer
  lookup: function(hostname: string): Addr, string
end
```

## Functions

### addr

```teal
function addr(n: integer): Addr
```

 Wrap a raw integer as a typed Addr.

**Parameters:**

- `n` (integer) - The IP address as an integer

**Returns:**

- Addr - The typed IP address

### parse

```teal
function parse(str: string): integer
```

 Parse an IP address string to its integer representation.
 Returns -1 for invalid or unsupported addresses (including IPv6).

**Parameters:**

- `str` (string) - The IP address string (e.g., "192.168.1.1")

**Returns:**

- integer - The IP address as an integer, or -1 on error

### format

```teal
function format(ip: integer): string
```

 Format an integer IP address as a string.

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- string - The formatted IP address string

### categorize

```teal
function categorize(ip: integer): string
```

 Categorize an IP address.
 Returns categories like "LOOPBACK", "PRIVATE", "ARIN", etc.

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- string - The category name

### is_loopback

```teal
function is_loopback(ip: integer): boolean
```

 Check if an IP address is a loopback address (127.x.x.x).

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- boolean - True if the address is a loopback address

### is_private

```teal
function is_private(ip: integer): boolean
```

 Check if an IP address is a private address.
 Private ranges: 10.x.x.x, 172.16-31.x.x, 192.168.x.x

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- boolean - True if the address is private

### is_public

```teal
function is_public(ip: integer): boolean
```

 Check if an IP address is a public/routable address.

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- boolean - True if the address is public

### resolve

```teal
function resolve(hostname: string): integer
```

 Resolve a hostname to an IP address.

**Parameters:**

- `hostname` (string) - The hostname to resolve

**Returns:**

- integer - The IP address as an integer, or -1 on error

### lookup

```teal
function lookup(hostname: string): Addr, string
```

 Look up a hostname and return a typed Addr.
 Returns nil and an error message on failure.

**Parameters:**

- `hostname` (string) - The hostname to look up

**Returns:**

- Addr? - The resolved IP address, or nil on error
- string? - Error message on failure
