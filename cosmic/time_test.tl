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

--- The nanoseconds `text` names, which must parse.
local function at(text: string): integer
  return (assert(Time.parse_rfc3339(text)))
end

local function test_add_calendar_moves_years_months_then_days()
  local from = at("2024-01-31T10:20:30.5Z")
  local cases: {{Time.Change, string, string}} = {
    { { days = 1 }, "reject", "2024-02-01T10:20:30.5Z" },
    { { days = -31 }, "reject", "2023-12-31T10:20:30.5Z" },
    { { months = 2 }, "reject", "2024-03-31T10:20:30.5Z" },
    { { months = 1 }, "clamp", "2024-02-29T10:20:30.5Z" },
    { { years = 1, months = 1 }, "clamp", "2025-02-28T10:20:30.5Z" },
    { { months = -13 }, "reject", "2022-12-31T10:20:30.5Z" },
    -- The month first, then the day: February 29, then March 1.
    { { months = 1, days = 1 }, "clamp", "2024-03-01T10:20:30.5Z" },
    { {}, "reject", "2024-01-31T10:20:30.5Z" },
  }
  for _, case in ipairs(cases) do
    local moved = assert(Time.add_calendar(from, case[1], { overflow = case[2] as Time.Overflow }))
    assert(Time.format_rfc3339(moved) == case[3], Time.format_rfc3339(moved) .. " not " .. case[3])
  end
  local leap_day = at("2024-02-29T00:00:00Z")
  assert(Time.format_rfc3339((assert(Time.add_calendar(leap_day, { years = 4 })))) ==
    "2028-02-29T00:00:00Z")
  local clamped = assert(Time.add_calendar(leap_day, { years = 1 }, { overflow = "clamp" }))
  assert(Time.format_rfc3339(clamped) == "2025-02-28T00:00:00Z")
end

local function test_add_calendar_refuses_a_day_its_month_lacks_by_default()
  local none, why = Time.add_calendar(at("2024-01-31T00:00:00Z"), { months = 1 })
  assert(none == nil and why == "2024-02 has no day 31; overflow \"clamp\" takes its last", why)
  none, why = Time.add_calendar(at("2024-02-29T00:00:00Z"), { years = 1 }, { overflow = "reject" })
  assert(none == nil and why:find("2025-02 has no day 29", 1, true) ~= nil, why)
  -- A step past the range on the way is not refused: the result is what counts.
  local back = assert(Time.add_calendar(at("2262-01-01T00:00:00Z"), { years = 10, days = -3652 }))
  assert(Time.format_rfc3339(back) == "2262-01-01T00:00:00Z", Time.format_rfc3339(back))
  assert(not pcall(Time.add_calendar, 0, { days = 1 }, { overflow = "Clamp" as Time.Overflow }))
  none, why = Time.add_calendar(at("2262-01-01T00:00:00Z"), { years = 1 })
  assert(none == nil and why:find("outside", 1, true) ~= nil, why)
  none, why = Time.add_calendar(at("1678-01-01T00:00:00Z"), { days = -200 })
  assert(none == nil and why:find("outside", 1, true) ~= nil, why)
  none, why = Time.add_calendar(0, { months = 1.5 as integer })
  assert(none == nil and why:find("months is not an integer", 1, true) ~= nil, why)
  none, why = Time.add_calendar(0, { years = math.maxinteger })
  assert(none == nil and why:find("years", 1, true) ~= nil, why)
end

local function test_days_between_counts_dates_not_hours()
  assert(Time.days_between(at("2024-03-01T23:59:59Z"), at("2024-03-02T00:00:00Z")) == 1)
  assert(Time.days_between(at("2024-03-02T00:00:00Z"), at("2024-03-01T23:59:59Z")) == -1)
  assert(Time.days_between(at("2024-01-01T00:00:00Z"), at("2025-01-01T00:00:00Z")) == 366)
  assert(Time.days_between(at("1969-12-31T23:59:59.9Z"), at("1970-01-01T00:00:00Z")) == 1)
  assert(Time.days_between(0, 0) == 0)
end

