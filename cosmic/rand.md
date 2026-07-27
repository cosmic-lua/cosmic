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
  bytes: function(n: integer): string | nil, string
  int: function(min: integer, max: integer): integer | nil, string
  float: function(): number | nil, string
  choice: function(list: {any}): any, string
  shuffle: function(list: {any}): {any} | nil, string
  token: function(len?: integer): string | nil, string
  rand64: function(): integer
end
```

## Functions

### bytes

```teal
function bytes(n: integer): string | nil, string
```

 Generate cryptographically secure random bytes.

**Parameters:**

- `n` (integer) - The number of random bytes to generate (1..4194304)

**Returns:**

- string - | nil Random bytes, or nil on failure
- string? - Error message on failure

### rand64

```teal
function rand64(): integer
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

### float

```teal
function float(): number | nil, string
```

 Generate a cryptographically secure uniform float in [0, 1).
 Uses 53 random bits, so the result has full double precision.

**Returns:**

- number - | nil The random float, or nil on failure
- string? - Error message on failure

### choice

```teal
function choice(list: {any}): any, string
```

 Pick one element of a list uniformly at random (crypto-grade).

**Parameters:**

- `list` ({any}) - The list to pick from

**Returns:**

- any - The chosen element, or nil on failure or empty list
- string? - Error message on failure or empty list

### shuffle

```teal
function shuffle(list: {any}): {any} | nil, string
```

 Shuffle a list in place with an unbiased Fisher-Yates pass
 (crypto-grade). Returns the same list for call chaining.

**Parameters:**

- `list` ({any}) - The list to shuffle (mutated in place)

**Returns:**

- {any} - | nil The shuffled list, or nil on failure
- string? - Error message on failure

### token

```teal
function token(len?: integer): string | nil, string
```

 Generate a random alphanumeric token (crypto-grade, unbiased).
 Tokens are URL- and filename-safe. Each character carries ~5.95 bits
 of entropy, so the default 32 characters give ~190 bits.

**Parameters:**

- `len` (integer?) - Token length in characters (default 32)

**Returns:**

- string - | nil The token, or nil on failure
- string? - Error message on failure
