# shm

 Shared memory for inter-process communication.
 Provides atomic operations and wait/wake primitives for synchronization.
 Memory created with mapshared is shared across fork() and provides
 fundamental synchronization primitives including futexes.

## Types

### ShmModule

 Module type for shared memory operations.

```teal
local record ShmModule
  --  Memory record type for shared memory operations.
  --  Memory encapsulates shared memory with atomic operations.
  Methods: 
  read: function(self: Memory, offset?: number, bytes?: number): string
  write: function(self: Memory, data: string, offset?: number, bytes?: number)
  load: function(self: Memory, word_index: number): number
  store: function(self: Memory, word_index: number, value: number)
  xchg: function(self: Memory, word_index: number, value: number): number
  cmpxchg: function(self: Memory, word_index: number, old: number, new: number): boolean, number
  fetch_add: function(self: Memory, word_index: number, value: number): number
  fetch_and: function(self: Memory, word_index: number, value: number): number
  fetch_or: function(self: Memory, word_index: number, value: number): number
  fetch_xor: function(self: Memory, word_index: number, value: number): number
  wait: function(self: Memory, word_index: number, expect: number, abs_deadline?: number, nanos?: number): number
  wake: function(self: Memory, word_index: number, count?: number): number
  mapshared: function(size: number): Memory
  --  Creates a shared memory region.
  --  The memory is shared across fork() and can be used for inter-process
  --  communication with atomic operations and futex synchronization.
  mutex: 
  --  Creates a shared memory region.
  --  The memory is shared across fork() and can be used for inter-process
  --  communication with atomic operations and futex synchronization.
  --  Example usage for a simple mutex:
  --  ```lua
  --  local shm = require("cosmic.shm")
  --  local mem = shm.mapshared(8000 * 8)
  --  local LOCK = 0  -- word index for lock
  --  -- Lock acquisition
  mem: xchg(LOCK, 1) == 1 do
  --  Creates a shared memory region.
  --  The memory is shared across fork() and can be used for inter-process
  --  communication with atomic operations and futex synchronization.
  --  Example usage for a simple mutex:
  --  ```lua
  --  local shm = require("cosmic.shm")
  --  local mem = shm.mapshared(8000 * 8)
  --  local LOCK = 0  -- word index for lock
  --  -- Lock acquisition
  --  while mem:xchg(LOCK, 1) == 1 do
  mem: wait(LOCK, 1)
end
```

## Functions

### mapshared

```teal
function mapshared(size: number): ShmModule.Memory
```

 Creates a shared memory region.
 The memory is shared across fork() and can be used for inter-process
 communication with atomic operations and futex synchronization.
 Example usage for a simple mutex:
 ```lua
 local shm = require("cosmic.shm")
 local mem = shm.mapshared(8000 * 8)
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

- `size` (number) - Size in bytes for the shared memory region

**Returns:**

- Memory - Shared memory object with atomic operations
