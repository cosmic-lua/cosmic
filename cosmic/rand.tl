--- Seeded pseudorandom numbers. A source made from a seed draws the same
--- sequence on every run and every target, so a run that depends on
--- chance can be replayed by naming its seed. The generator is
--- xoshiro256**, its state filled from the seed by splitmix64. It is not
--- cryptographic: never derive a key, token or nonce from it; draw those
--- from [`Rand.entropy`].
---
--- - [`Rand.new`] makes a seeded [`Rand.Source`], whose `int`, `float`,
---   `bytes`, `normal` and `gamma` draw from it: use one for shuffles,
---   simulations and tests that must replay.
--- - [`Rand.uniform`] picks an unbiased integer in a range from any
---   function that draws 64 random bits.
--- - [`Rand.entropy`] draws unguessable bytes from the operating system:
---   use it for keys, tokens and nonces.
---
---     local dice = Rand.new(2026)
---     local roll = dice:int(1, 6)
---     local token = assert(Rand.entropy(16))

local sys = require("cosmic.sys")

local record Rand
  --- A generator and its state. Each source draws its own sequence;
  --- two made from the same seed draw the same one.
  record Source
    --- An integer drawn uniformly from `min` through `max`, both
    --- included. Raises when `min` is greater than `max`.
    mut int: function(self: Source, min: integer, max: integer): integer

    --- A float drawn uniformly from [0, 1), a multiple of 2^-53.
    mut float: function(self: Source): number

    --- `count` bytes drawn uniformly. Raises when `count` is negative.
    mut bytes: function(self: Source, count: integer): string

    --- A float drawn from the normal distribution of mean `mean`
    --- (default 0) and standard deviation `stddev` (default 1), by
    --- Marsaglia's polar method. Raises when either is not finite or
    --- `stddev` is negative; a `stddev` of 0 gives `mean`. Its value
    --- goes through the target's `log`, so a seed's draws agree across
    --- targets only as far as their `log`s do.
    mut normal: function(self: Source, mean?: number, stddev?: number): number

    --- A float drawn from the gamma distribution of shape `shape` and
    --- scale `scale` (default 1), whose mean is `shape * scale`, by
    --- Marsaglia and Tsang's method. Raises when either is not finite
    --- and positive. Like `normal`, it goes through the target's `log`.
    --- A shape far below 1 can underflow a draw to 0.
    mut gamma: function(self: Source, shape: number, scale?: number): number
  end
end

local record State
  mut s0: integer
  mut s1: integer
  mut s2: integer
  mut s3: integer
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

