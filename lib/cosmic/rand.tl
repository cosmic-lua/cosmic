--- Random number generation.
--- Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
--- cosmo.Rand64/Lemur64/Rdrand/Rdseed for fast non-cryptographic use cases.
---
--- Example usage:
---   local rand = require("cosmic.rand")
---   local key = rand.bytes(32)          -- cryptographically secure
---   local n = rand.rand64()             -- fast pseudo-random (not secure)
---   local n, err = rand.rdrand()        -- hardware random (may be unavailable)
local cosmo = require("cosmo")

--- Generate cryptographically secure random bytes.
--- @param n number The number of random bytes to generate
--- @return string Random bytes
local function bytes(n: number): string
  return cosmo.GetRandomBytes(n)
end

--- Generate a fast 64-bit pseudo-random integer (non-cryptographic).
--- Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.
--- @return integer Random 64-bit integer
local function rand64(): integer
  return cosmo.Rand64()
end

--- Generate a fast 64-bit pseudo-random integer using Lemire's PRNG (non-cryptographic).
--- Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.
--- @return integer Random 64-bit integer
local function lemur64(): integer
  return cosmo.Lemur64()
end

--- Generate a hardware random integer using Intel RDRAND instruction.
--- Returns nil and an error message on CPUs that do not support RDRAND.
--- @return integer, string Random integer, or nil and error message if unavailable
local function rdrand(): integer, string
  return cosmo.Rdrand()
end

--- Generate a hardware random seed using Intel RDSEED instruction.
--- Returns nil and an error message on CPUs that do not support RDSEED.
--- @return integer, string Random seed integer, or nil and error message if unavailable
local function rdseed(): integer, string
  return cosmo.Rdseed()
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
