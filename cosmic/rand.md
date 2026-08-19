# rand

 Random bytes, integers, floats, choice, shuffle, and tokens.
 Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
 cosmo.Rand64 for fast non-cryptographic use cases.

 Every function here is INFALLIBLE: on every supported platform
 the kernel CSPRNG cannot fail once the system has booted, so there is
 no runtime failure for a return slot to carry. Out-of-range arguments
 are contract violations and throw — the one thing that must never
 happen is code limping on without entropy. Callers check nothing.

 A second, deliberately-insecure surface lives alongside the CSPRNG one:
 rand.insecure_source(seed) returns a seedable, reproducible Source for
 callers that need randomness to replay rather than to be unguessable.

 Example usage:
   local rand = require("cosmic.rand")
   local key = rand.bytes(32)          -- cryptographically secure
   local roll = rand.int(1, 6)         -- crypto-grade, unbiased
   local n = rand.insecure64()         -- fast pseudo-random (not secure)
   local src = rand.insecure_source(42) -- seedable, reproducible (NOT secure)

## Types

### Source

 A seedable, non-cryptographic pseudo-random source. NOT part of the
 CSPRNG surface: draws are cheap and reproducible, never secure, and
 must never be used for anything security-sensitive (use rand.bytes,
 rand.int, or rand.token for that).
 Each Source owns private state and never reads or reseeds Lua's
 global math.random()/math.randomseed() — drawing from one Source
 cannot perturb another Source, math.random() elsewhere in the
 process, or (once a future slice wires it in) `_fuzz`'s own replay
 stream. This is the property that makes it usable inside code a
 fuzz property exercises without desyncing replay.

```teal
local record Source
  --  Draw a pseudo-random integer in [min, max] (inclusive). A simple
  --  modulo reduction, not rejection-sampled like rand.int — adequate
  --  for jitter/backoff and fuzz-input generation, not a uniformity
  --  guarantee. Throws on min > max (contract violation, same
  --  convention rand.int already uses).
  int: function(Source, integer, integer): integer
  --  Draw a pseudo-random float in [0, 1).
  float: function(Source): number
end
```

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
  insecure_source: function(seed: integer): Source
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

### insecure_source

```teal
function insecure_source(seed: integer): Source
```

 Create a new seedable, non-cryptographic pseudo-random source.
 The same seed reproduces the same sequence of draws WITHIN ONE
 PROCESS. This is NOT a stability guarantee: the algorithm may
 change in a future cosmic release, so a recorded seed is only
 meaningful for replay within roughly the same build/session
 (matching _fuzz/driver.tl's own replay promise) — never treat it
 as a byte-stable format to pin across releases.

**Parameters:**

- `seed` (integer) - The seed

**Returns:**

- Source - A new pseudo-random source
