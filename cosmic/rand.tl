--- Seeded pseudorandom numbers. A source made from a seed draws the same
--- sequence on every run, and on every target for `int`, `float` and
--- `bytes`, so a run that depends on chance can be replayed by naming
--- its seed; `normal` and `gamma` (and their bulk forms) agree across
--- targets only as far as their `log` (and for `gamma` `pow`) do. The generator is xoshiro256**,
--- its state filled from the seed by splitmix64. It is not cryptographic: never derive a key, token or
--- nonce from it; draw those from [`Rand.entropy`].
---
--- - [`Rand.new`] makes a seeded [`Rand.Source`], whose `int`, `float`,
---   `bytes`, `normal` and `gamma` draw from it: use one for shuffles,
---   simulations and tests that must replay. Its `floats`, `normals` and
---   `gammas` draw many values at once, in the C core, to the same
---   sequence: use them where a run needs thousands of draws.
--- - [`Rand.uniform`], [`Rand.normal`] and [`Rand.gamma`] are the
---   samplers behind `Source:int`, `normal` and `gamma`, each taking any
---   function that draws 64 random bits: use them to draw from another
---   bit source, such as [`Rand.entropy`].
--- - [`Rand.entropy`] draws unguessable bytes from the operating system:
---   use it for keys, tokens and nonces.
--- - [`Rand.uuid`] draws a UUID from that entropy, as text: use it for an
---   identifier. [`Rand.uuid_of`] writes sixteen bytes a caller holds as
---   one, and [`Rand.uuid_maker`] draws from an entropy source and a clock
---   the caller names.
---
---     local dice = Rand.new(2026)
---     local roll = dice:int(1, 6)
---     local token = assert(Rand.entropy(16))
---     local id = assert(Rand.uuid())

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
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
    --- Marsaglia and Tsang's method. Raises unless both are finite and
    --- positive. Its value goes through the target's `log` and, for a
    --- shape below 1, `pow`. A shape far below 1 can underflow a draw
    --- to 0, and a large `shape * scale` can overflow one to infinity.
    mut gamma: function(self: Source, shape: number, scale?: number): number

    --- `count` floats, each drawn as `float` draws one, in one call to the
    --- core. The values and the generator's state after them are exactly
    --- those of `count` successive `float` calls, on every target, so bulk
    --- and single draws interleave freely. Raises when `count` is negative
    --- or past 1048576 (2^20), drawing nothing.
    mut floats: function(self: Source, count: integer): {number}

    --- `count` values, each drawn as `normal(mean, stddev)` draws one, in
    --- one call to the core. The values and the generator's state after
    --- them are exactly those of `count` successive `normal` calls on the
    --- same target, so bulk and single draws interleave freely. Raises
    --- when `count` is negative or past 1048576 (2^20), or for a `mean`
    --- or `stddev` `normal` refuses, drawing nothing.
    mut normals: function(self: Source, count: integer, mean?: number, stddev?: number): {number}

    --- `count` values, each drawn as `gamma(shape, scale)` draws one, in
    --- one call to the core. The values and the generator's state after
    --- them are exactly those of `count` successive `gamma` calls on the
    --- same target, so bulk and single draws interleave freely. Raises
    --- when `count` is negative or past 1048576 (2^20), or for a `shape`
    --- or `scale` `gamma` refuses, drawing nothing.
    mut gammas: function(self: Source, count: integer, shape: number, scale?: number): {number}
  end
end

--- The kinds of draw [`sys.rand_draw`] takes, as core/rand.h's.
local KIND_FLOAT <const> = 0
local KIND_NORMAL <const> = 1
local KIND_GAMMA <const> = 2

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

--- A float uniform on [0, 1) from one draw of `draw`, a multiple of 2^-53.
local function unit(draw: function(): integer): number
  return (draw() >> 11) * (1.0 / 9007199254740992.0)
end

