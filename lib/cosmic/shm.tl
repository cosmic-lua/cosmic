--- Shared memory for inter-process communication.
--- Provides atomic operations and wait/wake primitives for synchronization.
--- Memory created with mapshared is shared across fork() and provides
--- fundamental synchronization primitives including futexes.
---
--- This is a real wrapper over unix.mapshared, not a passthrough: sizes
--- and offsets are validated in Lua (the region size is known at
--- mapshared time) so failures return nil, err per the stdlib error
--- convention instead of throwing, and residual binding throws are
--- pcall-translated.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

local WORD = 8

--- Module type for shared memory operations.
local record ShmModule
  --- Shared memory region with atomic word operations and futexes.
  --- Words are 64-bit; word_index is 0-based. Futex words (wait/wake)
  --- only inspect the low 32 bits — store only int32 values in words
  --- you wait on.
  --- Not a mirror of the generated unix.Memory: this is a deliberately
  --- narrowed surface whose methods validate bounds in Lua, return
  --- nil, err instead of throwing, and add size().
  record Memory
    --- Read bytes from the region. With no bytes count, reads up to the
    --- first NUL byte (string semantics).
    read: function(self: Memory, offset?: integer, bytes?: integer): string | nil, string
    --- Write bytes to the region (appends a NUL when no count is given).
    write: function(self: Memory, data: string, offset?: integer, bytes?: integer): boolean, string
    --- Atomic load of a word.
    load: function(self: Memory, word_index: integer): integer | nil, string
    --- Atomic store to a word.
    store: function(self: Memory, word_index: integer, value: integer): boolean, string
    --- Atomic exchange; returns the old value.
    xchg: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Compare-and-exchange; returns success plus the actual old value.
    cmpxchg: function(self: Memory, word_index: integer, old: integer, new: integer): boolean | nil, integer, string
    --- Atomic add; returns the old value.
    fetch_add: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Atomic AND; returns the old value.
    fetch_and: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Atomic OR; returns the old value.
    fetch_or: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Atomic XOR; returns the old value.
    fetch_xor: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Wait until the word no longer holds `expect`. Returns 0 when
    --- woken; nil plus an error naming EAGAIN (value already differed),
    --- ETIMEDOUT (deadline expired), or EINTR (signal).
    wait: function(self: Memory, word_index: integer, expect: integer, abs_deadline?: integer, nanos?: integer): integer | nil, string
    --- Wake processes waiting on a word; returns how many woke.
    wake: function(self: Memory, word_index: integer, count?: integer): integer
    --- The mapped region size in bytes.
    size: function(self: Memory): integer
  end
  mapshared: function(size: integer): Memory | nil, string
end

local type Memory = ShmModule.Memory

