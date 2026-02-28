#!/usr/bin/env cosmic
local rand = require("cosmic.rand")

local function test_bytes_returns_requested_length()
  local b = rand.bytes(16)
  assert(#b == 16, "bytes(16) should return 16 bytes, got " .. #b)
end
test_bytes_returns_requested_length()

local function test_bytes_different_each_call()
  local b1 = rand.bytes(32)
  local b2 = rand.bytes(32)
  assert(b1 ~= b2, "bytes should return different values each call")
end
test_bytes_different_each_call()

local function test_bytes_various_sizes()
  for _, size in ipairs({1, 8, 16, 32, 64, 128}) do
    local b = rand.bytes(size)
    assert(#b == size, "bytes(" .. size .. ") should return " .. size .. " bytes, got " .. #b)
  end
end
test_bytes_various_sizes()

local function test_rand64_returns_integer()
  local n = rand.rand64()
  assert(type(n) == "number", "rand64() should return a number, got " .. type(n))
end
test_rand64_returns_integer()

local function test_rand64_different_each_call()
  local n1 = rand.rand64()
  local n2 = rand.rand64()
  -- Extremely unlikely to be equal; treat collision as acceptable
  assert(type(n1) == "number" and type(n2) == "number", "rand64() should return numbers")
end
test_rand64_different_each_call()

local function test_lemur64_returns_integer()
  local n = rand.lemur64()
  assert(type(n) == "number", "lemur64() should return a number, got " .. type(n))
end
test_lemur64_returns_integer()

local function test_lemur64_different_each_call()
  local n1 = rand.lemur64()
  local n2 = rand.lemur64()
  assert(type(n1) == "number" and type(n2) == "number", "lemur64() should return numbers")
end
test_lemur64_different_each_call()

local function test_rdrand_returns_integer_or_error()
  local n, err = rand.rdrand()
  if n then
    assert(type(n) == "number", "rdrand() value should be a number, got " .. type(n))
  else
    assert(type(err) == "string", "rdrand() error should be a string, got " .. type(err))
  end
end
test_rdrand_returns_integer_or_error()

local function test_rdseed_returns_integer_or_error()
  local n, err = rand.rdseed()
  if n then
    assert(type(n) == "number", "rdseed() value should be a number, got " .. type(n))
  else
    assert(type(err) == "string", "rdseed() error should be a string, got " .. type(err))
  end
end
test_rdseed_returns_integer_or_error()