--- A standard normal draw from `draw`, by Marsaglia's polar method: a
--- point uniform in the unit disc, kept when strictly inside and off the
--- centre. The pair's second value is dropped, so a draw leaves no state
--- behind but the generator's.
local function standard_normal(draw: function(): integer): number
  while true do
    local u = 2.0 * unit(draw) - 1.0
    local v = 2.0 * unit(draw) - 1.0
    local s = u * u + v * v
    if s < 1.0 and s > 0.0 then
      return u * math.sqrt(-2.0 * math.log(s) / s)
    end
  end
end

--- A gamma draw of shape `shape` and scale 1 from `draw`, by Marsaglia and
--- Tsang (2000). A shape below 1 draws shape + 1 and scales it by
--- u^(1/shape), the boost their paper gives.
local function standard_gamma(draw: function(): integer, shape: number): number
  if shape < 1.0 then
    -- 1 - unit is in (0, 1], so the power is never of 0.
    local u = 1.0 - unit(draw)
    return standard_gamma(draw, shape + 1.0) * u ^ (1.0 / shape)
  end
  local d = shape - 1.0 / 3.0
  local c = 1.0 / math.sqrt(9.0 * d)
  while true do
    local x = standard_normal(draw)
    local t = 1.0 + c * x
    if t > 0.0 then
      local v = t * t * t
      local u = 1.0 - unit(draw)
      local x2 = x * x
      if u < 1.0 - 0.0331 * x2 * x2 or
          math.log(u) < 0.5 * x2 + d * (1.0 - v + math.log(v)) then
        return d * v
      end
    end
  end
end

--- `count` values of `kind` from `st`'s generator by the core, which
--- advances the state: it is lent as four words and written back.
local function bulk(st: State, kind: integer, count: integer, first: number, second: number): {number}
  local words: mut {integer} = { st.s0, st.s1, st.s2, st.s3 }
  local values = sys.rand_draw(words, kind, count, first, second)
  -- The core writes four integers back; assert narrows what a read of the array cannot.
  st.s0 = assert(words[1])
  st.s1 = assert(words[2])
  st.s2 = assert(words[3])
  st.s3 = assert(words[4])
  return values
end

--- The most values one bulk draw returns, as core/rand.h's.
local BULK_MAX <const> = 1 << 20

--- Raises unless `mean` and `stddev` suit a normal draw of `name`, blaming
--- the frame `level` above the caller of this check.
local function check_normal(name: string, level: integer, m: number, sd: number)
  if not (finite(m) and finite(sd) and sd >= 0.0) then
    error(("rand: %s(%s, %s): mean and stddev must be finite, stddev not negative")
        :format(name, tostring(m), tostring(sd)), level + 1)
  end
end

--- Raises unless `shape` and `scale` suit a gamma draw of `name`, blaming
--- as [`check_normal`] does.
local function check_gamma(name: string, level: integer, k: number, theta: number)
  if not (finite(k) and finite(theta) and k > 0.0 and theta > 0.0) then
    error(("rand: %s(%s, %s): shape and scale must be finite and positive")
        :format(name, tostring(k), tostring(theta)), level + 1)
  end
end

--- Raises unless `count` is a number of values one bulk draw of `name`
--- returns, blaming as [`check_normal`] does.
local function check_count(name: string, level: integer, count: integer)
  if count < 0 or count > BULK_MAX then
    error(("rand: %s(%d): count is negative or past %d"):format(name, count, BULK_MAX), level + 1)
  end
end

