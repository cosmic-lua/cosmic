#!/usr/bin/env cosmic
local check = require("cosmic.check")
local rand = require("cosmic.rand")

local function test_bytes_returns_requested_length()
  local b = rand.bytes(16)
  assert(#b == 16, "bytes(16) should return 16 bytes, got " .. #b)
end
test_bytes_returns_requested_length()

local function test_bytes_different_each_call()
  local b1 = assert(rand.bytes(32))
  local b2 = assert(rand.bytes(32))
  assert(b1 ~= b2, "bytes should return different values each call")
end
test_bytes_different_each_call()

local function test_bytes_various_sizes()
  for _, size in ipairs({1, 8, 16, 32, 64, 128}) do
    local b = rand.bytes(size)
    assert(#b == size, "bytes(" .. size .. ") should return " .. size .. " bytes, got " .. #b)
  end
end
test_bytes_various_sizes()

local function test_bytes_statistical_sanity()
  -- 4096 draws should touch nearly all 256 byte values: the chance a
  -- given value is absent is (255/256)^4096 ~ 1e-7, so requiring 250
  -- distinct values can only fail on a broken (constant/low-entropy)
  -- generator, not on bad luck.
  local b = check.must(rand.bytes(4096))
  local seen: {integer: boolean} = {}
  local distinct = 0
  for i = 1, #b do
    local v = string.byte(b, i)
    if not seen[v] then
      seen[v] = true
      distinct = distinct + 1
    end
  end
  assert(distinct >= 250,
    "4096 random bytes should cover >=250 distinct values, got " .. distinct)
end
test_bytes_statistical_sanity()

-- Fast pseudo-random tests (non-cryptographic).

local function test_rand64()
  local n = rand.insecure64()
  assert(math.type(n) == "integer", "insecure64 should return integer, got " .. type(n))
  -- Two calls should almost certainly differ (false positive rate: 1/2^64)
  local n2 = rand.insecure64()
  assert(n ~= n2, "insecure64 should return different values each call")
end
test_rand64()

-- Crypto-grade bounded integers

local function test_int_bounds()
  for _ = 1, 500 do
    local n = assert(rand.int(-3, 7))
    assert(n >= -3 and n <= 7, "int(-3, 7) out of bounds: " .. n)
    assert(math.type(n) == "integer", "int should return an integer")
  end
end
test_int_bounds()

local function test_int_degenerate_range()
  assert(rand.int(5, 5) == 5, "int(5, 5) must return 5")
end
test_int_degenerate_range()

local function test_int_distribution_smoke()
  -- Every value of a small range should appear in a modest sample
  -- (P(miss) < 4 * (3/4)^400, effectively zero).
  local seen: {integer: boolean} = {}
  for _ = 1, 400 do
    local n = assert(rand.int(0, 3))
    seen[n] = true
  end
  for v = 0, 3 do
    assert(seen[v], "int(0, 3) never produced " .. v .. " in 400 draws")
  end
end
test_int_distribution_smoke()

local function test_int_wide_range()
  -- Multi-byte sampling path: range needs more than one random byte.
  local lo, hi = 0, 100000
  for _ = 1, 100 do
    local n = assert(rand.int(lo, hi))
    assert(n >= lo and n <= hi, "int(0, 100000) out of bounds: " .. n)
  end
end
test_int_wide_range()

local function test_int_invalid_args()
  -- Contract violations throw: a caller error is not a runtime
  -- failure, so it does not get a return slot.
  local ok, err = pcall(rand.int, 10, 1)
  assert(not ok, "min > max must throw")
  assert(tostring(err):match("min"), "expected min/max error, got: " .. tostring(err))

  ok = pcall(rand.int, 1.5 as integer, 3) -- cast: deliberate invalid input
  assert(not ok, "non-integer min must throw")

  ok, err = pcall(rand.int, math.mininteger, math.maxinteger)
  assert(not ok, "overflowing range must throw")
  assert(tostring(err):match("range"), "expected range error, got: " .. tostring(err))
end
test_int_invalid_args()

-- float

local function test_float_range()
  for _ = 1, 200 do
    local f = assert(rand.float())
    assert(f >= 0 and f < 1, "float() out of [0,1): " .. tostring(f))
    assert(math.type(f) == "float", "float() should return a float")
  end
end
test_float_range()

local function test_float_varies()
  local a = assert(rand.float())
  local b = assert(rand.float())
  assert(a ~= b, "two float() draws should differ")
end
test_float_varies()

-- choice

local function test_choice_picks_member()
  local list = {"a", "b", "c"}
  for _ = 1, 50 do
    local v = assert(rand.choice(list))
    assert(v == "a" or v == "b" or v == "c", "choice returned non-member: " .. tostring(v))
  end
end
test_choice_picks_member()

local function test_choice_covers_all()
  local seen: {string: boolean} = {}
  for _ = 1, 200 do
    seen[assert(rand.choice({"x", "y", "z"})) as string] = true -- cast: from any
  end
  assert(seen.x and seen.y and seen.z, "choice never produced some member in 200 draws")
end
test_choice_covers_all()

local function test_choice_single_and_empty()
  assert(rand.choice({42}) == 42, "single-element choice must return it")
  local v = rand.choice({})
  assert(v == nil, "empty list yields nil, the one nil this module returns")
end
test_choice_single_and_empty()

-- shuffle

local function test_shuffle_permutes()
  local list = {1, 2, 3, 4, 5, 6, 7, 8}
  local out = assert(rand.shuffle(list))
  assert(out == list, "shuffle should return the same list (in place)")
  assert(#out == 8, "shuffle must preserve length")
  local seen: {number: boolean} = {}
  for _, v in ipairs(out) do
    seen[v] = true
  end
  for v = 1, 8 do
    assert(seen[v], "shuffle lost element " .. v)
  end
end
test_shuffle_permutes()

local function test_shuffle_actually_shuffles()
  -- With 20 elements, 30 identity shuffles in a row is impossible in
  -- practice (P = (1/20!)^30).
  local moved = false
  for _ = 1, 30 do
    local list: {integer} = {}
    for i = 1, 20 do
      list[i] = i
    end
    assert(rand.shuffle(list as {any})) -- cast: widen {integer} to {any} param
    for i = 1, 20 do
      if list[i] ~= i then
        moved = true
      end
    end
    if moved then
      break
    end
  end
  assert(moved, "shuffle never changed the order")
end
test_shuffle_actually_shuffles()

local function test_shuffle_small()
  assert(#assert(rand.shuffle({})) == 0, "empty shuffle should be a no-op")
  local one = check.must(rand.shuffle({7}))
  assert(#one == 1 and one[1] == 7, "single-element shuffle should be a no-op")
end
test_shuffle_small()

-- token

local function test_token_default()
  local t = check.must(rand.token())
  assert(#t == 32, "default token length should be 32, got " .. #t)
  assert(t:match("^[%w]+$"), "token must be alphanumeric, got: " .. t)
end
test_token_default()

local function test_token_length_and_uniqueness()
  local t = assert(rand.token(8))
  assert(#t == 8, "token(8) length should be 8")
  local a = assert(rand.token(24))
  local b = assert(rand.token(24))
  assert(a ~= b, "two tokens should differ")
end
test_token_length_and_uniqueness()

local function test_token_invalid_length()
  local ok, err = pcall(rand.token, 0)
  assert(not ok, "token(0) must throw")
  assert(tostring(err):match("positive"), "got: " .. tostring(err))
end
test_token_invalid_length()

-- insecure_source

local function test_insecure_source_reproducible()
  local a = rand.insecure_source(42)
  local b = rand.insecure_source(42)
  for _ = 1, 20 do
    assert(a:int(1, 1000000) == b:int(1, 1000000),
      "same-seed Sources must produce identical int() draws")
  end
  for _ = 1, 20 do
    assert(a:float() == b:float(),
      "same-seed Sources must produce identical float() draws")
  end
end
test_insecure_source_reproducible()

local function test_insecure_source_differs_by_seed()
  local a = rand.insecure_source(1)
  local b = rand.insecure_source(2)
  local differed = false
  for _ = 1, 20 do
    if a:int(1, 1000000) ~= b:int(1, 1000000) then
      differed = true
      break
    end
  end
  assert(differed, "different seeds should not produce an identical sequence")
end
test_insecure_source_differs_by_seed()

local function test_insecure_source_independent_of_math_random()
  local a = rand.insecure_source(7)
  local a_draws: {integer} = {}
  for i = 1, 10 do
    a_draws[i] = a:int(1, 1000000)
  end

  local b = rand.insecure_source(7)
  local b_draws: {integer} = {}
  for i = 1, 10 do
    b_draws[i] = b:int(1, 1000000)
    for _ = 1, i do
      math.random()
    end
  end

  for i = 1, 10 do
    assert(a_draws[i] == b_draws[i],
      "Source draws must not depend on interleaved math.random() calls")
  end
end
test_insecure_source_independent_of_math_random()

local function test_insecure_source_int_bounds()
  local src = rand.insecure_source(99)
  for _ = 1, 500 do
    local n = src:int(-3, 7)
    assert(n >= -3 and n <= 7, "Source:int(-3, 7) out of bounds: " .. n)
    assert(math.type(n) == "integer", "Source:int should return an integer")
  end
end
test_insecure_source_int_bounds()

local function test_insecure_source_float_range()
  local src = rand.insecure_source(101)
  for _ = 1, 200 do
    local f = src:float()
    assert(f >= 0 and f < 1, "Source:float() out of [0,1): " .. tostring(f))
    assert(math.type(f) == "float", "Source:float() should return a float")
  end
end
test_insecure_source_float_range()
