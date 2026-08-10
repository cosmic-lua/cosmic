#!/usr/bin/env cosmic
local shm = require("cosmic.shm")
local check = require("cosmic.check")

-- Test module exports

local function test_module_exports()
  assert(shm.open ~= nil, "open function should be exported")
  assert(type(shm.open) == "function", "open should be a function")
end
test_module_exports()

-- Test basic shared memory creation

local function test_open_creates_memory()
  local mem = check.must(shm.open(4096))
  assert(mem ~= nil, "open should return a memory object")
end
test_open_creates_memory()

-- Test memory read/write operations
-- Note: write/read with no arguments uses null-terminated string semantics

local function test_memory_write_read()
  local mem = check.must(shm.open(4096))
  assert(mem:write("hello")) -- writes "hello\0"
  local data = mem:read() -- reads until null terminator
  assert(data == "hello", "expected 'hello', got '" .. tostring(data) .. "'")
end
test_memory_write_read()

local function test_memory_write_read_with_offset()
  local mem = check.must(shm.open(4096))
  assert(mem:write("hello")) -- writes at offset 0
  assert(mem:write("world")) -- overwrites
  local data = mem:read()
  assert(data == "world", "expected 'world', got '" .. tostring(data) .. "'")
end
test_memory_write_read_with_offset()

-- Test atomic word operations

local function test_memory_store_load()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 42))
  local value = mem:load(0)
  assert(value == 42, "expected 42, got " .. tostring(value))
end
test_memory_store_load()

local function test_memory_store_load_different_index()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 100))
  assert(mem:store(1, 200))
  local v0 = mem:load(0)
  local v1 = mem:load(1)
  assert(v0 == 100, "expected 100 at index 0, got " .. tostring(v0))
  assert(v1 == 200, "expected 200 at index 1, got " .. tostring(v1))
end
test_memory_store_load_different_index()

-- Test atomic exchange

local function test_memory_exchange()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 10))
  local old = mem:exchange(0, 20)
  assert(old == 10, "exchange should return old value 10, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 20, "after exchange, value should be 20, got " .. tostring(current))
end
test_memory_exchange()

-- Test compare-and-exchange

local function test_memory_compare_exchange_success()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 100))
  local r = check.must(mem:compare_exchange(0, 100, 200))
  assert(r.swapped == true, "compare_exchange should succeed when old matches")
  assert(r.value == 100, "compare_exchange should return old value 100, got " .. tostring(r.value))
  local current = mem:load(0)
  assert(current == 200, "after successful compare_exchange, value should be 200, got " .. tostring(current))
end
test_memory_compare_exchange_success()

local function test_memory_compare_exchange_failure()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 100))
  local r = check.must(mem:compare_exchange(0, 50, 200))
  assert(r.swapped == false, "compare_exchange should fail when old doesn't match")
  assert(r.value == 100, "compare_exchange should return actual value 100, got " .. tostring(r.value))
  local current = mem:load(0)
  assert(current == 100, "after failed compare_exchange, value should still be 100, got " .. tostring(current))
end
test_memory_compare_exchange_failure()

-- Test fetch_add

