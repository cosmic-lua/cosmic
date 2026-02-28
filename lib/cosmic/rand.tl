--- Random number generation.
--- Wraps cosmo functions for cryptographically secure and fast pseudo-random values.
---
--- Example usage:
---   local rand = require("cosmic.rand")
---   local key = rand.bytes(32)
---   local n = rand.rand64()
---   local n = rand.lemur64()
local cosmo = require("cosmo")

--- Generate cryptographically secure random bytes.
--- @param n number The number of random bytes to generate
--- @return string Random bytes
local function bytes(n: number): string
  return cosmo.GetRandomBytes(n)
end

--- Generate a fast 64-bit pseudo-random integer.
--- Not cryptographically secure. Always succeeds.
--- @return integer Random 64-bit integer
local function rand64(): integer
  return cosmo.Rand64()
end

--- Generate a fast 64-bit pseudo-random integer using Lemire's algorithm.
--- Not cryptographically secure. Always succeeds.
--- @return integer Random 64-bit integer
local function lemur64(): integer
  return cosmo.Lemur64()
end

--- Generate a hardware random number using Intel RDRAND.
--- Returns nil and an error string if RDRAND is unavailable on this CPU.
--- @return integer, string Random 64-bit integer, or nil and error message
local function rdrand(): integer, string
  if not (cosmo.Rdrand as function) then
    return nil, "rdrand: not available (cosmo.Rdrand not exposed)"
  end
  local ok, val, err = pcall(cosmo.Rdrand)
  if not ok then
    return nil, "rdrand: " .. tostring(val)
  end
  if err then
    return nil, err
  end
  return val
end

--- Generate a hardware random seed using Intel RDSEED.
--- Returns nil and an error string if RDSEED is unavailable on this CPU.
--- @return integer, string Random 64-bit seed, or nil and error message
local function rdseed(): integer, string
  if not (cosmo.Rdseed as function) then
    return nil, "rdseed: not available (cosmo.Rdseed not exposed)"
  end
  local ok, val, err = pcall(cosmo.Rdseed)
  if not ok then
    return nil, "rdseed: " .. tostring(val)
  end
  if err then
    return nil, err
  end
  return val
end

local record RandModule
  bytes: function(n: number): string
  rand64: function(): integer
  lemur64: function(): integer
  rdrand: function(): integer, string
  rdseed: function(): integer, string
end

local M: RandModule = {
  bytes = bytes,
  rand64 = rand64,
  lemur64 = lemur64,
  rdrand = rdrand,
  rdseed = rdseed,
}

return M
