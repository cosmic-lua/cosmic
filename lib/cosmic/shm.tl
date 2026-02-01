--- Shared memory for inter-process communication.
--- Provides atomic operations and wait/wake primitives for synchronization.
--- Memory created with mapshared is shared across fork() and provides
--- fundamental synchronization primitives including futexes.
local unix = require("cosmo.unix")

--- Module type for shared memory operations.
local record ShmModule
  --- Memory record type for shared memory operations.
  --- Memory encapsulates shared memory with atomic operations.
  ---
  --- Methods:
  --- - read(offset?, bytes?): Read bytes from memory region
  --- - write(data, offset?, bytes?): Write bytes to memory region
  --- - load(word_index): Atomic load of word
  --- - store(word_index, value): Atomic store of word
  --- - xchg(word_index, value): Atomic exchange, returns old value
  --- - cmpxchg(word_index, old, new): Compare-and-exchange, returns success and actual value
  --- - fetch_add(word_index, value): Atomic add, returns old value
  --- - fetch_and(word_index, value): Atomic AND, returns old value
  --- - fetch_or(word_index, value): Atomic OR, returns old value
  --- - fetch_xor(word_index, value): Atomic XOR, returns old value
  --- - wait(word_index, expect, abs_deadline?, nanos?): Wait for word to change
  --- - wake(word_index, count?): Wake waiting processes
  record Memory
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
  end
  mapshared: function(size: number): Memory
end

--- Creates a shared memory region.
--- The memory is shared across fork() and can be used for inter-process
--- communication with atomic operations and futex synchronization.
---
--- Example usage for a simple mutex:
--- ```lua
--- local shm = require("cosmic.shm")
--- local mem = shm.mapshared(8000 * 8)
--- local LOCK = 0  -- word index for lock
---
--- -- Lock acquisition
--- while mem:xchg(LOCK, 1) == 1 do
---   mem:wait(LOCK, 1)
--- end
---
--- -- Critical section here
---
--- -- Unlock
--- mem:store(LOCK, 0)
--- mem:wake(LOCK, 1)
--- ```
---
--- @param size number Size in bytes for the shared memory region
--- @return Memory Shared memory object with atomic operations
local function mapshared(size: number): ShmModule.Memory
  return unix.mapshared(size) as ShmModule.Memory
end

local M: ShmModule = {
  mapshared = mapshared,
}

return M
