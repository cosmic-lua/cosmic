# hash

 Hash utilities.
 Wraps cosmo.GetCryptoHash and cosmo.argon2 for digest, HMAC, and
 password hashing.

 Example usage:
   local hash = require("cosmic.hash")
   local digest = hash.sha256_hex("hello")
   local d = hash.digest("sha512", "hello")
   local tag = hash.hmac("sha256", "secret", "message")
   local encoded = hash.password("password123")
   local valid = hash.verify_password(encoded, "password123")

 Digest and HMAC functions return raw bytes; hex-encode with
 cosmic.codec.encode_hex if needed. For CRC-32 checksums, see
 cosmic.codec.crc32. For random bytes, use cosmic.rand.bytes(n).

 Reserved name: hash.new(algo): Hasher — a streaming digest object
 API (update/final) is reserved for a post-stable battery. Do not
 reuse this name for anything else.

## Types

### HashOptions

 Options for password hashing with Argon2.
 All fields are optional and have sensible defaults.

```teal
local record HashOptions
  --  Memory cost in kibibytes (default: 19456, i.e. 19 MiB per OWASP minimum)
  m_cost: integer
  --  Time cost / iterations (default: 3)
  t_cost: integer
  --  Parallelism factor (default: 1)
  parallelism: integer
  --  Output hash length in bytes (default: 32)
  hash_len: integer
  --  Variant: "argon2id" (default), "argon2i", or "argon2d"
  variant: argon2.Variant
end
```

### HashModule

```teal
local record HashModule
  digest: function(algo: Algo, data: string): string | nil, string
  hmac: function(algo: Algo, key: string, data: string): string | nil, string
  sha256: function(data: string): string
  sha256_hex: function(data: string): string
  hmac_sha256: function(key: string, data: string): string | nil, string
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

### digest

```teal
function digest(algo: Algo, data: string): string | nil, string
```

 Compute a message digest of data with the given algorithm.
 Returns raw bytes; hex-encode with cosmic.codec.encode_hex if
 needed. For the common case, sha256 / sha256_hex are equivalent
 conveniences. MD5 and SHA-1 are provided for interoperability with
 existing formats only — do not use them for new security purposes.

**Parameters:**

- `algo` (Algo) - The digest algorithm
- `data` (string) - The data to hash

**Returns:**

- string - | nil The digest as raw bytes, or nil on error
- string? - Error message if the algorithm is unknown

### hmac

```teal
function hmac(algo: Algo, key: string, data: string): string | nil, string
```

 Compute an HMAC (RFC 2104) of data with a secret key using the
 given digest algorithm. Returns raw bytes; hex-encode with
 cosmic.codec.encode_hex if needed. Compare MACs with
 constant_time_equal, not ==. The key must be non-empty: the C
 binding treats an empty key as "no key" and would silently compute
 a plain digest instead of an HMAC.

**Parameters:**

- `algo` (Algo) - The digest algorithm
- `key` (string) - The secret key (must be non-empty)
- `data` (string) - The message to authenticate

**Returns:**

- string - | nil The HMAC tag as raw bytes, or nil on error
- string? - Error message if the algorithm is unknown or the key is empty

### hmac_sha256

```teal
function hmac_sha256(key: string, data: string): string | nil, string
```

 Compute HMAC-SHA256 of data with a secret key (RFC 2104).
 Returns raw bytes (32 bytes); hex-encode with cosmic.codec.encode_hex
 if needed. Compare MACs with constant_time_equal, not ==. The key
 must be non-empty: the C binding treats an empty key as "no key"
 and would silently compute a plain digest instead of an HMAC.

**Parameters:**

- `key` (string) - The secret key (must be non-empty)
- `data` (string) - The message to authenticate

**Returns:**

- string - | nil The HMAC-SHA256 tag as raw bytes, or nil on error
- string? - Error message if the key is empty

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
