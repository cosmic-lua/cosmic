--- Seeded pseudorandom numbers. A source made from a seed draws the same
--- sequence on every run and every target, so a run that depends on
--- chance can be replayed by naming its seed. The generator is
--- xoshiro256**, its state filled from the seed by splitmix64. It is not
--- cryptographic: never derive a key, token or nonce from it; draw those
--- from `Rand.entropy`.

local sys = require("cosmic.sys")

local record Rand
  --- A generator and its state. Each source draws its own sequence;
  --- two made from the same seed draw the same one.
  record Source
    --- An integer drawn uniformly from `min` through `max`, both
    --- included. Raises when `min` is greater than `max`.
    int: function(self: Source, min: integer, max: integer): integer

    --- A float drawn uniformly from [0, 1), a multiple of 2^-53.
    float: function(self: Source): number

    --- `count` bytes drawn uniformly. Raises when `count` is negative.
    bytes: function(self: Source, count: integer): string
  end
end

local record State
  s0: integer
  s1: integer
  s2: integer
  s3: integer
end

local function rotl(x: integer, k: integer): integer
  return (x << k) | (x >> (64 - k))
end

--- The next 64 bits of xoshiro256**, as a Lua integer (any bit pattern).
local function next64(st: State): integer
  local result = rotl(st.s1 * 5, 7) * 9
  local t = st.s1 << 17
  st.s2 = st.s2 ~ st.s0
  st.s3 = st.s3 ~ st.s1
  st.s1 = st.s1 ~ st.s2
  st.s0 = st.s0 ~ st.s3
  st.s2 = st.s2 ~ t
  st.s3 = rotl(st.s3, 45)
  return result
end

--- One splitmix64 step from `x`: the next state and its output.
local function splitmix(x: integer): integer, integer
  x = x + 0x9e3779b97f4a7c15
  local z = x
  z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
  z = (z ~ (z >> 27)) * 0x94d049bb133111eb
  return x, z ~ (z >> 31)
end

--- The smallest all-ones mask covering `n`, read as unsigned.
local function mask_for(n: integer): integer
  local m = n
  m = m | (m >> 1)
  m = m | (m >> 2)
  m = m | (m >> 4)
  m = m | (m >> 8)
  m = m | (m >> 16)
  m = m | (m >> 32)
  return m
end

--- A source drawing the sequence `seed` names. Every integer is a
--- distinct seed, zero and negative ones included.
--- @param seed integer The seed
--- @return Source A fresh source
function Rand.new(seed: integer): Rand.Source
  local st: State = {}
  local x = seed
  x, st.s0 = splitmix(x)
  x, st.s1 = splitmix(x)
  x, st.s2 = splitmix(x)
  local _, s3 = splitmix(x)
  st.s3 = s3

  local source: Rand.Source = {}

  source.int = function(_self: Rand.Source, min: integer, max: integer): integer
    if min > max then
      error(("rand: int(%d, %d): min is greater than max"):format(min, max), 2)
    end
    -- The width minus one, as unsigned; max - min wraps into it exactly.
    local span = max - min
    local mask = mask_for(span)
    while true do
      local draw = next64(st) & mask
      if not math.ult(span, draw) then
        return min + draw
      end
    end
  end

  source.float = function(_self: Rand.Source): number
    return (next64(st) >> 11) * (1.0 / 9007199254740992.0)
  end

  source.bytes = function(_self: Rand.Source, count: integer): string
    if count < 0 then
      error(("rand: bytes(%d): count is negative"):format(count), 2)
    end
    local parts: {string} = {}
    local words = (count + 7) // 8
    for i = 1, words do
      parts[i] = string.pack("<i8", next64(st))
    end
    return table.concat(parts):sub(1, count)
  end

  return source
end

--- `count` bytes from the operating system's entropy source (`getrandom`,
--- `/dev/urandom`), fit for a
--- key, token or nonce: unlike a `Source`, never the same twice and never
--- replayable. Raises when `count` is negative or past 1 MiB.
--- @param count integer How many bytes
--- @return string | nil The bytes
--- @return string Why none were drawn, or "" when they were
function Rand.entropy(count: integer): string | nil, string
  local bytes, trouble = sys.entropy(count)
  if bytes == nil then
    return nil, "rand: entropy: " .. trouble
  end
  return bytes, ""
end

return Rand
