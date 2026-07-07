# hash

 Hash utilities.
 Wraps cosmo.Sha256 and cosmo.argon2 for digest and password hashing.

 Example usage:
   local hash = require("cosmic.hash")
   local digest = hash.sha256_hex("hello")
   local encoded = hash.password("password123")
   local valid = hash.verify_password(encoded, "password123")

 For random bytes, use cosmic.rand.bytes(n).

## Types

### HashOptions

 Options for password hashing with Argon2.
 All fields are optional and have sensible defaults.

```teal
local record HashOptions
  --  Memory cost in kibibytes (default: 19456, i.e. 19 MiB per OWASP minimum)
  m_cost: number
  --  Time cost / iterations (default: 3)
  t_cost: number
  --  Parallelism factor (default: 1)
  parallelism: number
  --  Output hash length in bytes (default: 32)
  hash_len: number
  --  Variant: "argon2id" (default), "argon2i", or "argon2d"
  variant: string
end
```

### HashModule

```teal
local record HashModule
  sha256: function(data: string): string
  sha256_hex: function(data: string): string
  hmac_sha256: function(key: string, data: string): string
  constant_time_equal: function(a: string, b: string): boolean
  password: function(pwd: string, options?: HashOptions): string | nil, string
  verify_password: function(encoded: string, pwd: string): boolean, string
end
```

## Functions

### sha256

```teal
function sha256(data: string): string
```

 Compute SHA-256 hash of data.
 Returns raw bytes (32 bytes).

**Parameters:**

- `data` (string) - The data to hash

**Returns:**

- string - The SHA-256 hash as raw bytes

### sha256_hex

```teal
function sha256_hex(data: string): string
```

 Compute SHA-256 hash of data and return as hex string.
 Returns a 64-character lowercase hex string.

**Parameters:**

- `data` (string) - The data to hash

**Returns:**

- string - The SHA-256 hash as a hex string

### hmac_sha256

```teal
function hmac_sha256(key: string, data: string): string
```

 Compute HMAC-SHA256 of data with a secret key (RFC 2104).
 Returns raw bytes (32 bytes); hex-encode with cosmic.codec.encode_hex
 if needed. Compare MACs with constant_time_equal, not ==.

**Parameters:**

- `key` (string) - The secret key
- `data` (string) - The message to authenticate

**Returns:**

- string - The HMAC-SHA256 tag as raw bytes

### constant_time_equal

```teal
function constant_time_equal(a: string, b: string): boolean
```

 Compare two strings in constant time (for digests and MACs).
 A plain == comparison exits at the first differing byte, leaking how
 much of a secret an attacker has guessed; this XOR-accumulates over
 every byte instead. Only the lengths are allowed to short-circuit
 (digest/MAC lengths are public).

**Parameters:**

- `a` (string) - First string
- `b` (string) - Second string

**Returns:**

- boolean - True when a and b are equal

### password

```teal
function password(pwd: string, options?: HashOptions): string | nil, string
```

 Hash a password using Argon2.
 Returns an encoded string suitable for storage.

**Parameters:**

- `pwd` (string) - The password to hash
- `options` (HashOptions?) - Optional configuration for the hash

**Returns:**

- string? - The encoded hash string, or nil on error
- string? - Error message if hashing failed

### verify_password

```teal
function verify_password(encoded: string, pwd: string): boolean, string
```

 Verify a password against an Argon2 encoded hash.
 Returns true on match, false (no error) on clean mismatch, or
 false plus an error string when the hash is malformed or the binding
 reports an error (e.g. "Decoding failed").

**Parameters:**

- `encoded` (string) - The encoded hash string (from password)
- `pwd` (string) - The password to verify

**Returns:**

- boolean - True if the password matches, false otherwise
- string? - Error message if the hash is malformed or another error occurred