local function test_memory_fetch_add()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 10))
  local old = mem:fetch_add(0, 5)
  assert(old == 10, "fetch_add should return old value 10, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 15, "after fetch_add, value should be 15, got " .. tostring(current))
end
test_memory_fetch_add()

-- Test fetch_and

local function test_memory_fetch_and()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 0xFF))
  local old = mem:fetch_and(0, 0x0F)
  assert(old == 0xFF, "fetch_and should return old value 255, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 0x0F, "after fetch_and, value should be 15, got " .. tostring(current))
end
test_memory_fetch_and()

-- Test fetch_or

local function test_memory_fetch_or()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 0x0F))
  local old = mem:fetch_or(0, 0xF0)
  assert(old == 0x0F, "fetch_or should return old value 15, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 0xFF, "after fetch_or, value should be 255, got " .. tostring(current))
end
test_memory_fetch_or()

-- Test fetch_xor

local function test_memory_fetch_xor()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 0xFF))
  local old = mem:fetch_xor(0, 0x0F)
  assert(old == 0xFF, "fetch_xor should return old value 255, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 0xF0, "after fetch_xor, value should be 240, got " .. tostring(current))
end
test_memory_fetch_xor()

-- Test wake (basic call, no waiters)

local function test_memory_wake_no_waiters()
  local mem = check.must(shm.open(4096))
  assert(mem:store(0, 0))
  local woken = mem:wake(0, 1)
  -- With no waiters, wake should return 0
  assert(woken == 0, "wake with no waiters should return 0, got " .. tostring(woken))
end
test_memory_wake_no_waiters()

-- Real wrapper with error slots (review item 25): invalid
-- sizes and out-of-range accesses return nil, err instead of throwing.

local function test_open_size_not_multiple_of_word()
  local mem, err = shm.open(100)
  assert(mem == nil, "open(100) should fail (not a multiple of 8)")
  assert(type(err) == "string" and err:find("multiple"),
    "error should mention the word-size multiple, got: " .. tostring(err))
end
test_open_size_not_multiple_of_word()

local function test_open_rejects_nonpositive_size()
  local mem, err = shm.open(0)
  assert(mem == nil and type(err) == "string", "open(0) should fail with an error")
  local mem2, err2 = shm.open(-8)
  assert(mem2 == nil and type(err2) == "string", "open(-8) should fail with an error")
end
test_open_rejects_nonpositive_size()

local function test_memory_size()
  local mem = check.must(shm.open(4096))
  assert(mem:size() == 4096, "size() should return the mapped size, got " .. tostring(mem:size()))
end
test_memory_size()

local function test_memory_read_out_of_range()
  local mem = check.must(shm.open(64))
  local data, err = mem:read(9999, 8)
  assert(data == nil, "read past the region should fail")
  assert(type(err) == "string" and err:find("range"),
    "read error should mention range, got: " .. tostring(err))
end
test_memory_read_out_of_range()

local function test_memory_write_out_of_range()
  local mem = check.must(shm.open(8))
  local ok, err = mem:write("far too long for eight bytes", 0)
  assert(ok == false, "write past the region should fail")
  assert(type(err) == "string" and err:find("range"),
    "write error should mention range, got: " .. tostring(err))
end
test_memory_write_out_of_range()

-- write must honor an explicit offset: raw.write's real C argument
-- order is (offset, data, bytes), not (data, offset, bytes), so this
-- once silently discarded the offset (treating it as a bytes count).
local function test_memory_write_at_explicit_offset()
  local mem = check.must(shm.open(4096))
  local ok1, err1 = mem:write("XXXXXXXXXX", 0)
  assert(ok1, "setup write failed: " .. tostring(err1))
  local ok2, err2 = mem:write("world", 3)
  assert(ok2, "write at offset 3 failed: " .. tostring(err2))
  local data = check.must(mem:read(0, 8))
  assert(data == "XXXworld",
    "expected 'XXXworld' at bytes 0-7, got: " .. tostring(data):gsub("%z", "\\0"))
end
test_memory_write_at_explicit_offset()

-- write must clamp `bytes` to the actual data length before it reaches
-- the binding: passing the caller's raw (over-large) count instead of
-- the validated min(bytes, #data) either wrote nothing (offset 0
-- collides with "no count") or threw "bytes is more than what's in data".
local function test_memory_write_clamps_bytes_to_data_length()
  local mem = check.must(shm.open(4096))
  local ok, err = mem:write("hi", 0, 100)
  assert(ok == true, "write with bytes > #data should still succeed: " .. tostring(err))
  local data = check.must(mem:read(0, 2))
  assert(data == "hi", "expected 'hi', got: " .. tostring(data))
end
test_memory_write_clamps_bytes_to_data_length()

local function test_memory_word_index_out_of_range()
  local mem = check.must(shm.open(64))
  local v, err = mem:load(9999)
  assert(v == nil, "load of out-of-range word should fail")
  assert(type(err) == "string" and err:find("range"),
    "load error should mention range, got: " .. tostring(err))
  local ok, serr = mem:store(-1, 5)
  assert(ok == false, "store to negative word index should fail")
  assert(type(serr) == "string" and serr:find("range"),
    "store error should mention range, got: " .. tostring(serr))
end
test_memory_word_index_out_of_range()

local function test_memory_wait_wrong_expect_returns_eagain()
  local mem = check.must(shm.open(64))
  assert(mem:store(0, 5))
  local rc, err = mem:wait(0, 3)
  assert(rc == nil, "wait with mismatched expect should fail immediately")
  assert(type(err) == "string" and err:match("EAGAIN"),
    "wait error should name EAGAIN, got: " .. tostring(err))
end
test_memory_wait_wrong_expect_returns_eagain()

-- signal-safety wave: a futex wait interrupted by a signal is retried
-- automatically — the absolute deadline keeps the timeout exact across
-- retries, so the wait ends in ETIMEDOUT, never EINTR.
local function test_memory_wait_retries_eintr_until_deadline()
  local signal = require("cosmic.signal")
  local mem = check.must(shm.open(64))
  assert(mem:store(0, 0))
  local prev = check.must(signal.sigaction(signal.SIGALRM, function(_: number) end))
  -- Interval timer: interrupts the wait several times before the deadline.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 30,
        interval_ms = 30,
      }))
  local rc, err = mem:wait(0, 0, 200)
  -- Disarm and restore before asserting so a failure can't leave a
  -- ticking timer behind.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 0,
        interval_ms = 0,
      }))
  assert(signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask))
  assert(rc == nil, "wait on an unchanged word should time out")
  assert(type(err) == "string" and err:match("ETIMEDOUT"),
    "interrupted wait should retry to the deadline (ETIMEDOUT), got: "
    .. tostring(err))
end
test_memory_wait_retries_eintr_until_deadline()

-- close releases the mapping deterministically instead of waiting
-- for the garbage collector. Idempotent and returns NOTHING (#999:
-- it used to return false for "already released", so asserting the
-- second, correct call failed); afterwards every fallible method
-- returns an error instead of touching freed memory, and wake wakes
-- nothing.
local function test_memory_close()
  local mem = assert(shm.open(64))
  assert(mem:store(0, 7))
  mem:close()
  mem:close() -- the second, correct call is a quiet no-op, not a false
  local v, err = mem:load(0)
  assert(v == nil, "load after unmap should fail")
  assert(type(err) == "string" and err:find("unmapped"),
    "load error should say unmapped, got: " .. tostring(err))
  local ok, werr = mem:write("x")
  assert(ok == false and type(werr) == "string", "write after unmap should fail")
  local rc, werr2 = mem:wait(0, 0)
  assert(rc == nil and type(werr2) == "string", "wait after unmap should fail")
  local woken, wake_err = mem:wake(0)
  assert(woken == nil and wake_err and wake_err:find("unmapped", 1, true),
    "wake after unmap is a caller bug and must say so, got: " .. tostring(wake_err))
end
test_memory_close()
