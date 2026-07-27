# ip

 IP address parsing, formatting, and classification utilities.
 The typed Addr is the only address currency in public signatures
 (api-review-2): parse and lookup return Addr, sockets accept
 and return Addr, and classification lives on Addr methods. The
 implementation is IPv4-only — IPv6 strings are rejected with an
 explicit error — but the shape is ready for IPv6 as a value
 extension: a later "inet6" family is a new Addr value, not a new
 API. Addr:int() exposes the raw v4 integer for the C boundary.

## Types

### Addr

 A typed IP address: the one address type in public signatures.
 Compares by value (two Addrs are == when they hold the same
 address) and formats with tostring().

```teal
local record Addr
  _n: integer
  --  Address family; "inet" for IPv4.
  family: Family
  --  Get the raw integer representation (the IPv4 payload).
  --  Use this at the C boundary or for arithmetic on the raw value.
  int: function(Addr): integer
  --  Format as a dotted-quad string (e.g., "192.168.1.1").
  format: function(Addr): string
  --  Categorize the address (e.g., "LOOPBACK", "PRIVATE", "ARIN").
  categorize: function(Addr): Category
  --  Check if this is a loopback address (127.x.x.x).
  is_loopback: function(Addr): boolean
  --  Check if this is a private address (10.x, 172.16-31.x, 192.168.x).
  is_private: function(Addr): boolean
  --  Check if this is a public/routable address.
  is_public: function(Addr): boolean
end
```

### Cidr

 A parsed IPv4 CIDR block (e.g. "10.0.0.0/8"). Compares by value
 and formats with tostring(). Construct with cidr().

```teal
local record Cidr
  _n: integer
  _bits: integer
  --  Prefix length (0-32).
  bits: function(Cidr): integer
  --  First address of the block (the network address).
  network: function(Cidr): Addr
  --  The netmask (e.g. 255.255.255.0 for /24).
  netmask: function(Cidr): Addr
  --  Last address of the block (the broadcast address).
  broadcast: function(Cidr): Addr
  --  Number of addresses in the block (including network/broadcast).
  size: function(Cidr): integer
  --  Check whether the block contains an address.
  --  message) when a string address does not parse
  contains: function(Cidr, Addr | string): boolean, string
  --  Format as "addr/bits" (same as tostring()).
  format: function(Cidr): string
end
```

### IpModule

```teal
local record IpModule
  Addr: Addr
  addr: function(n: integer): Addr
  parse: function(str: string): Addr | nil, string
  cidr: function(str: string): Cidr | nil, string
  lookup: function(hostname: string): Addr | nil, string
end
```

## Functions

### addr

```teal
function addr(n: integer): Addr
```

 Wrap a raw integer as a typed Addr.
 This is the explicit int-to-Addr constructor for the C boundary
 (e.g. values from cosmo bindings); everything else should already
 hold an Addr.

**Parameters:**

- `n` (integer) - The IP address as an integer

**Returns:**

- Addr - The typed IP address

### parse

```teal
function parse(str: string): Addr | nil, string
```

 Parse an IPv4 address string into a typed Addr.
 Strict dotted quad only: exactly four decimal octets 0-255, no
 leading zeros ("127.1", "1.2.3.4.5", "01.2.3.4" are all errors).
 IPv6 is rejected with an explicit error.

**Parameters:**

- `str` (string) - The IP address string (e.g., "192.168.1.1")

**Returns:**

- Addr - | nil The typed IP address, or nil on error
- string - Error message if parsing failed

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

### cidr

```teal
function cidr(str: string): Cidr | nil, string
```

 Parse an IPv4 CIDR block ("addr/prefix", e.g. "192.168.0.0/16").
 The address part follows parse()'s strict dotted-quad rules; the
 prefix must be a decimal 0-32 without leading zeros. Host bits set
 below the prefix are masked away (like Go's ParseCIDR):
 cidr("10.1.2.3/8") is the 10.0.0.0/8 block.

**Parameters:**

- `str` (string) - The CIDR string to parse

**Returns:**

- Cidr - | nil The parsed block, or nil on error
- string - Error message if parsing failed
