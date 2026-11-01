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

local function test_normal_replays_from_a_seed()
  local a, b = Rand.new(9), Rand.new(9)
  for _ = 1, 100 do
    assert(a:normal() == b:normal())
  end
  assert(Rand.new(9):normal() ~= Rand.new(10):normal())
end

local function test_normal_refuses_degenerate_parameters()
  local src = Rand.new(0)
  Test.raises(function() src:normal(0, -1) end, "stddev not negative")
  Test.raises(function() src:normal(0 / 0, 1) end, "must be finite")
  Test.raises(function() src:normal(0, math.huge) end, "must be finite")
  Test.raises(function() src:normal(math.huge, 1) end, "must be finite")
  Test.raises(function() src:normal(0, 0 / 0) end, "must be finite")
end

local function test_normal_has_the_shape_of_a_bell()
  local src = Rand.new(5)
  -- A uniform on [-sqrt 3, sqrt 3] has mean 0 and variance 1 too, but
  -- only 0.577 of its mass within one deviation and a fourth moment of
  -- 1.8. The normal has 0.6827 (standard error 0.0033 at 20000 draws,
  -- so the band is over four) and 3.
  local n, within, fourth = 20000, 0, 0.0
  for _ = 1, n do
    local x = src:normal()
    if math.abs(x) < 1.0 then within = within + 1 end
    fourth = fourth + x * x * x * x
  end
  local fraction = within / n
  assert(math.abs(fraction - 0.6827) < 0.015, "within one deviation " .. tostring(fraction))
  fourth = fourth / n
  assert(math.abs(fourth - 3.0) < 0.3, "fourth moment " .. tostring(fourth))
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

local function test_gamma_replays_from_a_seed()
  local a, b = Rand.new(9), Rand.new(9)
  for _ = 1, 100 do
    assert(a:gamma(0.3) == b:gamma(0.3))
    assert(a:gamma(2.5, 4) == b:gamma(2.5, 4))
  end
  assert(Rand.new(9):gamma(2) ~= Rand.new(10):gamma(2))
end

local function test_gamma_refuses_degenerate_parameters()
  local src = Rand.new(0)
  Test.raises(function() src:gamma(0) end, "finite and positive")
  Test.raises(function() src:gamma(-1) end, "finite and positive")
  Test.raises(function() src:gamma(1, 0) end, "finite and positive")
  Test.raises(function() src:gamma(1, -2) end, "finite and positive")
  Test.raises(function() src:gamma(math.huge) end, "finite and positive")
  Test.raises(function() src:gamma(1, math.huge) end, "finite and positive")
  Test.raises(function() src:gamma(0 / 0) end, "finite and positive")
  Test.raises(function() src:gamma(1, 0 / 0) end, "finite and positive")
end

local function test_gamma_has_the_shape_of_a_gamma()
  local src = Rand.new(6)
  -- Targets: P(X < 1) = 1 - e^-1 for shape 1 and P(X < 0.5) =
  -- erf(sqrt 0.5) for shape 0.5, each within 0.015 (over four standard
  -- errors at 20000 draws); skewness 2 / sqrt(shape) for shape 4.5,
  -- within 0.1 (about five).
  local n, below = 20000, 0
  for _ = 1, n do
    if src:gamma(1) < 1.0 then below = below + 1 end
  end
  local fraction = below / n
  assert(math.abs(fraction - (1.0 - math.exp(-1.0))) < 0.015, "below 1: " .. tostring(fraction))
  -- Gamma(0.5) is half a chi-squared of one degree of freedom, so
  -- P(X < 0.5) = erf(sqrt(0.5)) = 0.6827; this checks the boosted path.
  below = 0
  for _ = 1, n do
    if src:gamma(0.5) < 0.5 then below = below + 1 end
  end
  fraction = below / n
  assert(math.abs(fraction - 0.6827) < 0.015, "gamma(0.5) below 0.5: " .. tostring(fraction))
  -- Skewness is 2 / sqrt(shape), 0.943 for 4.5.
  local k = 4.5
  local sum, sq, cube = 0.0, 0.0, 0.0
  for _ = 1, n do
    local x = src:gamma(k)
    sum, sq, cube = sum + x, sq + x * x, cube + x * x * x
  end
  local mean = sum / n
  local var = sq / n - mean * mean
  local third = cube / n - 3.0 * mean * sq / n + 2.0 * mean * mean * mean
  local skew = third / var ^ 1.5
  assert(math.abs(skew - 2.0 / math.sqrt(k)) < 0.1, "skewness " .. tostring(skew))
end

--- A draw function that reads `source`'s generator one word at a time,
--- so a twin source built from the same seed lines up with it.
local function words_of(source: Rand.Source): function(): integer
  return function(): integer
    return (string.unpack("<i8", source:bytes(8)))
  end
end

