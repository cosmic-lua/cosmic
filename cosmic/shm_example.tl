--- Examples for the cosmic.shm module.
--- Demonstrates shared-memory string I/O and the atomic word
--- operations. Memory from mapshared() is inherited across fork(),
--- which is what makes the atomics useful; the examples stay in one
--- process so their output is deterministic.

-- Example_string_io demonstrates byte-level access: write() with no
-- count appends a NUL, and read() with no count reads back up to it
-- (string semantics).
local function Example_string_io()
  local check = require("cosmic.check")
  local shm = require("cosmic.shm")
  local mem = check.must(shm.mapshared(4096))
  assert(mem:write("hello"))
  print(check.must(mem:read()))
  print(mem:size())
  -- Output:
  -- hello
  -- 4096
end

-- Example_atomic_counter demonstrates the atomic word operations.
-- Words are 64-bit and word_index is 0-based; fetch_add returns the
-- value from before the addition.
local function Example_atomic_counter()
  local check = require("cosmic.check")
  local shm = require("cosmic.shm")
  local mem = check.must(shm.mapshared(4096))
  assert(mem:store(0, 41))
  local before = mem:fetch_add(0, 1)
  print(before, check.must(mem:load(0)))
  -- Output:
  -- 41	42
end

-- Example_cmpxchg demonstrates compare-and-exchange: the swap only
-- happens when the word still holds the expected old value, and the
-- actual old value comes back either way.
local function Example_cmpxchg()
  local check = require("cosmic.check")
  local shm = require("cosmic.shm")
  local mem = check.must(shm.mapshared(4096))
  assert(mem:store(0, 7))
  local ok, seen = mem:cmpxchg(0, 7, 8)
  print(ok, seen, check.must(mem:load(0)))
  local ok2, seen2 = mem:cmpxchg(0, 7, 9) -- stale expectation: no swap
  print(ok2, seen2, check.must(mem:load(0)))
  -- Output:
  -- true	7	8
  -- false	8	8
end

-- Suppress unused warnings for examples
local _ = {Example_string_io, Example_atomic_counter, Example_cmpxchg}
