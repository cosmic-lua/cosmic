# uuid

 UUID generation utilities.
 Wraps cosmo UUID functions for generating unique identifiers.

 Example usage:
   local uuid = require("cosmic.uuid")
   local id = uuid.v4()   -- random UUID
   local id = uuid.v7()   -- time-ordered UUID

## Types

### UuidModule

```teal
local record UuidModule
  v4: function(): string
  v7: function(): string
end
```

## Functions

### v4

```teal
function v4(): string
```

 Generate a random UUID (version 4).
 Returns a string in standard UUID format (e.g., "550e8400-e29b-41d4-a716-446655440000").

**Returns:**

- string - A random UUID string

### v7

```teal
function v7(): string
```

 Generate a time-ordered UUID (version 7).
 Returns a string in standard UUID format with embedded timestamp.
 UUIDv7 is useful for database primary keys since time-ordering provides better index locality.

**Returns:**

- string - A time-ordered UUID string
