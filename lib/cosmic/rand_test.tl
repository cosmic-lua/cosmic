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

-- Crypto-grade bounded integers (issue #531)

local function test_int_bounds()
  for _ = 1, 500 do
    local n = assert(rand.int(-3, 7))
    assert(n >= -3 and n <= 7, "int(-3, 7) out of bounds: " .. n)
    assert(math.type(n) == "integer", "int should return an integer")
  end
end
test_int_bounds()

local function test_int_degenerate_range()
  assert(rand.int(5, 5) == 5, "int(5, 5) must return 5")
end
test_int_degenerate_range()

local function test_int_distribution_smoke()
  -- Every value of a small range should appear in a modest sample
  -- (P(miss) < 4 * (3/4)^400, effectively zero).
  local seen: {integer: boolean} = {}
  for _ = 1, 400 do
    local n = assert(rand.int(0, 3))
    seen[n] = true
  end
  for v = 0, 3 do
    assert(seen[v], "int(0, 3) never produced " .. v .. " in 400 draws")
  end
end
test_int_distribution_smoke()

local function test_int_wide_range()
  -- Multi-byte sampling path: range needs more than one random byte.
  local lo, hi = 0, 100000
  for _ = 1, 100 do
    local n = assert(rand.int(lo, hi))
    assert(n >= lo and n <= hi, "int(0, 100000) out of bounds: " .. n)
  end
end
test_int_wide_range()

local function test_int_invalid_args()
  local n, err = rand.int(10, 1)
  assert(n == nil, "min > max should fail")
  assert(err and err:match("min"), "expected min/max error, got: " .. tostring(err))

  n, err = rand.int(1.5 as integer, 3)
  assert(n == nil, "non-integer min should fail")
  assert(err, "expected error for non-integer min")

  n, err = rand.int(math.mininteger, math.maxinteger)
  assert(n == nil, "full 64-bit span should be rejected")
  assert(err and err:match("range"), "expected range error, got: " .. tostring(err))
end
test_int_invalid_args()