--- An integer drawn uniformly from `min` through `max`, both included,
--- from `draw`, a function returning 64 random bits as a Lua integer
--- (any bit pattern). By rejection: a draw is masked to the width of the
--- range and kept only when within it, so no value is likelier than
--- another, as modulo would make it. `draw` is called once per attempt,
--- at least once even when `min` equals `max`. Raises when `min` is
--- greater than `max`. It is the sampler of `Source:int`, exported so a
--- caller with another bit source (the operating system's entropy) shares it.
--- @param draw function The source of 64 random bits
--- @param min integer The least value
--- @param max integer The greatest value
--- @return integer The value
function Rand.uniform(draw: function(): integer, min: integer, max: integer): integer
  if min > max then
    error(("rand: int(%d, %d): min is greater than max"):format(min, max), 2)
  end
  -- The width minus one, as unsigned; max - min wraps into it exactly.
  local span = max - min
  local mask = mask_for(span)
  while true do
    local candidate = draw() & mask
    if not math.ult(span, candidate) then
      return min + candidate
    end
  end
end

--- Whether `x` is a number neither infinite nor NaN.
local function finite(x: number): boolean
  return x - x == 0.0
end

--- A float uniform on [0, 1) from `st`, a multiple of 2^-53.
local function unit(st: State): number
  return (next64(st) >> 11) * (1.0 / 9007199254740992.0)
end

--- A standard normal draw from `st`, by Marsaglia's polar method: a
--- point uniform in the unit disc, kept when strictly inside and off the
--- centre. The pair's second value is dropped, so a draw leaves no state
--- behind but the generator's.
local function standard_normal(st: State): number
  while true do
    local u = 2.0 * unit(st) - 1.0
    local v = 2.0 * unit(st) - 1.0
    local s = u * u + v * v
    if s < 1.0 and s > 0.0 then
      return u * math.sqrt(-2.0 * math.log(s) / s)
    end
  end
end

--- A gamma draw of shape `shape` and scale 1 from `st`, by Marsaglia and
--- Tsang (2000). A shape below 1 draws shape + 1 and scales it by
--- u^(1/shape), the boost their paper gives.
local function standard_gamma(st: State, shape: number): number
  if shape < 1.0 then
    -- 1 - unit is in (0, 1], so the power is never of 0.
    local u = 1.0 - unit(st)
    return standard_gamma(st, shape + 1.0) * u ^ (1.0 / shape)
  end
  local d = shape - 1.0 / 3.0
  local c = 1.0 / math.sqrt(9.0 * d)
  while true do
    local x = standard_normal(st)
    local t = 1.0 + c * x
    if t > 0.0 then
      local v = t * t * t
      local u = 1.0 - unit(st)
      local x2 = x * x
      if u < 1.0 - 0.0331 * x2 * x2 or
          math.log(u) < 0.5 * x2 + d * (1.0 - v + math.log(v)) then
        return d * v
      end
    end
  end
end

--- A source drawing the sequence `seed` names. Every integer is a
--- distinct seed, zero and negative ones included.
--- @param seed integer The seed
--- @return Source A fresh source
function Rand.new(seed: integer): Rand.Source
  local s0, s1, s2, s3: integer, integer, integer, integer
  local x = seed
  x, s0 = splitmix(x)
  x, s1 = splitmix(x)
  x, s2 = splitmix(x)
  local _, last = splitmix(x)
  s3 = last
  local st: State = { s0 = s0, s1 = s1, s2 = s2, s3 = s3 }

  return {
    int = function(_self: Rand.Source, min: integer, max: integer): integer
      return Rand.uniform(function(): integer return next64(st) end, min, max)
    end,
    float = function(_self: Rand.Source): number
      return unit(st)
    end,
    bytes = function(_self: Rand.Source, count: integer): string
      if count < 0 then
        error(("rand: bytes(%d): count is negative"):format(count), 2)
      end
      local parts: mut {string} = {}
      local words = (count + 7) // 8
      for i = 1, words do
        parts[i] = string.pack("<i8", next64(st))
      end
      return table.concat(parts):sub(1, count)
    end,
    normal = function(_self: Rand.Source, mean?: number, stddev?: number): number
      local m, sd = mean or 0.0, stddev or 1.0
      if not (finite(m) and finite(sd) and sd >= 0.0) then
        error(("rand: normal(%s, %s): mean and stddev must be finite, stddev not negative")
            :format(tostring(m), tostring(sd)), 2)
      end
      return m + sd * standard_normal(st)
    end,
    gamma = function(_self: Rand.Source, shape: number, scale?: number): number
      local k, theta = shape, scale or 1.0
      if not (finite(k) and finite(theta) and k > 0.0 and theta > 0.0) then
        error(("rand: gamma(%s, %s): shape and scale must be finite and positive")
            :format(tostring(k), tostring(theta)), 2)
      end
      return standard_gamma(st, k) * theta
    end,
  }
end

--- `count` bytes from the operating system's entropy source
--- (`getentropy`, as `/dev/urandom` serves), fit for a key, token or
--- nonce: unlike a [`Source`], never the same twice and never replayable.
--- Raises when `count` is negative or past 1 MiB.
--- @param count integer How many bytes
--- @return string | nil The bytes
--- @return string Why none were drawn, or "" when they were
function Rand.entropy(count: integer): string?, string
  local bytes, trouble = sys.entropy(count)
  if bytes == nil then
    return nil, "rand: entropy: " .. trouble
  end
  return bytes, ""
end

return Rand
