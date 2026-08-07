# hash

 Hash utilities.
 Wraps cosmo.GetCryptoHash and cosmo.argon2 for digest, HMAC, and
 password hashing.

 Example usage:
   local hash = require("cosmic.hash")
   local digest = hash.sha256_hex("hello")
   local d = hash.digest("sha512", "hello")
   local d_hex = hash.digest_hex("sha512", "hello")
   local tag = hash.hmac("sha256", "secret", "message")
   local encoded = hash.hash_password("password123")
   local valid = hash.verify_password(encoded, "password123")

 Every raw-bytes function has a `_hex` twin. For CRC-32 checksums,
 see cosmic.codec.crc32. For random bytes, use cosmic.rand.bytes(n).

 Reserved name: hash.new(algo): Hasher — a streaming digest object
 API (update/final) is reserved for a post-stable battery. Do not
 reuse this name for anything else.

## Types

### Options

 Options for password hashing with Argon2.
 All fields are optional and have sensible defaults.

```teal
local record Options
  --  Memory cost in kibibytes (default: 19456, i.e. 19 MiB per OWASP minimum)
  memory_kb: integer
  --  Iteration count / Argon2 time cost (default: 3)
  iterations: integer
  --  Parallelism factor (default: 1)
  parallelism: integer
  --  Output hash length in bytes (default: 32)
  hash_bytes: integer
  --  Variant: "argon2id" (default), "argon2i", or "argon2d"
  variant: Variant
end
```

### HashModule

```teal
local record HashModule
  digest: function(algo: Algo, data: string): string
  digest_hex: function(algo: Algo, data: string): string
  hmac: function(algo: Algo, key: string, data: string): string | nil, string
  hmac_hex: function(algo: Algo, key: string, data: string): string | nil, string
  sha256: function(data: string): string
  sha256_hex: function(data: string): string
  is_equal_constant_time: function(a: string, b: string): boolean
  hash_password: function(pwd: string, opts?: Options): string | nil, string
  verify_password: function(encoded: string, pwd: string): boolean | nil, string
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
function digest(algo: Algo, data: string): string
```

 Compute a message digest of data with the given algorithm.
 Returns raw bytes; digest_hex is the hex twin. For the common case,
 sha256 / sha256_hex are equivalent conveniences. MD5 and SHA-1 are
 provided for interoperability with existing formats only — do not
 use them for new security purposes.
 Infallible: `algo` is the typed enum, so the checker already rejects
 every bad value; a value smuggled past it through a cast is a
 contract violation and throws (D22).

**Parameters:**

- `algo` (Algo) - The digest algorithm
- `data` (string) - The data to hash

**Returns:**

- string - The digest as raw bytes

### digest_hex

```teal
function digest_hex(algo: Algo, data: string): string
```

 Compute a message digest and return it as a lowercase hex string.
 The hex twin of digest.

**Parameters:**

- `algo` (Algo) - The digest algorithm
- `data` (string) - The data to hash

**Returns:**

- string - The digest as a hex string

### hmac

```teal
function hmac(algo: Algo, key: string, data: string): string | nil, string
```

 Compute an HMAC (RFC 2104) of data with a secret key using the
 given digest algorithm. Returns raw bytes; hmac_hex is the hex
 twin. Compare MACs with is_equal_constant_time, not ==. The key
 must be non-empty: the C binding treats an empty key as "no key"
 and would silently compute a plain digest instead of an HMAC —
 and keys arrive from config at runtime, so the empty key reports
 as an error rather than throwing.

**Parameters:**

- `algo` (Algo) - The digest algorithm
- `key` (string) - The secret key (must be non-empty)
- `data` (string) - The message to authenticate

**Returns:**

- string - | nil The HMAC tag as raw bytes, or nil on error
- string? - Error message when the key is empty

### hmac_hex

```teal
function hmac_hex(algo: Algo, key: string, data: string): string | nil, string
```

 Compute an HMAC and return it as a lowercase hex string.
 The hex twin of hmac.

**Parameters:**

- `algo` (Algo) - The digest algorithm
- `key` (string) - The secret key (must be non-empty)
- `data` (string) - The message to authenticate

**Returns:**

- string - | nil The HMAC tag as a hex string, or nil on error
- string? - Error message when the key is empty

### is_equal_constant_time

```teal
function is_equal_constant_time(a: string, b: string): boolean
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

### hash_password

```teal
function hash_password(pwd: string, opts?: Options): string | nil, string
```

 Hash a password using Argon2.
 Returns an encoded string suitable for storage.

**Parameters:**

- `pwd` (string) - The password to hash
- `opts` (Options?) - Optional configuration for the hash

**Returns:**

- string? - The encoded hash string, or nil on error
- string? - Error message if hashing failed

### verify_password

```teal
function verify_password(encoded: string, pwd: string): boolean | nil, string
```

 Verify a password against an Argon2 encoded hash.
 Three honest outcomes, no conflation: `true` on match, `false` (no
 error) on a clean mismatch, and `nil` plus an error string when the
 stored hash is malformed or the binding reports an error — so
 `if hash.verify_password(stored, input) then` can never treat a
 corrupt credential store as a failed login.

**Parameters:**

- `encoded` (string) - The encoded hash string (from hash_password)
- `pwd` (string) - The password to verify

**Returns:**

- boolean - | nil True on match, false on mismatch, nil on error
- string? - Error message when the hash is malformed
