# rand

 Random number generation.
 Wraps cosmo.GetRandomBytes for cryptographically secure randomness.

 Example usage:
   local rand = require("cosmic.rand")
   local key = rand.bytes(32)

## Types

### RandModule

```teal
local record RandModule
  bytes: function(n: number): string
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