--- Validate a 0-based word index against the region size.
local function check_word(word_index: integer, size: integer, op: string): string
  if word_index == nil or word_index < 0 or word_index >= size // WORD then
    return op .. ": word_index out of range (0-" .. tostring(size // WORD - 1)
    .. "): " .. tostring(word_index)
  end
  return nil
end

--- Translate a pcall failure (a residual binding throw) into the
--- error-return convention.
local function thrown(op: string, err: any): string
  return errstr(err, op)
end

--- Wrap the raw unix.Memory userdata in a Memory record whose methods
--- validate bounds in Lua and return nil, err instead of throwing.
local function wrap(raw: unix.Memory, size: integer): Memory
  local mem: Memory = {}

  function mem:size(): integer
    return size
  end

  function mem:read(offset?: integer, bytes?: integer): string | nil, string
    local off = offset or 0
    if off < 0 or off > size then
      return nil, "read: offset out of range (0-" .. tostring(size) .. "): " .. tostring(off)
    end
    if bytes ~= nil and (bytes < 0 or off + bytes > size) then
      return nil, "read: byte range out of range (offset " .. tostring(off)
      .. " + " .. tostring(bytes) .. " > " .. tostring(size) .. ")"
    end
    local ok, res = pcall(raw.read, raw, offset, bytes)
    if not ok then
      return nil, thrown("read", res)
    end
    return res as string
  end

  function mem:write(data: string, offset?: integer, bytes?: integer): boolean, string
    local off = offset or 0
    local n = bytes or #data
    if n > #data then
      n = #data
    end
    if off < 0 or off + n > size then
      return false, "write: byte range out of range (offset " .. tostring(off)
      .. " + " .. tostring(n) .. " > " .. tostring(size) .. ")"
    end
    local ok, err = pcall(raw.write, raw, data, offset, bytes) as(boolean, any)
    if not ok then
      return false, thrown("write", err)
    end
    return true
  end

  function mem:load(word_index: integer): integer | nil, string
    local range_err = check_word(word_index, size, "load")
    if range_err then
      return nil, range_err
    end
    local ok, res = pcall(raw.load, raw, word_index)
    if not ok then
      return nil, thrown("load", res)
    end
    return res as integer
  end

  function mem:store(word_index: integer, value: integer): boolean, string
    local range_err = check_word(word_index, size, "store")
    if range_err then
      return false, range_err
    end
    local ok, err = pcall(raw.store, raw, word_index, value) as(boolean, any)
    if not ok then
      return false, thrown("store", err)
    end
    return true
  end

  -- Shared body for the atomic read-modify-write word operations.
  local function atomic(op: string, fn: function(unix.Memory, integer, integer): integer, word_index: integer, value: integer): integer | nil, string
    local range_err = check_word(word_index, size, op)
    if range_err then
      return nil, range_err
    end
    local ok, res = pcall(fn, raw, word_index, value)
    if not ok then
      return nil, thrown(op, res)
    end
    return res as integer
  end

  function mem:xchg(word_index: integer, value: integer): integer | nil, string
    return atomic("xchg", raw.xchg, word_index, value)
  end

  function mem:fetch_add(word_index: integer, value: integer): integer | nil, string
    return atomic("fetch_add", raw.fetch_add, word_index, value)
  end

  function mem:fetch_and(word_index: integer, value: integer): integer | nil, string
    return atomic("fetch_and", raw.fetch_and, word_index, value)
  end

  function mem:fetch_or(word_index: integer, value: integer): integer | nil, string
    return atomic("fetch_or", raw.fetch_or, word_index, value)
  end

  function mem:fetch_xor(word_index: integer, value: integer): integer | nil, string
    return atomic("fetch_xor", raw.fetch_xor, word_index, value)
  end

  function mem:cmpxchg(word_index: integer, old: integer, new: integer): boolean | nil, integer, string
    local range_err = check_word(word_index, size, "cmpxchg")
    if range_err then
      return nil, nil, range_err
    end
    local ok, success, actual = pcall(raw.cmpxchg, raw, word_index, old, new)
    if not ok then
      return nil, nil, thrown("cmpxchg", success)
    end
    return success as boolean, actual as integer
  end

  function mem:wait(word_index: integer, expect: integer, abs_deadline?: integer, nanos?: integer): integer | nil, string
    local range_err = check_word(word_index, size, "wait")
    if range_err then
      return nil, range_err
    end
    -- The binding returns (nil, err, errno) for EAGAIN/ETIMEDOUT/EINTR
    -- and throws for a futex word with nonzero high bits; keep both as
    -- error returns.
    local ok, rc, err = pcall(raw.wait, raw, word_index, expect, abs_deadline, nanos)
    if not ok then
      return nil, thrown("wait", rc)
    end
    if rc == nil then
      return nil, errstr(err, "wait")
    end
    return rc as integer
  end

  function mem:wake(word_index: integer, count?: integer): integer
    local range_err = check_word(word_index, size, "wake")
    if range_err then
      -- wake never fails in the binding; an out-of-range index wakes
      -- nothing rather than growing an error slot for it.
      return 0
    end
    return raw:wake(word_index, count)
  end

  return mem
end

--- Creates a shared memory region.
--- The memory is shared across fork() and can be used for inter-process
--- communication with atomic operations and futex synchronization.
---
--- Example usage for a simple mutex:
--- ```lua
--- local shm = require("cosmic.shm")
--- local mem = assert(shm.mapshared(8000 * 8))
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
--- @param size integer Size in bytes: positive, a multiple of the 8-byte word size
--- @return Memory | nil Shared memory object, or nil on failure
--- @return string? Error message on failure
local function mapshared(size: integer): Memory | nil, string
  if size == nil or size <= 0 then
    return nil, "mapshared: size must be a positive number of bytes: " .. tostring(size)
  end
  if size % WORD ~= 0 then
    return nil, "mapshared: size must be a multiple of the " .. tostring(WORD)
    .. "-byte word size: " .. tostring(size)
  end
  -- Residual throws (e.g. out of memory, size cap) become nil, err.
  local ok, raw = pcall(unix.mapshared, size)
  if not ok then
    return nil, thrown("mapshared", raw)
  end
  return wrap(raw as unix.Memory, size)
end

local M: ShmModule = {
  mapshared = mapshared,
}

return M
