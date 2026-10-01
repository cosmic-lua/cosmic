--- [`Time.parse_duration`] and [`Time.format_duration`], a [`Time.Duration`]'s
--- text. The fuzz properties are in time_duration_fuzz_test.tl.

local Time = require("cosmic.time")

local NS <const> = 1000000000

local function duration(text: string): Time.Duration
  local d, why = Time.parse_duration(text)
  if d == nil then error(why) end
  return d
end

local function test_a_duration_reads_each_unit()
  local d = duration("1y2mo3d4h5m6s")
  assert(d.years == 1 and d.months == 2 and d.days == 3, "calendar part")
  assert(d.ns == (4 * 3600 + 5 * 60 + 6) * NS, d.ns)
  assert(duration("90m").ns == 90 * 60 * NS)
  assert(duration("0.5s").ns == NS // 2)
  assert(duration("1mo").months == 1 and duration("1m").months == 0, "mo is months, m minutes")
  assert(duration("+2d").days == 2)
end

local function test_a_negative_duration_negates_every_field()
  local d = duration("-1y2mo3d4h5m6.25s")
  assert(d.years == -1 and d.months == -2 and d.days == -3, "calendar part")
  assert(d.ns == -((4 * 3600 + 5 * 60 + 6) * NS + 250000000), d.ns)
end

local function test_a_bad_duration_is_refused_with_a_reason()
  for _, text in ipairs({ "", "-", "1", "y", "1x", "1d1y", "1d1d", "1.5m", "1.s", "1.1234567890s",
      "1 d", "1d ", "9999999999d", "99999999h99999999m", "-+1d", "1mo2mo" }) do
    local d, why = Time.parse_duration(text)
    assert(d == nil and why ~= "", ("%q read as a duration"):format(text))
  end
end

local function test_a_duration_writes_the_text_it_reads()
  assert(Time.format_duration(duration("1y2mo3d4h5m6s")) == "1y2mo3d4h5m6s")
  assert(Time.format_duration(duration("-90m")) == "-1h30m")
  assert(Time.format_duration(duration("0s")) == "0s")
  assert(Time.format_duration({ months = 14 }) == "14mo")
  assert(Time.format_duration(duration("1.500s")) == "1.5s")
  assert(not pcall(Time.format_duration, { days = 1, months = -1 }), "mixed signs")
end
