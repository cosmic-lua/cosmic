--- Shared memory for inter-process communication.
--- Provides atomic operations and wait/wake primitives for
--- synchronization. Memory created with shm.open (#999: was
--- `mapshared`) is shared across fork() and provides fundamental
--- synchronization primitives including futexes.
---
--- This is a real wrapper over unix.mapshared, not a passthrough: sizes
--- and offsets are validated in Lua (the region size is known at
--- open time) so failures return nil, err per the stdlib error
--- convention instead of throwing, and residual binding throws are
--- pcall-translated.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").format
local errno_is = require("cosmic.errno").is_code

local WORD = 8

--- Module type for shared memory operations.
local record ShmModule
  --- Shared memory region with atomic word operations and futexes.
  --- One compare-exchange outcome: whether the swap happened, and the
  --- word's actual value at the time (the old value on success). A
  --- record per D20 rule 11 (the error stays reachable in slot 2).
  record Exchange
    swapped: boolean
    value: integer
  end

  --- Words are 64-bit; word_index is 0-based. Futex words (wait/wake)
  --- only inspect the low 32 bits — store only int32 values in words
  --- you wait on.
  ---
  --- Memory ordering (#999, stated because a sync-primitives surface
  --- without one is a guess): every atomic word operation is
  --- sequentially consistent (the binding's C11 atomics use the
  --- default memory_order_seq_cst), so a store or exchange published
  --- before a wake is visible to the waiter it wakes; plain read/write
  --- byte access carries NO ordering — publish through the atomics.
  ---
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
    exchange: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Compare-and-exchange; returns success plus the actual old value.
    compare_exchange: function(self: Memory, word_index: integer, old: integer, new: integer): Exchange | nil, string
    --- Atomic add; returns the old value.
    fetch_add: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Atomic AND; returns the old value.
    fetch_and: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Atomic OR; returns the old value.
    fetch_or: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Atomic XOR; returns the old value.
    fetch_xor: function(self: Memory, word_index: integer, value: integer): integer | nil, string
    --- Wait until the word no longer holds `expect`. Returns 0 when
    --- woken; nil plus an error naming EAGAIN (value already differed)
    --- or ETIMEDOUT (timeout expired). `timeout_ms` is a RELATIVE
    --- timeout in integer milliseconds; omit it to wait forever. A wait interrupted
    --- by a signal is retried automatically — the deadline is computed
    --- once, up front, so retries keep the timeout exact.
    wait: function(self: Memory, word_index: integer, expect: integer, timeout_ms?: integer): integer | nil, string
    --- Wake processes waiting on a word; returns how many woke.
    --- Wakes nothing once the region has been unmapped.
    wake: function(self: Memory, word_index: integer, count?: integer): integer | nil, string
    --- Release the mapping now instead of waiting for the garbage
    --- collector. Idempotent and returns nothing (#999: it used to
    --- return false for "already released", so asserting the second,
    --- correct call failed). Afterwards every fallible method returns
    --- an error naming the unmapped state.
    close: function(self: Memory)
    --- The mapped region size in bytes.
    size: function(self: Memory): integer
  end
  open: function(size_bytes: integer): Memory | nil, string
end

local type Memory = ShmModule.Memory
local type Exchange = ShmModule.Exchange

