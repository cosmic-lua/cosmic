--- Fuzz properties for [`cosmic.time`]'s RFC 3339 text: what
--- `format_rfc3339` writes, in UTC or moved to any offset, parses back
--- to the moment it came from; and `parse_rfc3339` is total -- whatever
--- bytes it is handed, it answers a moment or a failure and never
--- raises, and a moment it accepts formats back to text naming the same
--- one. The same holds for the date-only text and the HTTP dates, in
--- all three of RFC 9110's forms. `between` answers a duration of one
--- sign for any two moments in any zone, which text round trips, and in
--- a zone whose offset is fixed `add_calendar` adds back to the second
--- moment. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Time = require("cosmic.time")

local NS <const> = 1000000000

--- A moment, anywhere in an integer's range: its seconds and
--- nanoseconds drawn apart, so shrinking lowers each toward the range's
--- start.
local function gen_moment(src: Fuzz.Source): integer
  if src:int(0, 3) == 0 then
    return Fuzz.pick(src, { math.mininteger, math.maxinteger, 0, -1, 1, 951782400 * NS })
  end
  local s = src:int(math.mininteger // NS + 1, math.maxinteger // NS - 1)
  local n = src:int(0, 2) == 0 and 0 or src:int(0, NS - 1)
  return s * NS + n
end

--- A moment, an offset in minutes east of UTC, and the fraction's
--- digits (-1 for the default), packed as the input.
local function gen_stamp(src: Fuzz.Source): string
  return string.pack("<i8i4i1", gen_moment(src), src:int(-1439, 1439), src:int(-1, 9))
end

--- `ns` as RFC 3339 text `minutes` east of UTC, or nil when the local
--- clock reading is outside what an integer holds.
local function at_offset(ns: integer, minutes: integer, opts: Time.FormatOptions): string
  local shift = minutes * 60 * NS
  if (shift > 0 and ns > math.maxinteger - shift) or (shift < 0 and ns < math.mininteger - shift) then
    return nil
  end
  local sign = minutes < 0 and "-" or "+"
  local text = Time.format_rfc3339(ns + shift, nil, opts)
  return text:sub(1, -2) .. ("%s%02d:%02d"):format(sign, math.abs(minutes) // 60, math.abs(minutes) % 60)
end

local function round_trips(input: string): boolean, string
  local ns, minutes, digits = string.unpack("<i8i4i1", input)
  local opts: Time.FormatOptions = digits >= 0 and { digits = digits } or nil
  local want = ns
  if digits >= 0 then
    local unit = 1
    for _ = digits + 1, 9 do unit = unit * 10 end
    if ns < math.mininteger + ns % unit then
      -- Cut toward the past, the range's first second names a moment
      -- before it, which parse refuses.
      Fuzz.label("cut before the range")
      want = nil
    else
      want = ns - ns % unit
    end
    if want ~= ns then Fuzz.label("cut") end
  end
  local utc = Time.format_rfc3339(ns, nil, opts)
  local back, why = Time.parse_rfc3339(utc)
  if back ~= want then
    return false, ("%d wrote %s, which parsed as %s: %s"):format(ns, utc, tostring(back), why)
  end
  local moved = at_offset(ns, minutes, opts)
  if moved ~= nil and want ~= nil then
    Fuzz.label("offset")
    back, why = Time.parse_rfc3339(moved)
    if back ~= want then
      return false, ("%d wrote %s, which parsed as %s: %s"):format(ns, moved, tostring(back), why)
    end
  end
  return true, ""
end

local function test_format_then_parse_is_the_same_moment(tmp: string)
  Fuzz.run({
    name = "rfc3339 round trip",
    dir = tmp,
    gen = gen_stamp,
    check = round_trips,
    requires = { "offset", "cut" },
  })
end

--- Timestamps to mutate: every form the grammar allows, and the range's
--- edges.
local SAMPLES <const> = {
  "2026-09-25T04:09:21Z", "2026-09-25t04:09:21.5z", "2026-09-25T09:39:21.000000001+05:30",
  "1969-12-31T23:59:59.999999999-08:00", "2000-02-29T00:00:00-00:00",
  "1677-09-21T00:12:43.145224192Z", "2262-04-11T23:47:16.854775807Z",
}

local function parse_holds(input: string): boolean, string
  local ok, ns, why = pcall(Time.parse_rfc3339, input)
  if not ok then return false, "raised: " .. tostring(ns) end
  if ns == nil then
    Fuzz.label("refused")
    if why == "" then return false, "refused without a reason" end
    return true, ""
  end
  Fuzz.label("parsed")
  if why ~= "" then return false, "parsed with a reason: " .. why end
  local again, again_why = Time.parse_rfc3339(Time.format_rfc3339(ns))
  if again ~= ns then
    return false, ("%q parsed as %d, whose text parsed as %s: %s"):format(input, ns,
      tostring(again), again_why)
  end
  return true, ""
end

local function test_parse_is_total(tmp: string)
  Fuzz.run({
    name = "rfc3339 parse total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      if src:int(0, 3) == 0 then return Fuzz.bytes(src, 40) end
      return Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), 3)
    end,
    check = parse_holds,
    requires = { "parsed", "refused" },
  })