local function test_months_between_counts_whole_months()
  local cases: {{string, string, integer}} = {
    { "2024-01-31T00:00:00Z", "2024-02-29T00:00:00Z", 0 },
    { "2024-01-31T00:00:00Z", "2024-03-31T00:00:00Z", 2 },
    { "2024-01-15T12:00:00Z", "2024-02-15T11:59:59Z", 0 },
    { "2024-01-15T12:00:00Z", "2024-02-15T12:00:00Z", 1 },
    { "2000-02-29T00:00:00Z", "2026-02-28T00:00:00Z", 311 },
    { "2024-03-15T00:00:00Z", "2024-01-16T00:00:00Z", -1 },
    { "2024-03-15T00:00:00Z", "2024-01-15T00:00:00Z", -2 },
    { "1969-12-31T23:59:59Z", "1970-01-31T23:59:59Z", 1 },
    -- Java's own answers, where the time of day and a shorter month meet.
    { "2024-01-31T12:00:00Z", "2024-03-01T06:00:00Z", 0 },
    { "2000-12-29T23:59:59.999Z", "2001-03-01T00:00:00Z", 1 },
    { "2024-02-29T12:00:00Z", "2023-02-28T23:59:59.999Z", -11 },
    { "2239-04-30T06:00:00Z", "2239-02-28T11:02:00Z", -1 },
    { "1969-05-31T00:00:00Z", "1969-02-28T12:00:00Z", -2 },
  }
  for _, case in ipairs(cases) do
    local got = Time.months_between(at(case[1]), at(case[2]))
    assert(got == case[3], case[1] .. " to " .. case[2] .. ": " .. got)
  end
  -- A birthday's years: whole months over 12 (a count that is not
  -- negative, so // truncates as it floors).
  local age = Time.months_between(at("1990-06-15T00:00:00Z"), at("2026-06-14T00:00:00Z")) // 12
  assert(age == 35, tostring(age))
end

local function test_format_date_is_the_utc_date()
  assert(Time.format_date(0) == "1970-01-01")
  assert(Time.format_date(-1) == "1969-12-31")
  assert(Time.format_date(951782400 * NS + 86399 * NS) == "2000-02-29")
  assert(Time.format_date(math.mininteger) == "1677-09-21")
  assert(Time.format_date(math.maxinteger) == "2262-04-11")
end

