# rand

 Random number generation.
 Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
 cosmo.Rand64 for fast non-cryptographic use cases.

 Example usage:
   local rand = require("cosmic.rand")
   local key, err = rand.bytes(32)     -- cryptographically secure
   local roll = rand.int(1, 6)         -- crypto-grade, unbiased
   local n = rand.rand64()             -- fast pseudo-random (not secure)

## Types

### RandModule

```teal
local record RandModule
  bytes: function(n: number): string | nil, string
  int: function(min: integer, max: integer): integer | nil, string
  rand64: function(): number
end
```

## Functions

### bytes

```teal
function bytes(n: number): string | nil, string
```

 Generate cryptographically secure random bytes.

**Parameters:**

- `n` (number) - The number of random bytes to generate (1..4194304)

**Returns:**

- string - | nil Random bytes, or nil on failure
- string? - Error message on failure

### rand64

```teal
function rand64(): number
```

 Generate a fast 64-bit pseudo-random integer (non-cryptographic).
 Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.

**Returns:**

- integer - Random 64-bit integer

### int

```teal
function int(min: integer, max: integer): integer | nil, string
```

 Generate a cryptographically secure uniform integer in [min, max]
 (both inclusive). Rejection-sampled over bytes(), so the result is
 unbiased — unlike the common `min + rand % range` shortcut.
 The range size (max - min + 1) must not exceed 2^53.

**Parameters:**

- `min` (integer) - Lower bound (inclusive)
- `max` (integer) - Upper bound (inclusive)

**Returns:**

- integer - | nil The random integer, or nil on failure
- string? - Error message on failure
