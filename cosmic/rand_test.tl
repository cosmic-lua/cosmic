local Codec = require("cosmic.codec")
local Rand = require("cosmic.rand")

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
  local seen: {integer: boolean} = {}
  for _ = 1, 1000 do
    local v = src:int(-3, 3)
    assert(v >= -3 and v <= 3, "out of range: " .. v)
    seen[v] = true
  end
  for v = -3, 3 do
    assert(seen[v], "never drew " .. v)
  end
  assert(src:int(9, 9) == 9)
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
  local ok, err = pcall(src.int, src, 2, 1)
  assert(not ok and tostring(err):find("min is greater than max", 1, true), tostring(err))
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