local function test_exported_normal_equals_the_method_draw_for_draw()
  local method = Rand.new(31)
  local draw = words_of(Rand.new(31))
  for _ = 1, 200 do
    assert(Rand.normal(draw) == method:normal())
  end
  for _ = 1, 50 do
    assert(Rand.normal(draw, -5.5, 2.25) == method:normal(-5.5, 2.25))
  end
  -- A zero stddev still consumes the same words as the method does.
  assert(Rand.normal(draw, 3, 0) == 3.0 and method:normal(3, 0) == 3.0)
  assert(Rand.normal(draw) == method:normal())
end

local function test_exported_gamma_equals_the_method_draw_for_draw()
  local method = Rand.new(32)
  local draw = words_of(Rand.new(32))
  for _, shape in ipairs({ 0.3, 1.0, 4.5, 30.0 }) do
    for _ = 1, 100 do
      assert(Rand.gamma(draw, shape) == method:gamma(shape), shape)
      assert(Rand.gamma(draw, shape, 2.5) == method:gamma(shape, 2.5), shape)
    end
  end
end

local function test_exported_samplers_validate_like_the_methods()
  local function draw(): integer return 1 end
  Test.raises(function() Rand.normal(draw, 0, -1) end, "stddev not negative")
  Test.raises(function() Rand.normal(draw, math.huge) end, "finite")
  Test.raises(function() Rand.normal(draw, 0, 0 / 0) end, "finite")
  Test.raises(function() Rand.gamma(draw, 0) end, "finite and positive")
  Test.raises(function() Rand.gamma(draw, 1, -2) end, "finite and positive")
  Test.raises(function() Rand.gamma(draw, math.huge) end, "finite and positive")
  Test.raises(function() Rand.gamma(draw, 1, 0 / 0) end, "finite and positive")
  -- A refusal draws nothing.
  local drawn = 0
  local function counting(): integer
    drawn = drawn + 1
    return 0
  end
  Test.raises(function() Rand.gamma(counting, -1) end, "finite and positive")
  Test.raises(function() Rand.normal(counting, 0, -1) end, "stddev not negative")
  assert(drawn == 0)
end

local seeds <const> = { 0, 1, -1, 42, 2026, 1 << 40 }

--- A float of the same bits as `x`, compared exactly: `==` would call a
--- NaN different from itself and 0.0 equal to -0.0.
local function same(a: number, b: number): boolean
  return string.pack("<d", a) == string.pack("<d", b)
end

--- Whether `bulk` is `values` bit for bit.
local function same_all(bulk: {number}, values: {number}): boolean
  if #bulk ~= #values then return false end
  for i, want in ipairs(values) do
    local got = bulk[i]
    if got == nil or not same(got, want) then return false end
  end
  return true
end

--- Draws `count` values with `single` from `twin`, to set against a bulk.
local function singles(count: integer, single: function(): number): {number}
  local values: mut {number} = {}
  for i = 1, count do values[i] = single() end
  return values
end

--- Whether `a` and `b` are in one state: their next words and floats agree.
local function in_step(a: Rand.Source, b: Rand.Source): boolean
  return a:bytes(24) == b:bytes(24) and same(a:float(), b:float())
end

local function test_floats_equal_the_same_number_of_single_draws()
  for _, seed in ipairs(seeds) do
    local bulk, twin = Rand.new(seed), Rand.new(seed)
    local values = bulk:floats(300)
    assert(same_all(values, singles(300, function(): number return twin:float() end)), seed)
    assert(in_step(bulk, twin), seed)
  end
end

local function test_normals_equal_the_same_number_of_single_draws()
  for _, seed in ipairs(seeds) do
    local bulk, twin = Rand.new(seed), Rand.new(seed)
    assert(same_all(bulk:normals(300), singles(300, function(): number return twin:normal() end)), seed)
    assert(in_step(bulk, twin), seed)
    assert(same_all(bulk:normals(120, -7.5, 3.25),
      singles(120, function(): number return twin:normal(-7.5, 3.25) end)), seed)
    assert(in_step(bulk, twin), seed)
    -- A stddev of 0 still consumes the words a draw does.
    assert(same_all(bulk:normals(10, 4, 0), singles(10, function(): number
      return twin:normal(4, 0)
    end)), seed)
    assert(in_step(bulk, twin), seed)
  end
end

local function test_gammas_equal_the_same_number_of_single_draws()
  -- 0.5 is the shape whose boost exponent is 2, which Lua squares rather
  -- than passing to pow.
  for _, shape in ipairs({ 0.05, 0.5, 0.9, 1.0, 1.5, 4.5, 30.0, 1000.0 }) do
    for _, seed in ipairs(seeds) do
      local bulk, twin = Rand.new(seed), Rand.new(seed)
      assert(same_all(bulk:gammas(150, shape), singles(150, function(): number
        return twin:gamma(shape)
      end)),
        tostring(shape) .. " seed " .. tostring(seed))
      assert(in_step(bulk, twin), shape)
      assert(same_all(bulk:gammas(40, shape, 2.5),
        singles(40, function(): number return twin:gamma(shape, 2.5) end)), shape)
      assert(in_step(bulk, twin), shape)
    end
  end
