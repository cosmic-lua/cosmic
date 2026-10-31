local Codec = require("cosmic.codec")
local Rand = require("cosmic.rand")
local Test = require("cosmic.test")

local hex = Codec.hex

-- xoshiro256** seeded by splitmix64, the reference generators' own
-- outputs: a seed names the same sequence everywhere.
local function test_a_seed_draws_the_reference_sequence()
  local zero = Rand.new(0)
  assert(hex(zero:bytes(8)) == "b4f275cb365fec99", "seed 0's first word")
  local one = Rand.new(1)
  assert(hex(one:bytes(10)) == "c510c70f6daff2b3ea4c", "seed 1's first ten bytes")
  local minus = Rand.new(-1)
  assert(hex(minus:bytes(8)) == "08ad7e2ad520558f", "seed -1's first word")
end

local function test_two_sources_with_one_seed_agree()
  local a, b = Rand.new(42), Rand.new(42)
  for _ = 1, 100 do
    assert(a:int(-5, 5) == b:int(-5, 5))
    assert(a:float() == b:float())
  end
  assert(Rand.new(42):int(0, 1 << 40) ~= Rand.new(43):int(0, 1 << 40))
end

local function test_int_stays_within_its_bounds_and_reaches_both()
  local src = Rand.new(7)
  local seen: mut {integer: boolean} = {}
  for _ = 1, 1000 do
    local v = src:int(-3, 3)
    assert(v >= -3 and v <= 3, "out of range: " .. tostring(v))
    seen[v] = true
  end
  for v = -3, 3 do
    assert(seen[v], "never drew " .. tostring(v))
  end
  assert(src:int(9, 9) == 9)
end

local function test_uniform_draws_within_range_from_any_bit_source()
  local src = Rand.new(11)
  local function draw(): integer return src:int(math.mininteger, math.maxinteger) end
  local seen: mut {integer: integer} = {}
  for _ = 1, 3000 do
    local v = Rand.uniform(draw, 0, 2)
    assert(v >= 0 and v <= 2, "out of range: " .. tostring(v))
    seen[v] = (seen[v] or 0) + 1
  end
  -- Both ends are reachable, and a modulo would favor 0 (2^64 % 3 = 1):
  -- rejection keeps the three within a loose band of 1000 each.
  for v = 0, 2 do
    assert(seen[v] and seen[v] > 850 and seen[v] < 1150, "biased: " .. tostring(v) .. " x" .. tostring(seen[v]))
  end
  assert(Rand.uniform(draw, -4, -4) == -4)
  assert(Rand.uniform(draw, math.mininteger, math.mininteger + 1) <= math.mininteger + 1)
  -- Words are masked to 3 and rejected while past the span 2.
  local words = { 7, 3, 1 }
  local at: integer = 0
  local got = Rand.uniform(function(): integer
    at = at + 1
    return words[at]
  end, 0, 2)
  assert(got == 1 and at == 3, "rejection: " .. tostring(got) .. " after " .. tostring(at))
  assert(not pcall(Rand.uniform, draw, 3, 2))
end

local function test_int_spans_the_whole_integer_range()
  local src = Rand.new(0)
  -- The full width takes the raw word unmasked, offset by min.
  assert(src:int(math.mininteger, math.maxinteger) == 0x19ec5f36cb75f2b4)
  local wide = Rand.new(3)
  for _ = 1, 100 do
    local v = wide:int(math.maxinteger - 2, math.maxinteger)
    assert(v >= math.maxinteger - 2)
  end
end

local function test_float_is_in_the_unit_interval()
  local src = Rand.new(11)
  for _ = 1, 1000 do
    local f = src:float()
    assert(f >= 0.0 and f < 1.0)
  end
end

