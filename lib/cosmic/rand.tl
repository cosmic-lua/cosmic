--- Random number generation.
--- Wraps cosmo.GetRandomBytes for cryptographically secure randomness.
---
--- Example usage:
---   local rand = require("cosmic.rand")
---   local key = rand.bytes(32)
local cosmo = require("cosmo")

--- Generate cryptographically secure random bytes.
--- @param n number The number of random bytes to generate
--- @return string Random bytes
local function bytes(n: number): string
  return cosmo.GetRandomBytes(n)
end

local record RandModule
  bytes: function(n: number): string
end

local M: RandModule = {
  bytes = bytes,
}

return M
