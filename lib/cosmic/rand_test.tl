#!/usr/bin/env cosmic
local rand = require("cosmic.rand")

local function test_bytes_returns_requested_length()
  local b, err = rand.bytes(16)
  assert(b, "bytes(16) failed: " .. tostring(err))
  assert(#b == 16, "bytes(16) should return 16 bytes, got " .. #b)
end
test_bytes_returns_requested_length()

local function test_bytes_different_each_call()
  local b1 = assert(rand.bytes(32))
  local b2 = assert(rand.bytes(32))
  assert(b1 ~= b2, "bytes should return different values each call")
end
test_bytes_different_each_call()

local function test_bytes_various_sizes()
  for _, size in ipairs({1, 8, 16, 32, 64, 128}) do
    local b, err = rand.bytes(size)
    assert(b, "bytes(" .. size .. ") failed: " .. tostring(err))
    assert(#b == size, "bytes(" .. size .. ") should return " .. size .. " bytes, got " .. #b)
  end
end
test_bytes_various_sizes()

-- Fast pseudo-random tests (non-cryptographic).

local function test_rand64()
  local n = rand.rand64()
  assert(math.type(n) == "integer", "rand64 should return integer, got " .. type(n))
  -- Two calls should almost certainly differ (false positive rate: 1/2^64)
  local n2 = rand.rand64()
  assert(n ~= n2, "rand64 should return different values each call")
end
test_rand64()
