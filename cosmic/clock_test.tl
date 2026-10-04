local Clock = require("cosmic.clock")

local NS <const> = 1000000000

local function test_the_constructors_scale_a_count_to_nanoseconds()
  assert(Clock.ms(1) == 1000000 and Clock.seconds(1) == NS and Clock.minutes(1) == 60 * NS)
  assert(Clock.hours(1) == 3600 * NS and Clock.ms(0) == 0 and Clock.ms(-5) == -5000000)
  -- A float is as good as an integer when the span is whole, and is answered as one.
  assert(Clock.ms(1.5) == 1500000 and math.type(Clock.ms(1.5)) == "integer")
  assert(Clock.seconds(0.25) == 250000000 and Clock.minutes(1.5) == 90 * NS)
  assert(Clock.hours(0.5) == 1800 * NS and Clock.hours(2.0) == 7200 * NS)
  assert(Clock.hours(24) == Clock.seconds(86400) and Clock.minutes(60) == Clock.hours(1))
  -- Float rounding in the product is no refusal: a count whose span is whole to within it.
  assert(Clock.seconds(1.005) == 1005000000 and Clock.seconds(1.1) == 1100000000)
  assert(Clock.seconds(0.1 + 0.2) == 300000000 and Clock.ms(0.1 + 0.2) == 300000)
  assert(Clock.minutes(0.1) == 6 * NS and Clock.hours(1 / 3) == 1200 * NS)
  -- The largest count each takes.
  assert(Clock.seconds(math.maxinteger // NS) == math.maxinteger // NS * NS)
  assert(Clock.ms(-(math.maxinteger // 1000000)) == -(math.maxinteger // 1000000) * 1000000)
end

local function test_the_constructors_refuse_what_is_no_span_an_integer_holds()
  local constructors: {string:function(number): integer} = {
    ["Clock.ms"] = Clock.ms, ["Clock.seconds"] = Clock.seconds, ["Clock.minutes"] = Clock.minutes,
    ["Clock.hours"] = Clock.hours,
  }
  for name, make in pairs(constructors) do
    for _, bad in ipairs({ 1e-12, 0 / 0, math.huge, -math.huge,
        math.maxinteger, math.mininteger + 1, 2 ^ 62 } as {number}) do
      local ok, err = pcall(make, bad)
      assert(not ok and tostring(err):find(name, 1, true), name .. " " .. tostring(bad))
    end
    local text: any = "5"
    local ok, err = pcall(make, text as number)
    assert(not ok and tostring(err):find("takes a number, not string", 1, true), tostring(err))
  end
  local ok, err = pcall(Clock.ms, 0.0000001)
  assert(not ok and tostring(err):find("not a whole number of nanoseconds", 1, true), tostring(err))
  ok, err = pcall(Clock.seconds, math.maxinteger // NS + 1)
  assert(not ok and tostring(err):find("outside what an integer", 1, true), tostring(err))
end

--- A span as the count of a unit that covers it: rounded up, so a span
--- that is not none is never counted as none, whatever its sign.
local function test_ceil_rounds_a_span_up_to_a_count_of_the_unit()
  local ms = Clock.ms(1)
  assert(Clock.ceil(0, ms) == 0 and Clock.ceil(1, ms) == 1 and Clock.ceil(ms, ms) == 1)
  assert(Clock.ceil(ms + 1, ms) == 2 and Clock.ceil(Clock.ms(7), ms) == 7)
  assert(Clock.ceil(-1, ms) == 0 and Clock.ceil(-ms, ms) == -1 and Clock.ceil(-ms - 1, ms) == -1)
  assert(Clock.ceil(math.maxinteger, ms) == math.maxinteger // ms + 1)
  assert(Clock.ceil(math.mininteger, ms) == math.mininteger // ms + 1)
  assert(Clock.ceil(math.maxinteger, 1) == math.maxinteger and Clock.ceil(math.mininteger, 1) == math.mininteger)
  assert(Clock.ceil(Clock.ms(1500), Clock.seconds(1)) == 2)
  for _, bad in ipairs({ 0, -1 }) do
    local ok, why = pcall(Clock.ceil, 1, bad)
    assert(not ok and tostring(why):find("unit must be", 1, true), tostring(why))
  end
  local ok, why = pcall(Clock.ceil, 1.5 as integer, ms)
  assert(not ok and tostring(why):find("ns must be an integer", 1, true), tostring(why))
end

local function test_the_clocks_read_and_the_monotonic_one_does_not_go_back()
  local before = Clock.monotonic_ns()
  assert(Clock.sleep_ns(Clock.ms(1)))
  local after = Clock.monotonic_ns()
  assert(after - before >= Clock.ms(1), tostring(after - before))
  -- 2020-09-13 in nanoseconds: any host's wall clock is past it.
  assert(Clock.now_ns() > 1600000000 * NS)
end

local function test_sleep_ns_refuses_a_negative_span()
  local ok = pcall(Clock.sleep_ns, -1)
  assert(not ok)
end
