# rand

 Random number generation.
 Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
 cosmo.Rand64/Lemur64/Rdrand/Rdseed for fast non-cryptographic use cases.

 Example usage:
   local rand = require("cosmic.rand")
   local key = rand.bytes(32)          -- cryptographically secure
   local n = rand.rand64()             -- fast pseudo-random (not secure)
   local n, err = rand.rdrand()        -- hardware random (may be unavailable)

## Types

### RandModule

```teal
local record RandModule
  bytes: function(n: number): string
  rand64: function(): integer
  lemur64: function(): integer
  rdrand: function(): integer, string
  rdseed: function(): integer, string
end
```

## Functions

### bytes

```teal
function bytes(n: number): string
```

 Generate cryptographically secure random bytes.

**Parameters:**

- `n` (number) - The number of random bytes to generate

**Returns:**

- string - Random bytes

### rand64

```teal
function rand64(): integer
```

 Generate a fast 64-bit pseudo-random integer (non-cryptographic).
 Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.

**Returns:**

- integer - Random 64-bit integer

### lemur64

```teal
function lemur64(): integer
```

 Generate a fast 64-bit pseudo-random integer using Lemire's PRNG (non-cryptographic).
 Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.

**Returns:**

- integer - Random 64-bit integer

### rdrand

```teal
function rdrand(): integer, string
```

 Generate a hardware random integer using Intel RDRAND instruction.
 Returns nil and an error message on CPUs that do not support RDRAND.

**Returns:**

- integer, - string Random integer, or nil and error message if unavailable

### rdseed

```teal
function rdseed(): integer, string
```

 Generate a hardware random seed using Intel RDSEED instruction.
 Returns nil and an error message on CPUs that do not support RDSEED.

**Returns:**

- integer, - string Random seed integer, or nil and error message if unavailable
