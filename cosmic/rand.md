# rand

 Random bytes, integers, floats, choice, shuffle, and tokens.
 Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
 cosmo.Rand64 for fast non-cryptographic use cases.

 Every function here is INFALLIBLE (D22): on every supported platform
 the kernel CSPRNG cannot fail once the system has booted, so there is
 no runtime failure for a return slot to carry. Out-of-range arguments
 are contract violations and throw — the one thing that must never
 happen is code limping on without entropy. Callers check nothing.

 Example usage:
   local rand = require("cosmic.rand")
   local key = rand.bytes(32)          -- cryptographically secure
   local roll = rand.int(1, 6)         -- crypto-grade, unbiased
   local n = rand.insecure64()         -- fast pseudo-random (not secure)

## Types

### RandModule

```teal
local record RandModule
  bytes: function(n: integer): string
  int: function(min: integer, max: integer): integer
  float: function(): number
  choice: function(list: {any}): any
  shuffle: function(list: {any}): {any}
  token: function(len?: integer): string
  insecure64: function(): integer
end
```

## Functions

### bytes

```teal
function bytes(n: integer): string
```

 Generate cryptographically secure random bytes.

**Parameters:**

- `n` (integer) - The number of random bytes to generate (1..4194304)

**Returns:**

- string - n random bytes

### insecure64

```teal
function insecure64(): integer
```

 Generate a fast 64-bit pseudo-random integer (non-cryptographic).
 Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.

**Returns:**

- integer - Random 64-bit integer

### int

```teal
function int(min: integer, max: integer): integer
```

 Generate a cryptographically secure uniform integer in [min, max]
 (both inclusive). Rejection-sampled over bytes(), so the result is
 unbiased — unlike the common `min + rand % range` shortcut.
 The range size (max - min + 1) must not exceed 2^53.

**Parameters:**

- `min` (integer) - Lower bound (inclusive)
- `max` (integer) - Upper bound (inclusive)

**Returns:**

- integer - The random integer

### float

```teal
function float(): number
```

 Generate a cryptographically secure uniform float in [0, 1).
 Uses 53 random bits, so the result has full double precision.

**Returns:**

- number - The random float

### choice

```teal
function choice(list: {any}): any
```

 Pick one element of a list uniformly at random (crypto-grade).

**Parameters:**

- `list` ({any}) - The list to pick from

**Returns:**

- any - The chosen element; nil only when the list is empty

### shuffle

```teal
function shuffle(list: {any}): {any}
```

 Shuffle a list in place with an unbiased Fisher-Yates pass
 (crypto-grade). Returns the same list for call chaining.

**Parameters:**

- `list` ({any}) - The list to shuffle (mutated in place)

**Returns:**

- {any} - The shuffled list

### token

```teal
function token(len?: integer): string
```

 Generate a random alphanumeric token (crypto-grade, unbiased).
 Tokens are URL- and filename-safe. Each character carries ~5.95 bits
 of entropy, so the default 32 characters give ~190 bits.

**Parameters:**

- `len` (integer?) - Token length in characters (default 32, must be positive)

**Returns:**

- string - The token
