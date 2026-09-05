# ksuid

 K-Sortable Unique IDs: 20 bytes — a 4-byte big-endian timestamp
 (seconds since the KSUID epoch, 2014-05-13) followed by 16 random
 bytes — base62-encoded to a fixed 27 characters. The alphabet is
 ascending ASCII, so LEXICOGRAPHIC ORDER IS CREATION ORDER: sorting
 ids as plain strings sorts them oldest-first, with no separate
 timestamp field to drift from the truth. Two callers minting ids
 never coordinate and never collide (128 random bits), which is
 exactly what a distributed system needs where a central counter
 (an auto-increment column, an issue number) isn't available.

 Example usage:
   local ksuid = require("cosmic.ksuid")
   local id = ksuid.new()               -- a fresh, sortable id
   local seconds = ksuid.time_of(id)     -- the creation time it carries

## Types

### KsuidModule

```teal
local record KsuidModule
  LEN: integer
  is_id: function(id: string): boolean
  encode: function(seconds: integer, payload: string): string | nil, string
  new: function(): string
  time_of: function(id: string): integer | nil, string
end
```

## Functions

### is_id

```teal
function is_id(id: string): boolean
```

 Whether a string is a well-formed KSUID: exactly 27 base62 bytes.

**Parameters:**

- `id` (string) - Candidate id

**Returns:**

- boolean - True when well-formed

### encode

```teal
function encode(seconds: integer, payload: string): string | nil, string
```

 A KSUID from its two fields. The one constructor `new` and the
 tests share, so a test minting deterministic ids exercises the
 same encoding a live call does.

**Parameters:**

- `seconds` (integer) - Unix seconds; must be at or after the KSUID epoch
- `payload` (string) - Exactly 16 bytes of entropy

**Returns:**

- string - | nil The 27-character id
- string - Error message

### new

```teal
function new(): string
```

 A fresh id: now, with 16 CSPRNG bytes. `time.now()` and
 `rand.bytes(16)` are both infallible, and the offset from the KSUID
 epoch stays in range for a very long time, so this never routes
 through a value that can be nil.

**Returns:**

- string - The 27-character id

### time_of

```teal
function time_of(id: string): integer | nil, string
```

 The creation time an id carries.

**Parameters:**

- `id` (string) - A KSUID

**Returns:**

- integer - | nil Unix seconds
- string - Error message for a malformed id