--- A float drawn from the normal distribution of mean `mean` (default 0)
--- and standard deviation `stddev` (default 1), by Marsaglia's polar
--- method, from `draw`, a function returning 64 random bits as a Lua
--- integer (any bit pattern). `draw` is called twice per attempt, and an
--- attempt is kept about 78.5% of the time. Raises when either parameter
--- is not finite or `stddev` is negative; a `stddev` of 0 gives `mean`.
--- It is the sampler of `Source:normal`, exported so a caller with
--- another bit source (the operating system's entropy) shares it. Its
--- value goes through the target's `log`.
--- @param draw function The source of 64 random bits
--- @param mean number The mean, 0 when nil
--- @param stddev number The standard deviation, 1 when nil
--- @return number The value
function Rand.normal(draw: function(): integer, mean?: number, stddev?: number): number
  local m, sd = mean or 0.0, stddev or 1.0
  check_normal("normal", 2, m, sd)
  return m + sd * standard_normal(draw)
end

--- A float drawn from the gamma distribution of shape `shape` and scale
--- `scale` (default 1), whose mean is `shape * scale`, by Marsaglia and
--- Tsang's method, from `draw`, a function returning 64 random bits as a
--- Lua integer (any bit pattern). Raises unless both parameters are
--- finite and positive. It is the sampler of `Source:gamma`, exported so
--- a caller with another bit source (the operating system's entropy)
--- shares it. Its value goes through the target's `log` and, for a shape
--- below 1, `pow`. A shape far below 1 can underflow a draw to 0, and a
--- large `shape * scale` can overflow one to infinity.
--- @param draw function The source of 64 random bits
--- @param shape number The shape
--- @param scale number The scale, 1 when nil
--- @return number The value
function Rand.gamma(draw: function(): integer, shape: number, scale?: number): number
  local k, theta = shape, scale or 1.0
  check_gamma("gamma", 2, k, theta)
  return standard_gamma(draw, k) * theta
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
  local function draw(): integer return next64(st) end

  return {
    int = function(_self: Rand.Source, min: integer, max: integer): integer
      return Rand.uniform(draw, min, max)
    end,
    float = function(_self: Rand.Source): number
      return unit(draw)
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
      return Rand.normal(draw, mean, stddev)
    end,
    gamma = function(_self: Rand.Source, shape: number, scale?: number): number
      return Rand.gamma(draw, shape, scale)
    end,
    floats = function(_self: Rand.Source, count: integer): {number}
      check_count("floats", 2, count)
      return bulk(st, KIND_FLOAT, count, 0.0, 0.0)
    end,
    normals = function(_self: Rand.Source, count: integer, mean?: number, stddev?: number): {number}
      local m, sd = mean or 0.0, stddev or 1.0
      check_count("normals", 2, count)
      check_normal("normals", 2, m, sd)
      return bulk(st, KIND_NORMAL, count, m, sd)
    end,
    gammas = function(_self: Rand.Source, count: integer, shape: number, scale?: number): {number}
      local k, theta = shape, scale or 1.0
      check_count("gammas", 2, count)
      check_gamma("gammas", 2, k, theta)
      return bulk(st, KIND_GAMMA, count, k, theta)
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

--- `bytes`, which must be sixteen, as a UUID in its canonical text:
--- lower-case hexadecimal in groups of 8, 4, 4, 4 and 12 digits with a
--- hyphen between, 36 characters. With no `version` every bit is written
--- as given. With one, from 1 through 8, the four version bits and the
--- two variant bits (RFC 9562's `10`) are set first and the other 122
--- kept, so sixteen bytes of a seeded [`Source`] give an identifier a
--- test can replay, and the first sixteen of a hash a name-based one.
--- Raises when `bytes` is not sixteen bytes or `version` is out of range.
--- @param bytes string The sixteen bytes
--- @param version integer The version to mark the bytes with, none when nil
--- @return string The text
function Rand.uuid_of(bytes: string, version?: integer): string
  if #bytes ~= 16 then
    error(("rand: uuid_of: %d bytes given, not 16"):format(#bytes), 2)
  end
  if version ~= nil then
    if version < 1 or version > 8 then
      error(("rand: uuid_of: version %d is not 1 through 8"):format(version), 2)
    end
    local marked = (assert(bytes:byte(7), "sixteen bytes were given") & 0x0f) | (version << 4)
    local variant = (assert(bytes:byte(9), "sixteen bytes were given") & 0x3f) | 0x80
    bytes = bytes:sub(1, 6) .. string.char(marked) .. bytes:sub(8, 8) .. string.char(variant) .. bytes:sub(10)
  end
  local hex = Codec.hex(bytes)
  return hex:sub(1, 8) .. "-" .. hex:sub(9, 12) .. "-" .. hex:sub(13, 16) .. "-" ..
    hex:sub(17, 20) .. "-" .. hex:sub(21, 32)
end

--- A function that draws UUIDs as [`Rand.uuid`] does, from `entropy`
--- (default [`Rand.entropy`]) and, for version 7, the wall clock `now_ns`
--- in nanoseconds (default [`cosmic.clock.now_ns`]). Each maker orders
--- its own version 7 values and no other maker's. `entropy` is asked for
--- 16 bytes for a version 4 value and 8 for a version 7 one, and answers
--- as [`Rand.entropy`] does; the bytes and the reason of one that fails
--- are passed on, and an error it raises is not caught. Name both to pin
--- a test's values, or `entropy` to draw from a pool.
--- @param entropy function The source of bytes
--- @param now_ns function The wall clock, in nanoseconds
--- @return function The function that draws
function Rand.uuid_maker(
    entropy?: function(count: integer): (string?, string),
    now_ns?: function(): integer
): function(version?: integer): (string?, string)
  local draw_bytes = entropy or Rand.entropy
  local read_clock = now_ns or Clock.now_ns
  -- The last version 7 timestamp given: milliseconds in the high bits,
  -- 4096ths of one in the low twelve.
  local last = -1

  --- `count` bytes of the source, or nil and why there are none.
  local function drawn(count: integer): string?, string
    local bytes, trouble = draw_bytes(count)
    if bytes == nil then return nil, trouble end
    if #bytes ~= count then
      return nil, ("rand: uuid: the entropy source gave %d bytes, not %d"):format(#bytes, count)
    end
    return bytes, ""
  end

  return function(version?: integer): string?, string
    local wanted = version or 4
    if wanted == 4 then
      local bytes, trouble = drawn(16)
      if bytes == nil then return nil, trouble end
      return Rand.uuid_of(bytes, 4), ""
    end
    if wanted ~= 7 then
      error(("rand: uuid(%d): the version is 4 or 7"):format(wanted), 2)
    end
    local tail, trouble = drawn(8)
    if tail == nil then return nil, trouble end
    local ns = read_clock()
    if ns < 0 then
      return nil, ("rand: uuid: the clock reads %d ns, before 1970, which version 7 has no room for"):format(ns)
    end
    -- At most 2^55: every nanosecond count an integer holds is under 2^44
    -- milliseconds, so the 48 bits of them never overflow.
    local stamp = ((ns // 1000000) << 12) | ((ns % 1000000) * 4096 // 1000000)
    if stamp <= last then stamp = last + 1 end
    last = stamp
    return Rand.uuid_of(string.pack(">I6I2", stamp >> 12, stamp & 0xfff) .. tail, 7), ""
  end
end

local draw_uuid = Rand.uuid_maker()

--- A UUID (RFC 9562) drawn from the operating system's entropy, in its
--- canonical text: 36 characters, lower-case hexadecimal in groups of 8,
--- 4, 4, 4 and 12 digits, as `f81d4fae-7dec-41d0-a765-00a0c91e6bf6`.
---
--- Version 4, the default, is 122 bits of entropy: fit for an identifier
--- nobody can guess. Version 7 opens with the wall clock, 48 bits of Unix
--- milliseconds and then 12 bits of the clock's fraction of the
--- millisecond (the RFC's method 3), and ends in 62 bits of entropy.
--- Version 7 values compare as text in the order this process drew them:
--- one that would not sort after the one before, in the same 4096th of a
--- millisecond or after the clock stepped back, takes the previous
--- timestamp plus one 4096th. Two processes are ordered only as far as
--- their clocks are, and a version 7 value tells its reader when it was
--- drawn.
---
--- Nil and why when the entropy source fails or, for version 7, the
--- clock reads before 1970. Raises when `version` is neither 4 nor 7.
--- @param version integer 4 or 7; 4 when nil
--- @return string | nil The UUID
--- @return string Why none was drawn, or "" when one was
function Rand.uuid(version?: integer): string?, string
  if version ~= nil and version ~= 4 and version ~= 7 then
    error(("rand: uuid(%d): the version is 4 or 7"):format(version), 2)
  end
  return draw_uuid(version)
end

return Rand
