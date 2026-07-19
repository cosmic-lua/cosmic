# shm

 Shared memory for inter-process communication.
 Provides atomic operations and wait/wake primitives for synchronization.
 Memory created with mapshared is shared across fork() and provides
 fundamental synchronization primitives including futexes.

 This is a real wrapper over unix.mapshared, not a passthrough: sizes
 and offsets are validated in Lua (the region size is known at
 mapshared time) so failures return nil, err per the stdlib error
 convention instead of throwing, and residual binding throws are
 pcall-translated.

## Types

### Memory

 Shared memory region with atomic word operations and futexes.
 Words are 64-bit; word_index is 0-based. Futex words (wait/wake)
 only inspect the low 32 bits — store only int32 values in words
 you wait on.

```teal
local record Memory
  --  Read bytes from the region. With no bytes count, reads up to the
  --  first NUL byte (string semantics).
  read: function(self: Memory, offset?: integer, bytes?: integer): string | nil, string
  --  Write bytes to the region (appends a NUL when no count is given).
  write: function(self: Memory, data: string, offset?: integer, bytes?: integer): boolean, string
  --  Atomic load of a word.
  load: function(self: Memory, word_index: integer): integer | nil, string
  --  Atomic store to a word.
  store: function(self: Memory, word_index: integer, value: integer): boolean, string
  --  Atomic exchange; returns the old value.
  xchg: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Compare-and-exchange; returns success plus the actual old value.
  cmpxchg: function(self: Memory, word_index: integer, old: integer, new: integer): boolean | nil, integer, string
  --  Atomic add; returns the old value.
  fetch_add: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Atomic AND; returns the old value.
  fetch_and: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Atomic OR; returns the old value.
  fetch_or: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Atomic XOR; returns the old value.
  fetch_xor: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Wait until the word no longer holds `expect`. Returns 0 when
  --  woken; nil plus an error naming EAGAIN (value already differed),
  --  ETIMEDOUT (deadline expired), or EINTR (signal).
  wait: function(self: Memory, word_index: integer, expect: integer, abs_deadline?: integer, nanos?: integer): integer | nil, string
  --  Wake processes waiting on a word; returns how many woke.
  wake: function(self: Memory, word_index: integer, count?: integer): integer
  --  The mapped region size in bytes.
  size: function(self: Memory): integer
end
```

### ShmModule

 Module type for shared memory operations.

```teal
local record ShmModule
  mapshared: function(size: integer): Memory | nil, string
end
```

## Functions

### mapshared

```teal
function mapshared(size: integer): Memory | nil, string
```

 Creates a shared memory region.
 The memory is shared across fork() and can be used for inter-process
 communication with atomic operations and futex synchronization.
 Example usage for a simple mutex:
 ```lua
 local shm = require("cosmic.shm")
 local mem = assert(shm.mapshared(8000 * 8))
 local LOCK = 0  -- word index for lock
 -- Lock acquisition
 while mem:xchg(LOCK, 1) == 1 do
   mem:wait(LOCK, 1)
 end
 -- Critical section here
 -- Unlock
 mem:store(LOCK, 0)
 mem:wake(LOCK, 1)
 ```

**Parameters:**

- `size` (integer) - Size in bytes: positive, a multiple of the 8-byte word size

**Returns:**

- Memory - | nil Shared memory object, or nil on failure
- string? - Error message on failure

### mem:size

```teal
function mem:size(): integer
```

### mem:read

```teal
function mem:read(offset?: integer, bytes?: integer): string | nil, string
```

### mem:write

```teal
function mem:write(data: string, offset?: integer, bytes?: integer): boolean, string
```

### mem:load

```teal
function mem:load(word_index: integer): integer | nil, string
```

### mem:store

```teal
function mem:store(word_index: integer, value: integer): boolean, string
```

### mem:xchg

```teal
function mem:xchg(word_index: integer, value: integer): integer | nil, string
```

### mem:fetch_add

```teal
function mem:fetch_add(word_index: integer, value: integer): integer | nil, string
```

### mem:fetch_and

```teal
function mem:fetch_and(word_index: integer, value: integer): integer | nil, string
```

### mem:fetch_or

```teal
function mem:fetch_or(word_index: integer, value: integer): integer | nil, string
```

### mem:fetch_xor

```teal
function mem:fetch_xor(word_index: integer, value: integer): integer | nil, string
```

### mem:cmpxchg

```teal
function mem:cmpxchg(word_index: integer, old: integer, new: integer): boolean | nil, integer, string
```

### mem:wait

```teal
function mem:wait(word_index: integer, expect: integer, abs_deadline?: integer, nanos?: integer): integer | nil, string
```

### mem:wake

```teal
function mem:wake(word_index: integer, count?: integer): integer
```
