local Time = require("cosmic.time")

local NS <const> = 1000000000

local function civil(year: integer, month: integer, day: integer, hour?: integer, minute?: integer,
    second?: integer, nanosecond?: integer): Time.Civil
  return { year = year, month = month, day = day, hour = hour or 0, minute = minute or 0,
    second = second or 0, nanosecond = nanosecond or 0 }
end

local function same_moment(got: Time.Civil, want: Time.Civil)
  local function text(c: Time.Civil): string
    return ("%d-%d-%d %d:%d:%d.%d"):format(c.year, c.month, c.day, c.hour, c.minute, c.second,
      c.nanosecond)
  end
  assert(text(got) == text(want), ("got %s, want %s"):format(text(got), text(want)))
end

local function test_civil_names_known_moments()
  same_moment(Time.civil(0), civil(1970, 1, 1))
  same_moment(Time.civil(951782400 * NS), civil(2000, 2, 29))
  same_moment(Time.civil(-1), civil(1969, 12, 31, 23, 59, 59, 999999999))
  same_moment(Time.civil(1790309361 * NS + 123), civil(2026, 9, 25, 4, 9, 21, 123))
  same_moment(Time.civil(-2208988800 * NS), civil(1900, 1, 1))
  same_moment(Time.civil(4107542400 * NS), civil(2100, 3, 1))
  same_moment(Time.civil(4107542400 * NS - 1), civil(2100, 2, 28, 23, 59, 59, 999999999))
end

local function test_civil_spans_every_integer()
  same_moment(Time.civil(math.mininteger), civil(1677, 9, 21, 0, 12, 43, 145224192))
  same_moment(Time.civil(math.maxinteger), civil(2262, 4, 11, 23, 47, 16, 854775807))
end