end

local DAY_NS <const> = 86400 * NS
local MONTHS <const> = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
  "Nov", "Dec" }
local DAYS <const> = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  "Sunday" }

--- `ns` cut toward the past to a multiple of `unit`, or nil when that
--- is before the range.
local function cut(ns: integer, unit: integer): integer
  if ns < math.mininteger + ns % unit then return nil end
  return ns - ns % unit
end

--- Whether `text` parses as `want` (nil for a refusal), and why not.
local function parses_as(parse: function(string): (integer | nil, string), text: string,
    want: integer, ns: integer): boolean, string
  local back, why = parse(text)
  if back ~= want then
    return false, ("%d wrote %q, which parsed as %s, not %s: %s"):format(ns, text,
      tostring(back), tostring(want), why)
  end
  return true, ""
end

local function http_round_trips(input: string): boolean, string
  local ns = string.unpack("<i8", input)
  local second = cut(ns, NS)
  if second == nil then Fuzz.label("second before the range") end
  local ok, why = parses_as(Time.parse_http, Time.format_http(ns), second, ns)
  if not ok then return false, why end
  ok, why = parses_as(Time.parse_date, Time.format_date(ns), cut(ns, DAY_NS), ns)
  if not ok then return false, why end
  if second == nil then return true, "" end
  local c = Time.civil(ns)
  local day = (" %d"):format(c.day):sub(-2)
  if c.day < 10 then Fuzz.label("one-digit day") end
  local clock = ("%02d:%02d:%02d"):format(c.hour, c.minute, c.second)
  ok, why = parses_as(Time.parse_http, ("%s %s %s %s %04d"):format(DAYS[c.weekday]:sub(1, 3),
    MONTHS[c.month], day, clock, c.year), second, ns)
  if not ok then return false, why end
  if c.year >= 1969 and c.year <= 2068 then
    Fuzz.label("rfc850")
    ok, why = parses_as(Time.parse_http, ("%s, %02d-%s-%02d %s GMT"):format(DAYS[c.weekday],
      c.day, MONTHS[c.month], c.year % 100, clock), second, ns)
    if not ok then return false, why end
  end
  return true, ""
end

local function test_http_and_date_text_round_trip(tmp: string)
  Fuzz.run({
    name = "http date round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string return string.pack("<i8", gen_moment(src)) end,
    check = http_round_trips,
    requires = { "rfc850", "one-digit day" },
  })
end

--- HTTP dates and plain dates to mutate: each form, and the range's
--- edges.
local TEXT_SAMPLES <const> = {
  "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994",
  "Fri Sep 25 05:22:21 2026", "Tue, 21 Sep 1677 00:12:44 GMT", "Fri, 11 Apr 2262 23:47:16 GMT",
  "2026-09-25", "2000-02-29", "1677-09-22", "2262-04-11",
}

