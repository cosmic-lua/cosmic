--- Random number generation.
--- Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
--- cosmo.Rand64 for fast non-cryptographic use cases.
---
--- Example usage:
---   local rand = require("cosmic.rand")
---   local key, err = rand.bytes(32)     -- cryptographically secure
---   local roll = rand.int(1, 6)         -- crypto-grade, unbiased
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

--- Generate a cryptographically secure uniform integer in [min, max]
--- (both inclusive). Rejection-sampled over bytes(), so the result is
--- unbiased — unlike the common `min + rand % range` shortcut.
--- The range size (max - min + 1) must not exceed 2^53.
--- @param min integer Lower bound (inclusive)
--- @param max integer Upper bound (inclusive)
--- @return integer | nil The random integer, or nil on failure
--- @return string? Error message on failure
local function int(min: integer, max: integer): integer | nil, string
  if math.type(min) ~= "integer" or math.type(max) ~= "integer" then
    return nil, "rand.int: min and max must be integers"
  end
  if min > max then
    return nil, "rand.int: min must be <= max"
  end
  local range = max - min + 1
  -- range <= 0 means max - min overflowed the signed 64-bit space.
  if range <= 0 or range > (1 << 53) then
    return nil, "rand.int: range too large (max 2^53)"
  end
  -- Smallest byte count whose value space covers the range.
  local nbytes = 1
  local space = 256
  while space < range do
    nbytes = nbytes + 1
    space = space * 256
  end
  -- Rejection sampling: draw values until one lands under the largest
  -- multiple of range, so every residue is equally likely. Each draw
  -- accepts with probability > 1/2, so the expected iteration count is < 2.
  local limit = space - (space % range)
  while true do
    local data, err = bytes(nbytes)
    if not data then
      return nil, err
    end
    local v = 0
    for i = 1, nbytes do
      v = v * 256 + string.byte(data as string, i)
    end
    if v < limit then
      return min + v % range
    end
  end
end

local record RandModule
  bytes: function(n: number): string | nil, string
  int: function(min: integer, max: integer): integer | nil, string
  rand64: function(): number
end

local M: RandModule = {
  bytes = bytes,
  int = int,
  rand64 = rand64,
}

return M