local function test_weekday_is_iso()
  assert(Time.civil(0).weekday == 4) -- 1970-01-01, a Thursday
  assert(Time.civil(-1).weekday == 3)
  assert(Time.civil(951782400 * NS).weekday == 2) -- 2000-02-29, a Tuesday
  assert(Time.civil(1790309361 * NS).weekday == 5) -- 2026-09-25, a Friday
  assert(assert(Time.from_civil(civil(2026, 9, 27))) // NS == 1790467200)
  assert(Time.civil(1790467200 * NS).weekday == 7) -- a Sunday
  assert(Time.civil(1790467200 * NS + 86400 * NS).weekday == 1)
  assert(Time.civil(-2208988800 * NS).weekday == 1) -- 1900-01-01, a Monday
end

local function test_yday_runs_from_one_to_the_years_length()
  local function yday(y: integer, m: integer, d: integer): integer
    return Time.civil((assert(Time.from_civil(civil(y, m, d))))).yday
  end
  assert(yday(2026, 1, 1) == 1)
  assert(yday(2026, 12, 31) == 365)
  assert(yday(2000, 12, 31) == 366)
  assert(yday(2000, 3, 1) == 61)
  assert(yday(1900, 3, 1) == 60)
  assert(yday(1969, 12, 31) == 365)
  assert(yday(1968, 12, 31) == 366)
end

local function test_leap_years_follow_the_gregorian_rule()
  assert(Time.from_civil(civil(2000, 2, 29)))
  assert(Time.from_civil(civil(2024, 2, 29)))
  local v, why = Time.from_civil(civil(1900, 2, 29))
  assert(v == nil and why:find("day 29", 1, true), why)
  v, why = Time.from_civil(civil(2100, 2, 29))
  assert(v == nil and why ~= "", why)
  v, why = Time.from_civil(civil(2026, 2, 29))
  assert(v == nil and why ~= "", why)
end

local function test_from_civil_inverts_civil()
  for _, ns in ipairs({ 0, -1, 1, math.mininteger, math.maxinteger, 951782400 * NS,
      -2208988800 * NS - 7, 4107542400 * NS - 1, 1790309361 * NS + 500000000 }) do
    local back, why = Time.from_civil(Time.civil(ns))
    assert(back == ns, ("%d came back as %s: %s"):format(ns, tostring(back), why))
  end
end

local function test_from_civil_refuses_fields_out_of_range()
  for _, c in ipairs({
    civil(2026, 13, 1), civil(2026, 0, 1), civil(2026, 2, 30), civil(2026, 4, 31),
    civil(2026, 1, 0), civil(2026, 1, 1, 24), civil(2026, 1, 1, -1), civil(2026, 1, 1, 0, 60),
    civil(2026, 1, 1, 0, 0, 60), civil(2026, 1, 1, 0, 0, 0, NS), civil(2026, 1, 1, 0, 0, 0, -1),
  }) do
    local v, why = Time.from_civil(c)
    assert(v == nil and why ~= "", tostring(v))
  end
  local float_year = civil(2026, 1, 1)
  float_year.year = 2026.0 as integer
  local fv, fwhy = Time.from_civil(float_year)
  assert(fv == nil and fwhy:find("year is not an integer: float", 1, true), fwhy)
  local c = civil(2026, 1, 1)
  c.month = nil
  local v, why = Time.from_civil(c)
  assert(v == nil and why:find("month", 1, true), why)
end

local function test_from_civil_refuses_what_an_integer_cannot_hold()
  local edges: {{Time.Civil, boolean}} = {
    { civil(1677, 9, 21, 0, 12, 43, 145224192), true },
    { civil(1677, 9, 21, 0, 12, 43, 145224191), false },
    { civil(2262, 4, 11, 23, 47, 16, 854775807), true },
    { civil(2262, 4, 11, 23, 47, 17), false },
    { civil(1600, 1, 1), false },
    { civil(3000, 1, 1), false },
    { civil(math.maxinteger, 1, 1), false },
    { civil(math.mininteger, 1, 1), false },
  }
  for _, e in ipairs(edges) do
    local v, why = Time.from_civil(e[1])
    assert((v ~= nil) == e[2], why)
    if not e[2] then assert(why:find("outside", 1, true), why) end
  end
  assert(Time.from_civil(edges[1][1]) == math.mininteger)
  assert(Time.from_civil(edges[3][1]) == math.maxinteger)
end

local function test_format_writes_a_fraction_only_when_there_is_one()
  assert(Time.format_rfc3339(0) == "1970-01-01T00:00:00Z")
  assert(Time.format_rfc3339(1790309361 * NS) == "2026-09-25T04:09:21Z")
  assert(Time.format_rfc3339(1790309361 * NS + 500000000) == "2026-09-25T04:09:21.5Z")
  assert(Time.format_rfc3339(1790309361 * NS + 1000) == "2026-09-25T04:09:21.000001Z")
  assert(Time.format_rfc3339(-1) == "1969-12-31T23:59:59.999999999Z")
  assert(Time.format_rfc3339(math.mininteger) == "1677-09-21T00:12:43.145224192Z")
  assert(Time.format_rfc3339(math.maxinteger) == "2262-04-11T23:47:16.854775807Z")
end

local function test_format_digits_fix_the_fraction_cut_toward_the_past()
  assert(Time.format_rfc3339(0, { digits = 3 }) == "1970-01-01T00:00:00.000Z")
  assert(Time.format_rfc3339(-1, { digits = 3 }) == "1969-12-31T23:59:59.999Z")
  assert(Time.format_rfc3339(-1, { digits = 0 }) == "1969-12-31T23:59:59Z")
  assert(Time.format_rfc3339(123456789, { digits = 9 }) == "1970-01-01T00:00:00.123456789Z")
  for _, digits in ipairs({ -1, 10 }) do
    local ok, err = pcall(Time.format_rfc3339, 0, { digits = digits })
    assert(not ok and tostring(err):find("digits", 1, true), tostring(err))
  end
end

local function test_parse_reads_offsets_and_fractions()
  local base = 1790309361 * NS
  local cases: {string: integer} = {
    ["2026-09-25T04:09:21Z"] = base,
    ["2026-09-25t04:09:21z"] = base,
    ["2026-09-25T04:09:21.5Z"] = base + 500000000,
    ["2026-09-25T04:09:21.000000001Z"] = base + 1,
    ["2026-09-25T09:39:21+05:30"] = base,
    ["2026-09-24T20:09:21-08:00"] = base,
    ["2026-09-25T04:09:21-00:00"] = base,
    ["1970-01-01T00:00:00Z"] = 0,
    ["1969-12-31T23:59:59.999999999Z"] = -1,
    ["2000-02-29T00:00:00Z"] = 951782400 * NS,
    -- Offsets that cross a day and a year.
    ["2027-01-01T01:00:00+02:00"] = (assert(Time.from_civil(civil(2026, 12, 31, 23)))),
    ["2026-12-31T23:30:00-01:00"] = (assert(Time.from_civil(civil(2027, 1, 1, 0, 30)))),
    ["2000-03-01T00:00:00+00:01"] = (assert(Time.from_civil(civil(2000, 2, 29, 23, 59)))),
    -- The edges, reached through an offset from a year past them.
    ["1677-09-20T23:12:43.145224192-01:00"] = math.mininteger,
    ["2262-04-12T00:47:16.854775807+01:00"] = math.maxinteger,
  }
  for text, want in pairs(cases) do
    local got, why = Time.parse_rfc3339(text)
    assert(got == want, ("%s: got %s, want %d: %s"):format(text, tostring(got), want, why))
  end
end

local function test_parse_says_there_are_no_leap_seconds()
  local got, why = Time.parse_rfc3339("2026-09-25T04:09:60Z")
  assert(got == nil and why:find("second 60 is not 0 through 59", 1, true), why)
end

local function test_parse_refuses_what_rfc3339_does_not_say()
  for _, text in ipairs({
    "", "2026-09-25", "2026-09-25T04:09:21", "2026-09-25 04:09:21Z", "2026-09-25T04:09Z",
    "26-09-25T04:09:21Z", "+2026-09-25T04:09:21Z", "2026-9-25T04:09:21Z", "2026-09-25T4:09:21Z",
    "2026-13-25T04:09:21Z", "2026-02-29T04:09:21Z", "2026-09-31T04:09:21Z",
    "2026-09-25T24:00:00Z", "2026-09-25T04:60:21Z", "2026-09-25T23:59:60Z",
    "2026-09-25T04:09:21.Z", "2026-09-25T04:09:21.0000000001Z", "2026-09-25T04:09:21,5Z",
    "2026-09-25T04:09:21+0530", "2026-09-25T04:09:21+05", "2026-09-25T04:09:21+24:00",
    "2026-09-25T04:09:21+05:60", "2026-09-25T04:09:21Z ", "2026-09-25T04:09:21ZZ",
    " 2026-09-25T04:09:21Z", "2026-09-25T04:09:21UTC", "2026-09-25T04:09:21+05:30x",
    "0000-01-01T00:00:00Z", "9999-12-31T23:59:59Z", "2262-04-11T23:47:17Z",
    "1677-09-21T00:12:43.145224191Z", "2026-09-25T04:09:21\0Z", "2026-09-25T04:09:2aZ",
  }) do
    local got, why = Time.parse_rfc3339(text)
    assert(got == nil and why ~= "", ("%q: got %s"):format(text, tostring(got)))
  end
end
