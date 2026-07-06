# ip

 IP address parsing, formatting, and classification utilities.

## Types

### Addr

 A typed IP address.
 Wraps the raw integer representation with convenience methods.

```teal
local record Addr
  _n: number
  --  Get the raw integer representation.
  --  Use this when passing to net.Socket:connect() or other APIs that take integer IPs.
  int: function(Addr): number
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
  addr: function(n: number): Addr
  parse: function(str: string): integer | nil, string
  format: function(ip: number): string
  categorize: function(ip: number): string
  is_loopback: function(ip: number): boolean
  is_private: function(ip: number): boolean
  is_public: function(ip: number): boolean
  resolve: function(hostname: string): integer | nil, string
  lookup: function(hostname: string): Addr | nil, string
end
```

## Functions

### addr

```teal
function addr(n: number): Addr
```

 Wrap a raw integer as a typed Addr.

**Parameters:**

- `n` (integer) - The IP address as an integer

**Returns:**

- Addr - The typed IP address

### parse

```teal
function parse(str: string): integer | nil, string
```

 Parse an IP address string to its integer representation.
 Invalid or unsupported addresses (including IPv6) are errors.

**Parameters:**

- `str` (string) - The IP address string (e.g., "192.168.1.1")

**Returns:**

- integer - | nil The IP address as an integer, or nil on error
- string - Error message if parsing failed

### format

```teal
function format(ip: number): string
```

 Format an integer IP address as a string.

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- string - The formatted IP address string

### categorize

```teal
function categorize(ip: number): string
```

 Categorize an IP address.
 Returns categories like "LOOPBACK", "PRIVATE", "ARIN", etc.

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- string - The category name

### is_loopback

```teal
function is_loopback(ip: number): boolean
```

 Check if an IP address is a loopback address (127.x.x.x).

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- boolean - True if the address is a loopback address

### is_private

```teal
function is_private(ip: number): boolean
```

 Check if an IP address is a private address.
 Private ranges: 10.x.x.x, 172.16-31.x.x, 192.168.x.x

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- boolean - True if the address is private

### is_public

```teal
function is_public(ip: number): boolean
```

 Check if an IP address is a public/routable address.

**Parameters:**

- `ip` (integer) - The IP address as an integer

**Returns:**

- boolean - True if the address is public

### resolve

```teal
function resolve(hostname: string): integer | nil, string
```

 Resolve a hostname to an IP address.

**Parameters:**

- `hostname` (string) - The hostname to resolve

**Returns:**

- integer - | nil The IP address as an integer, or nil on error
- string - Error message if resolution failed

### lookup

```teal
function lookup(hostname: string): Addr | nil, string
```

 Look up a hostname and return a typed Addr.
 Returns nil and an error message on failure.

**Parameters:**

- `hostname` (string) - The hostname to look up

**Returns:**

- Addr? - The resolved IP address, or nil on error
- string? - Error message on failure