end

local function test_bulk_and_single_draws_interleave()
  local mixed, twin = Rand.new(77), Rand.new(77)
  local got: mut {number} = {}
  local want: mut {number} = {}
  local function take(values: {number})
    for _, v in ipairs(values) do got[#got + 1] = v end
  end
  local function expect(single: function(): number, count: integer)
    for _ = 1, count do
      local value = single()
      want[#want + 1] = value
    end
  end
  take({ mixed:float() })
  expect(function(): number return twin:float() end, 1)
  take(mixed:normals(7))
  expect(function(): number return twin:normal() end, 7)
  take({ mixed:gamma(0.7, 2) })
  expect(function(): number return twin:gamma(0.7, 2) end, 1)
  take(mixed:gammas(5, 3.5))
  expect(function(): number return twin:gamma(3.5) end, 5)
  take(mixed:floats(4))
  expect(function(): number return twin:float() end, 4)
  assert(mixed:int(1, 1000) == twin:int(1, 1000))
  take(mixed:normals(3, 10, 2))
  expect(function(): number return twin:normal(10, 2) end, 3)
  take({ mixed:normal() })
  expect(function(): number return twin:normal() end, 1)
  assert(same_all(got, want))
  assert(in_step(mixed, twin))
end

local function test_a_bulk_of_none_returns_an_empty_table_and_draws_nothing()
  local bulk, twin = Rand.new(5), Rand.new(5)
  assert(#bulk:floats(0) == 0 and #bulk:normals(0) == 0 and #bulk:gammas(0, 2) == 0)
  assert(in_step(bulk, twin))
end

local function test_a_bulk_draws_up_to_its_bound_and_refuses_past_it()
  local source = Rand.new(9)
  assert(#source:floats(1 << 20) == 1 << 20)
  local twin = Rand.new(10)
  local other = Rand.new(10)
  Test.raises(function() twin:floats(-1) end, "count is negative or past 1048576")
  Test.raises(function() twin:floats((1 << 20) + 1) end, "count is negative or past 1048576")
  Test.raises(function() twin:normals(-1) end, "count is negative or past 1048576")
  Test.raises(function() twin:normals(math.maxinteger) end, "count is negative or past 1048576")
  Test.raises(function() twin:gammas(math.mininteger, 1) end, "count is negative or past 1048576")
  Test.raises(function() twin:gammas((1 << 20) + 1, 1) end, "count is negative or past 1048576")
  assert(in_step(twin, other))
end

local function test_bulk_draws_validate_like_the_single_ones_and_draw_nothing()
  local bulk, twin = Rand.new(11), Rand.new(11)
  Test.raises(function() bulk:normals(5, 0, -1) end, "stddev not negative")
  Test.raises(function() bulk:normals(5, math.huge) end, "finite")
  Test.raises(function() bulk:normals(5, 0, 0 / 0) end, "finite")
  Test.raises(function() bulk:gammas(5, 0) end, "finite and positive")
  Test.raises(function() bulk:gammas(5, 1, -2) end, "finite and positive")
  Test.raises(function() bulk:gammas(5, math.huge) end, "finite and positive")
  Test.raises(function() bulk:gammas(5, 1, 0 / 0) end, "finite and positive")
  assert(in_step(bulk, twin))
end

local function test_a_bulk_error_names_the_caller()
  local ok, message = pcall(function() Rand.new(1):floats(-1) end)
  assert(not ok)
  assert(tostring(message):find("cosmic.rand_test:", 1, true) == 1, tostring(message))
end

--- Long runs, so that a last-bit difference in a rare fraction of draws
--- shows: the boost u^2 of shape 0.5 differs between a product and pow for
--- about 0.1% of u, which a few hundred draws would miss.
local function test_long_bulks_equal_single_draws_bit_for_bit()
  local bulk, twin = Rand.new(2027), Rand.new(2027)
  assert(same_all(bulk:gammas(100000, 0.5), singles(100000, function(): number
    return twin:gamma(0.5)
  end)))
  assert(in_step(bulk, twin))
  assert(same_all(bulk:normals(60000, 1.5, 0.25), singles(60000, function(): number
    return twin:normal(1.5, 0.25)
  end)))
  assert(in_step(bulk, twin))
  assert(same_all(bulk:floats(60000), singles(60000, function(): number return twin:float() end)))
  assert(in_step(bulk, twin))
  for _, shape in ipairs({ 0.3, 1.0, 2.5, 40.0 }) do
    assert(same_all(bulk:gammas(30000, shape, 0.75), singles(30000, function(): number
      return twin:gamma(shape, 0.75)
    end)), shape)
    assert(in_step(bulk, twin), shape)
  end
end
