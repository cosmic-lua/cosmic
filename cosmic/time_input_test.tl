--- `Time.parse_duration`, `Time.format_duration` and `Time.parse_input`,
--- the readers of what a person types that `cosmic time` uses. The fuzz
--- properties are in time_input_fuzz_test.tl.

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
  assert(d.nanoseconds == (4 * 3600 + 5 * 60 + 6) * NS, d.nanoseconds)
  assert(duration("90m").nanoseconds == 90 * 60 * NS)
  assert(duration("0.5s").nanoseconds == NS // 2)
  assert(duration("1mo").months == 1 and duration("1m").months == 0, "mo is months, m minutes")
  assert(duration("+2d").days == 2)
end

local function test_a_negative_duration_negates_every_field()
  local d = duration("-1y2mo3d4h5m6.25s")
  assert(d.years == -1 and d.months == -2 and d.days == -3, "calendar part")
  assert(d.nanoseconds == -((4 * 3600 + 5 * 60 + 6) * NS + 250000000), d.nanoseconds)
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

local function test_an_input_reads_every_form()
  local utc = assert(Time.zone("UTC"))
  local z = assert(Time.parse_input("2026-03-08T12:00:00Z", utc))
  assert(z.ns == 1772971200 * NS and z.zone == Time.UTC, z.ns)
  local offset = assert(Time.parse_input("2026-03-08T12:00:00+05:30", utc))
  assert(offset.ns == (1772971200 - 19800) * NS and offset.zone.name == "+05:30")
  local named = assert(Time.parse_input("2026-03-08T12:00:00-04:00[America/New_York]", utc))
  assert(named.zone.name == "America/New_York")
  local epoch = assert(Time.parse_input("@1772971200", utc))
  assert(epoch.ns == 1772971200 * NS and epoch.zone == nil)
  assert((assert(Time.parse_input("@-1.5", utc))).ns == -1500000000)
  assert((assert(Time.parse_input("@0.000000001", utc))).ns == 1)
  local date = assert(Time.parse_input("2026-03-08", (assert(Time.zone("Asia/Tokyo")))))
  assert(date.ns == (1772971200 - 12 * 3600 - 9 * 3600) * NS, date.ns)
  local wall = assert(Time.parse_input("2026-03-08T12:00", utc))
  assert(wall.ns == 1772971200 * NS)
  assert((assert(Time.parse_input("2026-03-08T12:00:30.25", utc))).ns == (1772971230 * NS + 250000000))
end

local function test_a_gap_and_an_overlap_are_resolved_as_asked()
  local ny = assert(Time.zone("America/New_York"))
  local function read(text: string, how?: Time.Disambiguation): integer | nil, string
    local got, why = Time.parse_input(text, ny, how and { disambiguation = how } or nil)
    if got == nil then return nil, why end
    return got.ns, ""
  end
  local function hour(ns: integer): string
    return Time.format_rfc3339(ns, { zone = ny })
  end
  -- 2026-03-08 02:30 does not exist: clocks went 02:00 EST to 03:00 EDT.
  assert(hour((assert(read("2026-03-08T02:30")))) == "2026-03-08T03:30:00-04:00")
  assert(hour((assert(read("2026-03-08T02:30", "later")))) == "2026-03-08T03:30:00-04:00")
  assert(hour((assert(read("2026-03-08T02:30", "earlier")))) == "2026-03-08T01:30:00-05:00")
  local none, why = read("2026-03-08T02:30", "reject")
  assert(none == nil and why:find("does not exist", 1, true), why)
  -- 2026-11-01 01:30 happens twice: EDT, then EST.
  assert(hour((assert(read("2026-11-01T01:30")))) == "2026-11-01T01:30:00-04:00")
  assert(hour((assert(read("2026-11-01T01:30", "earlier")))) == "2026-11-01T01:30:00-04:00")
  assert(hour((assert(read("2026-11-01T01:30", "later")))) == "2026-11-01T01:30:00-05:00")
  local twice, twice_why = read("2026-11-01T01:30", "reject")
  assert(twice == nil and twice_why:find("happens twice", 1, true), twice_why)
end

local function test_a_bad_input_is_refused_naming_the_forms()
  for _, text in ipairs({ "", "yesterday", "2026-13-01", "2026-02-30", "2026-03-08T25:00", "@", "@x", "@1.",
      "@9999999999999", "2026-03-08T12:00:60", "2026-03-08T12:00:00.1234567890", "2026-03-08 12:00" }) do
    local got, why = Time.parse_input(text)
    assert(got == nil and why ~= "", ("%q read as a time"):format(text))
  end
  local _, why = Time.parse_input("yesterday")
  assert(why:find("RFC 3339", 1, true) and why:find("@<epoch", 1, true), why)
end
