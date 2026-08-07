--- Random number generation.
--- Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
--- cosmo.Rand64 for fast non-cryptographic use cases.
---
--- Every function here is INFALLIBLE (D22): on every supported platform
--- the kernel CSPRNG cannot fail once the system has booted, so there is
--- no runtime failure for a return slot to carry. Out-of-range arguments
--- are contract violations and throw — the one thing that must never
--- happen is code limping on without entropy. Callers check nothing.
---
--- Example usage:
---   local rand = require("cosmic.rand")
---   local key = rand.bytes(32)          -- cryptographically secure
---   local roll = rand.int(1, 6)         -- crypto-grade, unbiased
---   local n = rand.insecure64()         -- fast pseudo-random (not secure)
local cosmo = require("cosmo")

--- Generate cryptographically secure random bytes.
--- @param n integer The number of random bytes to generate (1..4194304)
--- @return string n random bytes
local function bytes(n: integer): string
  local data, err = cosmo.GetRandomBytes(n)
  if not data then
    -- A failing CSPRNG is unrecoverable and an error return invites
    -- proceeding insecurely; the binding only fails on an out-of-range
    -- n (a contract violation) or a genuinely broken host (D22).
    error("rand.bytes: " .. (err or "GetRandomBytes failed"), 2)
  end
  return data
end

--- Generate a fast 64-bit pseudo-random integer (non-cryptographic).
--- Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.
--- @return integer Random 64-bit integer
local function insecure64(): integer
  return cosmo.Rand64()
end

--- Generate a cryptographically secure uniform integer in [min, max]
--- (both inclusive). Rejection-sampled over bytes(), so the result is
--- unbiased — unlike the common `min + rand % range` shortcut.
--- The range size (max - min + 1) must not exceed 2^53.
--- @param min integer Lower bound (inclusive)
--- @param max integer Upper bound (inclusive)
--- @return integer The random integer
local function int(min: integer, max: integer): integer
  if math.type(min) ~= "integer" or math.type(max) ~= "integer" then
    error("rand.int: min and max must be integers", 2)
  end
  if min > max then
    error("rand.int: min must be <= max", 2)
  end
  local range = max - min + 1
  -- range <= 0 means max - min overflowed the signed 64-bit space.
  if range <= 0 or range > (1 << 53) then
    error("rand.int: range too large (max 2^53)", 2)
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
    local data = bytes(nbytes)
    local v = 0
    for i = 1, nbytes do
      v = v * 256 + string.byte(data, i)
    end
    if v < limit then
      return min + v % range
    end
  end
end

--- Generate a cryptographically secure uniform float in [0, 1).
--- Uses 53 random bits, so the result has full double precision.
--- @return number The random float
local function float(): number
  return int(0, (1 << 53) - 1) / (1 << 53)
end

--- Pick one element of a list uniformly at random (crypto-grade).
--- @param list {any} The list to pick from
--- @return any The chosen element; nil only when the list is empty
local function choice(list: {any}): any
  if #list == 0 then
    return nil
  end
  return list[int(1, #list)]
end

--- Shuffle a list in place with an unbiased Fisher-Yates pass
--- (crypto-grade). Returns the same list for call chaining.
--- @param list {any} The list to shuffle (mutated in place)
--- @return {any} The shuffled list
local function shuffle(list: {any}): {any}
  for i = #list, 2, -1 do
    local j = int(1, i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

local TOKEN_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

--- Generate a random alphanumeric token (crypto-grade, unbiased).
--- Tokens are URL- and filename-safe. Each character carries ~5.95 bits
--- of entropy, so the default 32 characters give ~190 bits.
--- @param len integer? Token length in characters (default 32, must be positive)
--- @return string The token
local function token(len?: integer): string
  len = len or 32
  if len < 1 then
    error("rand.token: len must be positive", 2)
  end
  local chars: {string} = {}
  for i = 1, len do
    local j = int(1, #TOKEN_ALPHABET)
    chars[i] = TOKEN_ALPHABET:sub(j, j)
  end
  return table.concat(chars)
end

local record RandModule
  bytes: function(n: integer): string
  int: function(min: integer, max: integer): integer
  float: function(): number
  choice: function(list: {any}): any
  shuffle: function(list: {any}): {any}
  token: function(len?: integer): string
  insecure64: function(): integer
end

local M: RandModule = {
  bytes = bytes,
  int = int,
  float = float,
  choice = choice,
  shuffle = shuffle,
  token = token,
  insecure64 = insecure64,
}

return M
