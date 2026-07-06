--- Random number generation.
--- Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
--- cosmo.Rand64 for fast non-cryptographic use cases.
---
--- Example usage:
---   local rand = require("cosmic.rand")
---   local key, err = rand.bytes(32)     -- cryptographically secure
---   local n = rand.rand64()             -- fast pseudo-random (not secure)
local cosmo = require("cosmo")

--- Generate cryptographically secure random bytes.
--- @param n number The number of random bytes to generate (1..4194304)
--- @return string | nil Random bytes, or nil on failure
--- @return string? Error message on failure
local function bytes(n: number): string | nil, string
  local data, err = cosmo.GetRandomBytes(n)
  if not data then
    return nil, err or "GetRandomBytes failed"
  end
  return data
end

--- Generate a fast 64-bit pseudo-random integer (non-cryptographic).
--- Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.
--- @return integer Random 64-bit integer
local function rand64(): number
  return cosmo.Rand64()
end

local record RandModule
  bytes: function(n: number): string | nil, string
  rand64: function(): number
end

local M: RandModule = {
  bytes = bytes,
  rand64 = rand64,
}

return M