local function test_bytes_draws_any_length()
  local src = Rand.new(5)
  assert(src:bytes(0) == "")
  assert(#src:bytes(1) == 1)
  assert(#src:bytes(17) == 17)
end

local function test_a_degenerate_argument_raises()
  local src = Rand.new(0)
  Test.raises(function() src:int(2, 1) end, "min is greater than max")
  local ok2, err2 = pcall(src.bytes, src, -1)
  assert(not ok2 and tostring(err2):find("count is negative", 1, true), tostring(err2))
end

local function test_entropy_draws_fresh_bytes()
  local a = assert(Rand.entropy(32))
  local b = assert(Rand.entropy(32))
  assert(#a == 32 and #b == 32 and a ~= b)
  assert(assert(Rand.entropy(0)) == "")
  -- Past getentropy's 256-byte ceiling, drawn in several calls.
  local many = assert(Rand.entropy(1000))
  assert(#many == 1000 and many:sub(1, 256) ~= many:sub(257, 512))
end

local function test_entropy_refuses_a_degenerate_count()
  assert(not pcall(Rand.entropy, -1))
  assert(not pcall(Rand.entropy, (1 << 20) + 1))
  assert(#assert(Rand.entropy(1 << 20)) == 1 << 20)
end

--- The mean and variance of `n` draws of `draw`.
local function moments(draw: function(): number, n: integer): number, number
  local sum, sq = 0.0, 0.0
  for _ = 1, n do
    local x = draw()
    sum = sum + x
    sq = sq + x * x
  end
  local mean = sum / n
  return mean, sq / n - mean * mean
end

local function test_normal_has_its_mean_and_deviation()
  local src = Rand.new(3)
  -- 20000 draws put the sample mean within 0.03 of 0 at about four
  -- standard errors, and the variance within 0.06 of 1.
  local mean, var = moments(function(): number return src:normal() end, 20000)
  assert(math.abs(mean) < 0.03, "mean " .. tostring(mean))
  assert(math.abs(var - 1.0) < 0.06, "variance " .. tostring(var))
  mean, var = moments(function(): number return src:normal(10, 3) end, 20000)
  assert(math.abs(mean - 10.0) < 0.1, "mean " .. tostring(mean))
  assert(math.abs(var - 9.0) < 0.6, "variance " .. tostring(var))
  assert(src:normal(5, 0) == 5.0)
end

local function test_gamma_has_its_mean_and_variance_either_side_of_shape_one()
  local src = Rand.new(4)
  -- Gamma(k, theta) has mean k * theta and variance k * theta^2; a shape
  -- below 1 takes the boosted path.
  local record Case
    k: number
    theta: number
  end
  local cases: {Case} = {
    { k = 0.5, theta = 2.0 },
    { k = 1.0, theta = 1.0 },
    { k = 4.5, theta = 0.5 },
  }
  for _, case in ipairs(cases) do
    local k, theta = case.k, case.theta
    local least = math.huge
    local mean, var = moments(function(): number
      local x = src:gamma(k, theta)
      if x < least then least = x end
      return x
    end, 20000)
    local want_mean, want_var = k * theta, k * theta * theta
    local where = ("gamma(%g, %g): "):format(k, theta)
    assert(least >= 0.0, where .. "negative draw " .. tostring(least))
    assert(math.abs(mean - want_mean) < 0.05 * want_mean + 0.02, where .. "mean " .. tostring(mean))
    assert(math.abs(var - want_var) < 0.1 * want_var + 0.02, where .. "variance " .. tostring(var))
  end
end

local function test_normal_and_gamma_replay_from_a_seed()
  local a, b = Rand.new(9), Rand.new(9)
  for _ = 1, 100 do
    assert(a:normal() == b:normal())
    assert(a:gamma(0.3) == b:gamma(0.3))
    assert(a:gamma(2.5, 4) == b:gamma(2.5, 4))
  end
  assert(Rand.new(9):normal() ~= Rand.new(10):normal())
end

local function test_normal_and_gamma_refuse_degenerate_parameters()
  local src = Rand.new(0)
  Test.raises(function() src:normal(0, -1) end, "stddev not negative")
  Test.raises(function() src:normal(0 / 0, 1) end, "must be finite")
  Test.raises(function() src:normal(0, math.huge) end, "must be finite")
  Test.raises(function() src:gamma(0) end, "finite and positive")
  Test.raises(function() src:gamma(-1) end, "finite and positive")
  Test.raises(function() src:gamma(1, 0) end, "finite and positive")
  Test.raises(function() src:gamma(math.huge) end, "finite and positive")
  Test.raises(function() src:gamma(0 / 0) end, "finite and positive")
end
