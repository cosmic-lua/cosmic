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

-- Fast pseudo-random tests (non-cryptographic).

local function test_rand64()
  local n = rand.rand64()
  assert(math.type(n) == "integer", "rand64 should return integer, got " .. type(n))
  -- Two calls should almost certainly differ (false positive rate: 1/2^64)
  local n2 = rand.rand64()
  assert(n ~= n2, "rand64 should return different values each call")
end
test_rand64()

local function test_lemur64()
  local n = rand.lemur64()
  assert(math.type(n) == "integer", "lemur64 should return integer, got " .. type(n))
  local n2 = rand.lemur64()
  assert(n ~= n2, "lemur64 should return different values each call")
end
test_lemur64()

-- Hardware RNG tests: skip gracefully when the CPU lacks RDRAND/RDSEED.

local function test_rdrand()
  if not rand.has_hwrng() then
    io.stderr:write("SKIP: rdrand (hardware RNG not available)\n")
    return
  end
  local n, err = rand.rdrand()
  assert(n ~= nil, "rdrand should return a value when hardware RNG is available: " .. tostring(err))
  assert(math.type(n) == "integer", "rdrand should return integer, got " .. type(n))
end
test_rdrand()

local function test_rdseed()
  if not rand.has_hwrng() then
    io.stderr:write("SKIP: rdseed (hardware RNG not available)\n")
    return
  end
  local n, err = rand.rdseed()
  if n == nil then
    -- RDSEED can transiently fail even when present; require an error message.
    assert(type(err) == "string" and #err > 0, "rdseed should return error string on transient failure")
    io.stderr:write("SKIP: rdseed (transient hardware failure: " .. err .. ")\n")
    return
  end
  assert(math.type(n) == "integer", "rdseed should return integer, got " .. type(n))
end
test_rdseed()
