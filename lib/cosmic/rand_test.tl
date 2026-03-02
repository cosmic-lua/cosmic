#!/usr/bin/env cosmic
local rand = require("cosmic.rand")
local cosmo = require("cosmo")

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

-- Fast pseudo-random tests (non-cryptographic)
-- These skip gracefully if the cosmo bindings are not yet available.

local has_rand64 = cosmo.Rand64 ~= nil
local has_lemur64 = cosmo.Lemur64 ~= nil
local has_rdrand = cosmo.Rdrand ~= nil
local has_rdseed = cosmo.Rdseed ~= nil

local function test_rand64()
  if not has_rand64 then
    io.stderr:write("SKIP: rand64 (Rand64 primitive not available)\n")
    return
  end
  local n = rand.rand64()
  assert(math.type(n) == "integer", "rand64 should return integer, got " .. type(n))
  -- Two calls should almost certainly differ (false positive rate: 1/2^64)
  local n2 = rand.rand64()
  assert(n ~= n2, "rand64 should return different values each call")
end
test_rand64()

local function test_lemur64()
  if not has_lemur64 then
    io.stderr:write("SKIP: lemur64 (Lemur64 primitive not available)\n")
    return
  end
  local n = rand.lemur64()
  assert(math.type(n) == "integer", "lemur64 should return integer, got " .. type(n))
  local n2 = rand.lemur64()
  assert(n ~= n2, "lemur64 should return different values each call")
end
test_lemur64()

local function test_rdrand()
  if not has_rdrand then
    io.stderr:write("SKIP: rdrand (Rdrand primitive not available)\n")
    return
  end
  local n, err = rand.rdrand()
  if n == nil then
    -- Hardware unavailable on this CPU; error message should be present
    assert(type(err) == "string" and #err > 0, "rdrand should return error string when unavailable")
    io.stderr:write("SKIP: rdrand (hardware not available: " .. err .. ")\n")
    return
  end
  assert(math.type(n) == "integer", "rdrand should return integer, got " .. type(n))
end
test_rdrand()

local function test_rdseed()
  if not has_rdseed then
    io.stderr:write("SKIP: rdseed (Rdseed primitive not available)\n")
    return
  end
  local n, err = rand.rdseed()
  if n == nil then
    -- Hardware unavailable on this CPU; error message should be present
    assert(type(err) == "string" and #err > 0, "rdseed should return error string when unavailable")
    io.stderr:write("SKIP: rdseed (hardware not available: " .. err .. ")\n")
    return
  end
  assert(math.type(n) == "integer", "rdseed should return integer, got " .. type(n))
end
test_rdseed()
