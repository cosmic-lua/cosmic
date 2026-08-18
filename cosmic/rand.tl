--- Random bytes, integers, floats, choice, shuffle, and tokens.
--- Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
--- cosmo.Rand64 for fast non-cryptographic use cases.
---
--- Every function here is INFALLIBLE: on every supported platform
--- the kernel CSPRNG cannot fail once the system has booted, so there is
--- no runtime failure for a return slot to carry. Out-of-range arguments
--- are contract violations and throw — the one thing that must never
--- happen is code limping on without entropy. Callers check nothing.
---
--- A second, deliberately-insecure surface lives alongside the CSPRNG one:
--- rand.insecure_source(seed) returns a seedable, reproducible Source for
--- callers that need randomness to replay rather than to be unguessable.
---
--- Example usage:
---   local rand = require("cosmic.rand")
---   local key = rand.bytes(32)          -- cryptographically secure
---   local roll = rand.int(1, 6)         -- crypto-grade, unbiased
---   local n = rand.insecure64()         -- fast pseudo-random (not secure)
---   local src = rand.insecure_source(42) -- seedable, reproducible (NOT secure)
local cosmo = require("cosmo")

--- Generate cryptographically secure random bytes.
--- @param n integer The number of random bytes to generate (1..4194304)
--- @return string n random bytes
local function bytes(n: integer): string
  local data, err = cosmo.GetRandomBytes(n)
  if not data then
    -- A failing CSPRNG is unrecoverable and an error return invites
    -- proceeding insecurely; the binding only fails on an out-of-range
    -- n (a contract violation) or a genuinely broken host.
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

--- A seedable, non-cryptographic pseudo-random source. NOT part of the
--- CSPRNG surface: draws are cheap and reproducible, never secure, and
--- must never be used for anything security-sensitive (use rand.bytes,
--- rand.int, or rand.token for that).
---
--- Each Source owns private state and never reads or reseeds Lua's
--- global math.random()/math.randomseed() — drawing from one Source
--- cannot perturb another Source, math.random() elsewhere in the
--- process, or (once a future slice wires it in) `_fuzz`'s own replay
--- stream. This is the property that makes it usable inside code a
--- fuzz property exercises without desyncing replay.
local record Source
  --- Draw a pseudo-random integer in [min, max] (inclusive). A simple
  --- modulo reduction, not rejection-sampled like rand.int — adequate
  --- for jitter/backoff and fuzz-input generation, not a uniformity
  --- guarantee. Throws on min > max (contract violation, same
  --- convention rand.int already uses).
  --- @param min integer Lower bound (inclusive)
  --- @param max integer Upper bound (inclusive)
  --- @return integer The random integer
  int: function(Source, integer, integer): integer
  --- Draw a pseudo-random float in [0, 1).
  --- @return number The random float
  float: function(Source): number
end

--- Create a new seedable, non-cryptographic pseudo-random source.
--- The same seed reproduces the same sequence of draws WITHIN ONE
--- PROCESS. This is NOT a stability guarantee: the algorithm may
--- change in a future cosmic release, so a recorded seed is only
--- meaningful for replay within roughly the same build/session
--- (matching _fuzz/driver.tl's own replay promise) — never treat it
--- as a byte-stable format to pin across releases.
--- @param seed integer The seed
--- @return Source A new pseudo-random source
local function insecure_source(seed: integer): Source
  local state: integer = seed

  -- splitmix64 (Vigna/Steele, public domain): one 64-bit multiply-mix
  -- per draw, one word of state, no shared/global state — deliberately
  -- NOT math.random()/math.randomseed(), which are a single process-wide
  -- stream. Wrapping that shared stream cannot give independent Sources
  -- without either corrupting whatever else reads it (defeating the
  -- whole point) or reseeding on every draw (which does the same
  -- corruption in the other direction). splitmix64 needs no such
  -- trade: it is a handful of arithmetic ops, not a from-scratch
  -- xoshiro/PCG-scale generator.
  local function draw(): integer
    state = state + 0x9E3779B97F4A7C15
    local z = state
    z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ~ (z >> 27)) * 0x94D049BB133111EB
    z = z ~ (z >> 31)
    return z & 0x7FFFFFFFFFFFFFFF -- 63 non-negative bits
  end

  local source: Source = {}

  source.int = function(_self: Source, min: integer, max: integer): integer
    if min > max then
      error("rand.insecure_source: min must be <= max", 2)
    end
    return min + draw() % (max - min + 1)
  end

  source.float = function(_self: Source): number
    return draw() / 9223372036854775808.0 -- 2^63; draw() in [0, 2^63)
  end

  return source
end

local record RandModule
  bytes: function(n: integer): string
  int: function(min: integer, max: integer): integer
  float: function(): number
  choice: function(list: {any}): any
  shuffle: function(list: {any}): {any}
  token: function(len?: integer): string
  insecure64: function(): integer
  type Source = Source
  insecure_source: function(seed: integer): Source
end

local M: RandModule = {
  bytes = bytes,
  int = int,
  float = float,
  choice = choice,
  shuffle = shuffle,
  token = token,
  insecure64 = insecure64,
  insecure_source = insecure_source,
}

return M