local function text_parse_holds(input: string): boolean, string
  local ok, ns, why = pcall(Time.parse_http, input)
  if not ok then return false, "parse_http raised: " .. tostring(ns) end
  if ns ~= nil then
    Fuzz.label("http parsed")
    if why ~= "" then return false, "parse_http parsed with a reason: " .. why end
    if ns % NS ~= 0 or Time.parse_http(Time.format_http(ns)) ~= ns then
      return false, ("%q parsed as %d, which does not come back"):format(input, ns)
    end
  elseif why == "" then
    return false, "parse_http refused without a reason"
  end
  ok, ns, why = pcall(Time.parse_date, input)
  if not ok then return false, "parse_date raised: " .. tostring(ns) end
  if ns ~= nil then
    Fuzz.label("date parsed")
    if why ~= "" then return false, "parse_date parsed with a reason: " .. why end
    if ns % DAY_NS ~= 0 or Time.parse_date(Time.format_date(ns)) ~= ns then
      return false, ("%q parsed as %d, which does not come back"):format(input, ns)
    end
  elseif why == "" then
    return false, "parse_date refused without a reason"
  end
  return true, ""
end

local function test_http_and_date_parse_are_total(tmp: string)
  Fuzz.run({
    name = "http date parse total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      if src:int(0, 3) == 0 then return Fuzz.bytes(src, 40) end
      return Fuzz.mutate(src, Fuzz.pick(src, TEXT_SAMPLES), 3)
    end,
    check = text_parse_holds,
    requires = { "http parsed", "date parsed" },
  })
end

local BETWEEN_ZONES <const> = { "UTC", "Asia/Kolkata", "America/New_York", "Pacific/Apia",
  "Europe/London", "Europe/Dublin", "Antarctica/Troll", "Australia/Lord_Howe" }

--- Two moments from 1897 through 2128, which reach each zone's history
--- of changes, and a zone, packed.
local function gen_pair(src: Fuzz.Source): string
  local function moment(): integer
    return src:int(-2500000000, 5000000000) * NS + (src:int(0, 2) == 0 and 0 or src:int(0, NS - 1))
  end
  local from = moment()
  -- Often near the first, where the calendar's small counts and its edges are.
  local to = src:int(0, 2) == 0 and from + src:int(-40, 40) * 86400 * NS + src:int(-5, 5) * 3600 * NS or
    moment()
  return string.pack("<i8i8", from, to) .. Fuzz.pick(src, BETWEEN_ZONES)
end

local function between_holds(input: string): boolean, string
  local from, to = string.unpack("<i8i8", input)
  local name = input:sub(17)
  local zone = assert(Time.zone(name))
  local ok, span = pcall(Time.between, from, to, zone)
  if not ok then return false, "raised: " .. tostring(span) end
  local d = span as Time.Duration
  local text_ok, text = pcall(Time.format_duration, d)
  if not text_ok then
    return false, ("%d to %d in %s: %s"):format(from, to, name, tostring(text))
  end
  local back = Time.parse_duration(text)
  if back == nil or back.years ~= d.years or back.months ~= d.months or back.days ~= d.days or
      back.ns ~= d.ns then
    return false, text .. " does not read back"
  end
  local dir = to > from and 1 or to < from and -1 or 0
  if (d.years * dir < 0) or (d.months * dir < 0) or (d.days * dir < 0) or (d.ns * dir < 0) then
    return false, ("%d to %d in %s: %s is against the sign of the span"):format(from, to, name, text)
  end
  Fuzz.label(to < from and "negative" or "positive")
  if d.months ~= 0 then Fuzz.label("months") end
  if d.days ~= 0 then Fuzz.label("days") end
  if name ~= "UTC" and name ~= "Asia/Kolkata" then Fuzz.label("a zone with changes") end
  local moved, why = Time.add_calendar(from, d, zone,
    { overflow = "clamp", disambiguation = "compatible" })
  if moved ~= to then
    return false, ("%d to %d in %s: %s adds to %s: %s"):format(from, to, name, text,
      tostring(moved), tostring(why))
  end
  return true, ""
end

local function test_between_adds_back_to_the_second_moment(tmp: string)
  Fuzz.run({
    name = "between round trip",
    dir = tmp,
    gen = gen_pair,
    check = between_holds,
    requires = { "negative", "positive", "months", "days", "a zone with changes" },
    shares = { negative = 0.2, months = 0.2, days = 0.2, ["a zone with changes"] = 0.5 },
  })
end
