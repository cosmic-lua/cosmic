# shm

 Shared memory for inter-process communication.
 Provides atomic operations and wait/wake primitives for
 synchronization. Memory created with shm.open (#999: was
 `mapshared`) is shared across fork() and provides fundamental
 synchronization primitives including futexes.

 This is a real wrapper over unix.mapshared, not a passthrough: sizes
 and offsets are validated in Lua (the region size is known at
 open time) so failures return nil, err per the stdlib error
 convention instead of throwing, and residual binding throws are
 pcall-translated.

## Types

### Exchange

 Shared memory region with atomic word operations and futexes.
 One compare-exchange outcome: whether the swap happened, and the
 word's actual value at the time (the old value on success). A
 record rather than (swapped, actual, err) returns — the error is
 in slot 2 where `local r, err = ...` can see it.

```teal
local record Exchange
  swapped: boolean
  value: integer
end
```

### Memory

 Words are 64-bit; word_index is 0-based. Futex words (wait/wake)
 only inspect the low 32 bits — store only int32 values in words
 you wait on.
 Memory ordering (#999, stated because a sync-primitives surface
 without one is a guess): every atomic word operation is
 sequentially consistent (the binding's C11 atomics use the
 default memory_order_seq_cst), so a store or exchange published
 before a wake is visible to the waiter it wakes; plain read/write
 byte access carries NO ordering — publish through the atomics.
 Not a mirror of the generated unix.Memory: this is a deliberately
 narrowed surface whose methods validate bounds in Lua, return
 nil, err instead of throwing, and add size().

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
  exchange: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Compare-and-exchange; returns success plus the actual old value.
  compare_exchange: function(self: Memory, word_index: integer, old: integer, new: integer): Exchange | nil, string
  --  Atomic add; returns the old value.
  fetch_add: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Atomic AND; returns the old value.
  fetch_and: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Atomic OR; returns the old value.
  fetch_or: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Atomic XOR; returns the old value.
  fetch_xor: function(self: Memory, word_index: integer, value: integer): integer | nil, string
  --  Wait until the word no longer holds `expect`. Returns 0 when
  --  woken; nil plus an error naming EAGAIN (value already differed)
  --  or ETIMEDOUT (timeout expired). `timeout_ms` is a RELATIVE
  --  timeout in integer milliseconds; omit it to wait forever. A wait interrupted
  --  by a signal is retried automatically — the deadline is computed
  --  once, up front, so retries keep the timeout exact.
  wait: function(self: Memory, word_index: integer, expect: integer, timeout_ms?: integer): integer | nil, string
  --  Wake processes waiting on a word; returns how many woke.
  --  Wakes nothing once the region has been unmapped.
  wake: function(self: Memory, word_index: integer, count?: integer): integer | nil, string
  --  Release the mapping now instead of waiting for the garbage
  --  collector. Idempotent and returns nothing (#999: it used to
  --  return false for "already released", so asserting the second,
  --  correct call failed). Afterwards every fallible method returns
  --  an error naming the unmapped state.
  close: function(self: Memory)
  --  The mapped region size in bytes.
  size: function(self: Memory): integer
end
```

### ShmModule

 Module type for shared memory operations.

```teal
local record ShmModule
  open: function(size_bytes: integer): Memory | nil, string
end
```

### Memory

alias of `ShmModule.Memory` — field and method table: `cosmic --docs ShmModule.Memory`

### Exchange

alias of `ShmModule.Exchange` — field and method table: `cosmic --docs ShmModule.Exchange`

## Functions

### open

```teal
function open(size_bytes: integer): Memory | nil, string
```

 Creates a shared memory region.
 The memory is shared across fork() and can be used for inter-process
 communication with atomic operations and futex synchronization.
 Example usage for a simple mutex:
 ```lua
 local shm = require("cosmic.shm")
 local mem = assert(shm.open(8000 * 8))
 local LOCK = 0  -- word index for lock
 -- Lock acquisition
 while mem:exchange(LOCK, 1) == 1 do
   mem:wait(LOCK, 1)
 end
 -- Critical section here
 -- Unlock
 mem:store(LOCK, 0)
 mem:wake(LOCK, 1)
 ```

**Parameters:**

- `size_bytes` (integer) - Size in bytes: positive, a multiple of the 8-byte word size

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

### mem:exchange

```teal
function mem:exchange(word_index: integer, value: integer): integer | nil, string
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

### mem:compare_exchange

```teal
function mem:compare_exchange(word_index: integer, old: integer, new: integer): Exchange | nil, string
```

### mem:wait

```teal
function mem:wait(word_index: integer, expect: integer, timeout_ms?: integer): integer | nil, string
```

### mem:wake

```teal
function mem:wake(word_index: integer, count?: integer): integer | nil, string
```

### mem:close

```teal
function mem:close()
```