local function test_parse_date_is_its_midnight()
  assert(Time.parse_date("1970-01-01") == 0)
  assert(Time.parse_date("2000-02-29") == 951782400 * NS)
  assert(Time.parse_date("1969-12-31") == -86400 * NS)
  assert(Time.parse_date("1677-09-22") == (math.mininteger // NS // 86400 + 1) * 86400 * NS)
  assert(Time.parse_date("2262-04-11") == math.maxinteger // NS // 86400 * 86400 * NS)
end

local function test_parse_date_refuses_what_is_not_a_date()
  for _, text in ipairs({
    "", "2026-09-25T00:00:00Z", "2026-09-25 ", " 2026-09-25", "2026-9-25", "26-09-25",
    "2026/09/25", "2026-02-29", "1900-02-29", "2026-13-01", "2026-00-01", "2026-09-00",
    "2026-09-31", "1677-09-21", "2262-04-12", "0000-01-01", "9999-12-31", "2026-09-2a",
  }) do
    local got, why = Time.parse_date(text)
    assert(got == nil and why ~= "", ("%q: got %s"):format(text, tostring(got)))
  end
end

local function test_format_http_is_imf_fixdate()
  assert(Time.format_http(784111777 * NS) == "Sun, 06 Nov 1994 08:49:37 GMT")
  assert(Time.format_http(1790313741 * NS + 999999999) == "Fri, 25 Sep 2026 05:22:21 GMT")
  assert(Time.format_http(-1) == "Wed, 31 Dec 1969 23:59:59 GMT")
  assert(Time.format_http(math.maxinteger) == "Fri, 11 Apr 2262 23:47:16 GMT")
end

local function test_parse_http_reads_rfc_9110s_three_forms()
  for _, text in ipairs({
    "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT",
    "Sun Nov  6 08:49:37 1994", "Sun Nov 06 08:49:37 1994",
  }) do
    local got, why = Time.parse_http(text)
    assert(got == 784111777 * NS, ("%s: got %s: %s"):format(text, tostring(got), why))
  end
  assert(Time.parse_http("Fri, 25 Sep 2026 05:22:21 GMT") == 1790313741 * NS)
  assert(Time.parse_http("Fri Sep 25 05:22:21 2026") == 1790313741 * NS)
  assert(Time.parse_http("Wednesday, 31-Dec-69 23:59:59 GMT") == -NS)
  assert(Time.parse_http("Thursday, 01-Jan-70 00:00:00 GMT") == 0)
end

local function test_parse_http_reads_two_digit_years_as_posix_does()
  local function year(text: string): integer
    return Time.civil((assert(Time.parse_http(text)))).year
  end
  assert(year("Wednesday, 01-Jan-69 00:00:00 GMT") == 1969)
  assert(year("Friday, 31-Dec-99 00:00:00 GMT") == 1999)
  assert(year("Saturday, 01-Jan-00 00:00:00 GMT") == 2000)
  assert(year("Monday, 31-Dec-68 00:00:00 GMT") == 2068)
end

local function test_parse_http_reads_the_date_whatever_its_weekday_name()
  for _, text in ipairs({
    "Mon, 26 Jul 1997 05:00:00 GMT", "Monday, 26-Jul-97 05:00:00 GMT", "Mon Jul 26 05:00:00 1997",
  }) do
    local got, why = Time.parse_http(text)
    assert(got == 869893200 * NS, ("%s: got %s: %s"):format(text, tostring(got), why))
  end
  for _, text in ipairs({
    "Mox, 26 Jul 1997 05:00:00 GMT", "Mon., 26 Jul 1997 05:00:00 GMT",
    "Monday, 26 Jul 1997 05:00:00 GMT", "Mon, 26-Jul-97 05:00:00 GMT",
    "Mond, 26-Jul-97 05:00:00 GMT", "mon Jul 26 05:00:00 1997", "Monday Jul 26 05:00:00 1997",
  }) do
    local got, why = Time.parse_http(text)
    assert(got == nil and why ~= "", ("%q: got %s"):format(text, tostring(got)))
  end
end

local function test_parse_http_refuses_what_rfc_9110_does_not_say()
  for _, text in ipairs({
    "", "Sun", "Sun,", "Sun, 06 Nov 1994 08:49:37", "Sun, 06 Nov 1994 08:49:37 UTC",
    "Sun, 06 Nov 1994 08:49:37 GMT ", " Sun, 06 Nov 1994 08:49:37 GMT",
    "Sun, 6 Nov 1994 08:49:37 GMT", "Sun, 06 nov 1994 08:49:37 GMT", "sun, 06 Nov 1994 08:49:37 GMT",
    "Sun, 06 Nov 94 08:49:37 GMT", "Sun, 06 Nov 1994 8:49:37 GMT", "Sun, 06-Nov-1994 08:49:37 GMT",
    "Sun,  06 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 08:49:37 +0000",
    "Sun, 06 Nov 1994 24:00:00 GMT", "Sun, 06 Nov 1994 08:60:37 GMT",
    "Sun, 06 Nov 1994 08:49:60 GMT", "Sun, 31 Nov 1994 08:49:37 GMT",
    "Sun, 2026-09-25T04:09:21Z", "2026-09-25T04:09:21Z", "Sunday, 06 Nov 1994 08:49:37 GMT",
    "Sun, 06-Nov-94 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37", "Sunday, 6-Nov-94 08:49:37 GMT",
    "Sundays, 06-Nov-94 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMTx",
    "Sun Nov 6 08:49:37 1994", "Sun Nov  6 08:49:37 94", "Sun Nov  6 08:49:37 1994 ",
    "Sun Nov  6 08:49:37 1994 GMT", "Sun  Nov 6 08:49:37 1994", "Sun Nov  x 08:49:37 1994",
    "Tue, 21 Sep 1677 00:12:43 GMT", "Sat, 12 Apr 2262 00:00:00 GMT",
    "Sat, 01 Jan 0000 00:00:00 GMT",
  }) do
    local got, why = Time.parse_http(text)
    assert(got == nil and why ~= "", ("%q: got %s"):format(text, tostring(got)))
  end
end

local function test_parse_http_reaches_the_ranges_edges()
  assert(Time.parse_http("Fri, 11 Apr 2262 23:47:16 GMT") == math.maxinteger - math.maxinteger % NS)
  assert(Time.parse_http("Tue, 21 Sep 1677 00:12:44 GMT") == (math.mininteger // NS + 1) * NS)
end