--- Validate a 0-based word index against the region size.
local function check_word(word_index: integer, size: integer, op: string): string
  if word_index == nil or word_index < 0 or word_index >= size // WORD then
    return op .. ": word_index out of range (0-" .. tostring(size // WORD - 1)
    .. "): " .. tostring(word_index)
  end
  return nil
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
      return nil, errstr(res, "read")
    end
    return res
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
    -- Pass the CLAMPED count, not the caller's raw `bytes` -- otherwise
    -- an over-large `bytes` sails past the check above straight into
    -- the binding. nil still means "no count" (append NUL), per raw.write.
    local write_count: integer = nil
    if bytes ~= nil then
      write_count = n
    end
    -- raw.write's real argument order is (self, offset, data[, bytes]),
    -- NOT (self, data, offset[, bytes]) as its declared Teal type implies
    -- (a mismatch in the upstream binding's own annotation): it decides
    -- offset-vs-data by whether arg 2 is a number, so calling it with
    -- `data` first makes it silently treat our `offset` as `bytes`
    -- instead (an offset of 0 masked this: `mem:write(x, 0)` always
    -- wrote 0 bytes). Passing the definite numeric `off` first is
    -- unambiguous.
    -- cast: real C arg order disagrees with raw.write's declared type
    local raw_write = raw.write as function(unix.Memory, integer, string, integer | nil): nil
    -- cast: pcall variadic returns to tuple
    local ok, err = pcall(raw_write, raw, off, data, write_count) as (boolean, any)
    if not ok then
      return false, errstr(err, "write")
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
      return nil, errstr(res, "load")
    end
    return res
  end

  function mem:store(word_index: integer, value: integer): boolean, string
    local range_err = check_word(word_index, size, "store")
    if range_err then
      return false, range_err
    end
    -- cast: pcall variadic returns to tuple
    local ok, err = pcall(raw.store, raw, word_index, value) as (boolean, any)
    if not ok then
      return false, errstr(err, "store")
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
      return nil, errstr(res, op)
    end
    return res
  end

  function mem:exchange(word_index: integer, value: integer): integer | nil, string
    return atomic("exchange", raw.xchg, word_index, value)
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

  function mem:compare_exchange(word_index: integer, old: integer, new: integer): Exchange | nil, string
    local range_err = check_word(word_index, size, "compare_exchange")
    if range_err then
      return nil, range_err
    end
    local ok, success, actual = pcall(raw.cmpxchg, raw, word_index, old, new)
    if not ok then
      return nil, errstr(success, "compare_exchange")
    end
    -- cast: from any (pcall widens the binding's returns)
    return {swapped = success as boolean, value = actual as integer}
  end

  function mem:wait(word_index: integer, expect: integer, timeout_ms?: integer): integer | nil, string
    local range_err = check_word(word_index, size, "wait")
    if range_err then
      return nil, range_err
    end
    -- The binding takes an absolute CLOCK_REALTIME deadline; compute it
    -- once from the relative timeout so EINTR retries stay exact.
    local abs_deadline: integer = nil
    local nanos: integer = nil
    if timeout_ms then
      local now_s, now_ns = unix.clock_gettime(unix.CLOCK_REALTIME)
      abs_deadline = now_s + math.floor(timeout_ms / 1000)
      nanos = now_ns + math.floor(timeout_ms % 1000) * 1000000
      if nanos >= 1000000000 then
        abs_deadline = abs_deadline + 1
        nanos = nanos - 1000000000
      end
    end
    -- The binding returns (nil, err, errno) for EAGAIN/ETIMEDOUT and
    -- throws for a futex word with nonzero high bits; keep both as
    -- error returns. A wait interrupted by a signal is retried (the
    -- signal-safety wave): the deadline is absolute, so retrying
    -- keeps the timeout exact, and a word that changed meanwhile
    -- surfaces honestly as EAGAIN on the retry.
    local ok, rc, err, weno = pcall(raw.wait, raw, word_index, expect, abs_deadline, nanos)
    while ok and rc == nil and errno_is(weno, "EINTR") do
      ok, rc, err, weno = pcall(raw.wait, raw, word_index, expect, abs_deadline, nanos)
    end
    if not ok then
      return nil, errstr(rc, "wait")
    end
    if rc == nil then
      return nil, errstr(err, "wait")
    end
    return rc
  end

  local unmapped = false

  function mem:wake(word_index: integer, count?: integer): integer | nil, string
    local range_err = check_word(word_index, size, "wake")
    if range_err then
      -- An out-of-range index is a caller bug; waking nothing and
      -- reporting 0 hid it as "no waiters".
      return nil, range_err
    end
    if unmapped then
      return nil, "wake: memory is unmapped"
    end
    return raw:wake(word_index, count)
  end

  function mem:close()
    unmapped = true
    raw:unmap()
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
--- local mem = assert(shm.open(8000 * 8))
--- local LOCK = 0  -- word index for lock
---
--- -- Lock acquisition
--- while mem:exchange(LOCK, 1) == 1 do
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
--- @param size_bytes integer Size in bytes: positive, a multiple of the 8-byte word size
--- @return Memory | nil Shared memory object, or nil on failure
--- @return string? Error message on failure
local function open(size_bytes: integer): Memory | nil, string
  if size_bytes == nil or size_bytes <= 0 then
    return nil, "open: size must be a positive number of bytes: " .. tostring(size_bytes)
  end
  if size_bytes % WORD ~= 0 then
    return nil, "open: size must be a multiple of the " .. tostring(WORD)
    .. "-byte word size: " .. tostring(size_bytes)
  end
  -- Residual throws (e.g. out of memory, size cap) become nil, err.
  local ok, raw = pcall(unix.mapshared, size_bytes)
  if not ok then
    return nil, errstr(raw, "open")
  end
  return wrap(raw, size_bytes)
end

local M: ShmModule = {
  open = open,
}

return M
