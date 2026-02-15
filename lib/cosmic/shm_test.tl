#!/usr/bin/env cosmic
local shm = require("cosmic.shm")

-- Test module exports

local function test_module_exports()
  assert(shm.mapshared ~= nil, "mapshared function should be exported")
  assert(type(shm.mapshared) == "function", "mapshared should be a function")
end
test_module_exports()

-- Test basic shared memory creation

local function test_mapshared_creates_memory()
  local mem = shm.mapshared(4096)
  assert(mem ~= nil, "mapshared should return a memory object")
end
test_mapshared_creates_memory()

-- Test memory read/write operations
-- Note: write/read with no arguments uses null-terminated string semantics

local function test_memory_write_read()
  local mem = shm.mapshared(4096)
  mem:write("hello") -- writes "hello\0"
  local data = mem:read() -- reads until null terminator
  assert(data == "hello", "expected 'hello', got '" .. tostring(data) .. "'")
end
test_memory_write_read()

local function test_memory_write_read_with_offset()
  local mem = shm.mapshared(4096)
  mem:write("hello") -- writes at offset 0
  mem:write("world") -- overwrites
  local data = mem:read()
  assert(data == "world", "expected 'world', got '" .. tostring(data) .. "'")
end
test_memory_write_read_with_offset()

-- Test atomic word operations

local function test_memory_store_load()
  local mem = shm.mapshared(4096)
  mem:store(0, 42)
  local value = mem:load(0)
  assert(value == 42, "expected 42, got " .. tostring(value))
end
test_memory_store_load()

local function test_memory_store_load_different_index()
  local mem = shm.mapshared(4096)
  mem:store(0, 100)
  mem:store(1, 200)
  local v0 = mem:load(0)
  local v1 = mem:load(1)
  assert(v0 == 100, "expected 100 at index 0, got " .. tostring(v0))
  assert(v1 == 200, "expected 200 at index 1, got " .. tostring(v1))
end
test_memory_store_load_different_index()

-- Test atomic exchange

local function test_memory_xchg()
  local mem = shm.mapshared(4096)
  mem:store(0, 10)
  local old = mem:xchg(0, 20)
  assert(old == 10, "xchg should return old value 10, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 20, "after xchg, value should be 20, got " .. tostring(current))
end
test_memory_xchg()

-- Test compare-and-exchange

local function test_memory_cmpxchg_success()
  local mem = shm.mapshared(4096)
  mem:store(0, 100)
  local ok, actual = mem:cmpxchg(0, 100, 200)
  assert(ok == true, "cmpxchg should succeed when old matches")
  assert(actual == 100, "cmpxchg should return old value 100, got " .. tostring(actual))
  local current = mem:load(0)
  assert(current == 200, "after successful cmpxchg, value should be 200, got " .. tostring(current))
end
test_memory_cmpxchg_success()

local function test_memory_cmpxchg_failure()
  local mem = shm.mapshared(4096)
  mem:store(0, 100)
  local ok, actual = mem:cmpxchg(0, 50, 200)
  assert(ok == false, "cmpxchg should fail when old doesn't match")
  assert(actual == 100, "cmpxchg should return actual value 100, got " .. tostring(actual))
  local current = mem:load(0)
  assert(current == 100, "after failed cmpxchg, value should still be 100, got " .. tostring(current))
end
test_memory_cmpxchg_failure()

-- Test fetch_add

local function test_memory_fetch_add()
  local mem = shm.mapshared(4096)
  mem:store(0, 10)
  local old = mem:fetch_add(0, 5)
  assert(old == 10, "fetch_add should return old value 10, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 15, "after fetch_add, value should be 15, got " .. tostring(current))
end
test_memory_fetch_add()

-- Test fetch_and

local function test_memory_fetch_and()
  local mem = shm.mapshared(4096)
  mem:store(0, 0xFF)
  local old = mem:fetch_and(0, 0x0F)
  assert(old == 0xFF, "fetch_and should return old value 255, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 0x0F, "after fetch_and, value should be 15, got " .. tostring(current))
end
test_memory_fetch_and()

-- Test fetch_or

local function test_memory_fetch_or()
  local mem = shm.mapshared(4096)
  mem:store(0, 0x0F)
  local old = mem:fetch_or(0, 0xF0)
  assert(old == 0x0F, "fetch_or should return old value 15, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 0xFF, "after fetch_or, value should be 255, got " .. tostring(current))
end
test_memory_fetch_or()

-- Test fetch_xor

local function test_memory_fetch_xor()
  local mem = shm.mapshared(4096)
  mem:store(0, 0xFF)
  local old = mem:fetch_xor(0, 0x0F)
  assert(old == 0xFF, "fetch_xor should return old value 255, got " .. tostring(old))
  local current = mem:load(0)
  assert(current == 0xF0, "after fetch_xor, value should be 240, got " .. tostring(current))
end
test_memory_fetch_xor()

-- Test wake (basic call, no waiters)

local function test_memory_wake_no_waiters()
  local mem = shm.mapshared(4096)
  mem:store(0, 0)
  local woken = mem:wake(0, 1)
  -- With no waiters, wake should return 0
  assert(woken == 0, "wake with no waiters should return 0, got " .. tostring(woken))
end
test_memory_wake_no_waiters()
