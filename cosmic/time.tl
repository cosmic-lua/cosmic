--- Clocks, sleeping, and the calendar, in UTC and in time zones. Every
--- reading is in nanoseconds, so nothing above this module carries a unit
--- it has to remember. A moment is an integer of nanoseconds since
--- 1970-01-01T00:00:00Z without leap seconds, so the calendar spans
--- what 64 bits hold: 1677-09-21T00:12:43.145224192Z through
--- 2262-04-11T23:47:16.854775807Z, on the proleptic Gregorian calendar.
---
--- A zone says what offset from UTC, abbreviation and daylight saving
--- time each moment has somewhere: IANA's, by name (`zone`), from the
--- copy of the tz database the binary carries -- never the host's zone
--- files, so a name means the same rules on every host; the host's own
--- (`local_zone`), the carried zone `TZ`, /etc/localtime or
--- /etc/timezone names; or one read from TZif bytes (RFC 8536) or a
--- POSIX TZ string. `civil`, `from_civil`,
--- `add_calendar`, `days_between`, `months_between` and RFC 3339 text
--- each take one, and read the UTC calendar without.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local record Time
  --- A moment as a calendar names it: UTC's, or a zone's local time.
  record Civil
    --- 1677 through 2262.
    year: integer
    --- 1 (January) through 12.
    month: integer
    --- 1 through the month's last day.
    day: integer
    --- 0 through 23.
    hour: integer
    --- 0 through 59.
    minute: integer
    --- 0 through 59: there are no leap seconds.
    second: integer
    --- 0 through 999999999.
    nanosecond: integer
    --- ISO 8601's: 1 (Monday) through 7 (Sunday). `from_civil` ignores it.
    weekday: integer
    --- The day of the year, 1 through 366. `from_civil` ignores it.
    yday: integer
    --- Seconds east of UTC the local time is: 0 on the UTC calendar.
    --- `from_civil` reads it only to choose between the two moments a
    --- zone gives one local time when its clocks go back.
    offset: integer
    --- What the zone calls its time then, as "EDT"; "UTC" on the UTC
    --- calendar. `from_civil` ignores it.
    abbreviation: string
    --- Whether the zone counts it daylight saving time. `from_civil`
    --- ignores it.
    dst: boolean
  end

  --- A time zone: the offset from UTC, abbreviation and daylight saving
  --- time it gives each moment. `zone`, `local_zone`, `zone_from_tzif`
  --- and `zone_from_posix` make one; a table made by hand is refused.
  record Zone
    --- IANA's name for it, as "America/New_York" -- the one
    --- `format_rfc3339`'s `zone_name` writes -- or else the POSIX TZ
    --- string it was read from, or the name `zone_from_tzif` was given.
    name: string
  end

  --- Which moment a zone's local time names when its clocks skipped it
  --- (a gap, as spring forward) or passed it twice (a fold, as fall
  --- back), as Temporal's `disambiguation` says. "reject" refuses both;
  --- "earlier" and "later" take the earlier or later moment of a fold
  --- and, in a gap, the local time as the offset after or before the
  --- change would name it (so "earlier" lands before the gap and
  --- "later" after it); "compatible" is "earlier" in a fold and "later"
  --- in a gap, which is what a wall clock set forward does.
  enum Disambiguation
    "reject"
    "earlier"
    "later"
    "compatible"
  end

  record CivilOptions
    --- "reject" when absent.
    disambiguation: Time.Disambiguation
  end

  --- A calendar amount, for `add_calendar`: each field may be negative,
  --- and a missing one is zero.
  record Change
    years: integer
    months: integer
    days: integer
  end

  --- What `add_calendar` does with a day its month does not have, as
  --- January 31 plus a month: "reject" refuses it, "clamp" takes the
  --- month's last day.
  enum Overflow
    "reject"
    "clamp"
  end

  record AddOptions
    --- "reject" when absent.
    overflow: Time.Overflow
    --- The zone whose calendar the amount moves along, keeping its local
    --- time of day; UTC's when absent.
    zone: Time.Zone
    --- For a local time the move lands in a gap or a fold of `zone`;
    --- "reject" when absent.
    disambiguation: Time.Disambiguation
  end

  record FormatOptions
    --- Digits of fraction to write, 0 through 9, cut toward the past; by
    --- default as many as the nanoseconds need, none when they are zero.
    digits: integer
    --- The zone whose local time to write, with its offset; UTC, as
    --- `Z`, when absent.
    zone: Time.Zone
    --- Also write `zone`'s IANA name after the offset, as RFC 9557 does:
    --- `[America/New_York]`.
    zone_name: boolean
  end

  --- What `local_zone` reads in place of the host's.
  record LocalOptions
    --- The `TZ` value to read, in place of the environment's: nil reads
    --- the environment's, unless `unset` is set.
    tz: string
    --- With no `tz`, read as though `TZ` were unset rather than the
    --- environment's.
    unset: boolean
    --- The link read in place of /etc/localtime.
    localtime: string
    --- The file read in place of /etc/timezone.
    timezone: string
  end

  --- A moment read from RFC 3339 text, and the zone its RFC 9557
  --- suffix names.
  record Zoned
    ns: integer
    --- Nil when the text names none.
    zone: Time.Zone
  end

  --- Coordinated Universal Time, the zone every other is an offset from.
  UTC: Time.Zone
end

local NS <const> = 1000000000
local DAY <const> = 86400

--- The first and last moments an integer holds, as whole seconds and the
--- nanoseconds past them.
local MIN_S <const> = math.mininteger // NS
local MIN_NS <const> = math.mininteger % NS
local MAX_S <const> = math.maxinteger // NS
local MAX_NS <const> = math.maxinteger % NS
local RANGE <const> = "outside 1677-09-21T00:12:43.145224192Z through " ..
  "2262-04-11T23:47:16.854775807Z, what an integer of nanoseconds holds"

--- Days since 1970-01-01 of a proleptic Gregorian date: Howard Hinnant's
--- `days_from_civil`, with floor division.
local function days_from_civil(y: integer, m: integer, d: integer): integer
  y = m <= 2 and y - 1 or y
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (m > 2 and m - 3 or m + 9) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

--- The inverse of `days_from_civil`: Hinnant's `civil_from_days`.
local function civil_from_days(z: integer): Time.Civil
  z = z + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local month = mp < 10 and mp + 3 or mp - 9
  return {
    year = yoe + era * 400 + (month <= 2 and 1 or 0),
    month = month,
    day = doy - (153 * mp + 2) // 5 + 1,
  }
end

local function leap(y: integer): boolean
  return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end

local MONTH_DAYS <const> = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function month_days(y: integer, m: integer): integer
  return m == 2 and leap(y) and 29 or MONTH_DAYS[m]
end

--- Why `value`, the field `name`, is not an integer from `lo` through
--- `hi`, or nil when it is.
local function outside(name: string, value: integer, lo: integer, hi: integer): string
  if math.type(value) ~= "integer" then
    return ("%s is not an integer: %s %s"):format(name, math.type(value) or type(value),
      tostring(value))
  end
  if value < lo or value > hi then
    return ("%s %d is not %d through %d"):format(name, value, lo, hi)
  end
  return nil
end

--- The seconds the fields of `c` name on the UTC calendar, or nil and
--- which field is wrong. A year either side of the range is let through,
--- so an offset can still reach the range's edges.
local function seconds_of(c: Time.Civil): integer | nil, string
  local why = outside("year", c.year, math.mininteger, math.maxinteger)
    or outside("month", c.month, 1, 12)
  if why ~= nil then return nil, why end
  if c.year < 1676 or c.year > 2263 then return nil, RANGE end
  why = outside("day", c.day, 1, month_days(c.year, c.month))
    or outside("hour", c.hour, 0, 23)
    or outside("minute", c.minute, 0, 59)
    or outside("second", c.second, 0, 59)
    or outside("nanosecond", c.nanosecond, 0, NS - 1)
  if why ~= nil then return nil, why end
  return days_from_civil(c.year, c.month, c.day) * DAY
    + c.hour * 3600 + c.minute * 60 + c.second, ""
end

--- The nanoseconds `s` seconds and `n` nanoseconds past the epoch
--- name, or nil and that they are outside what an integer holds.
local function instant(s: integer, n: integer): integer | nil, string
  if s < MIN_S or (s == MIN_S and n < MIN_NS) or s > MAX_S or (s == MAX_S and n > MAX_NS) then
    return nil, RANGE
  end
  -- At MIN_S the product wraps past the bottom and the sum wraps back:
  -- Lua's integers are two's complement.
  return s * NS + n, ""
end

--- The nanoseconds of a calendar moment `offset` seconds east of UTC,
--- or nil and which field is wrong, or that the moment is outside what
--- an integer holds.
local function moment(c: Time.Civil, offset: integer): integer | nil, string
  local s, why = seconds_of(c)
  if s == nil then return nil, why end
  return instant(s - offset, c.nanosecond)
end

--- The calendar fields of `s` seconds and `n` nanoseconds on the UTC
--- calendar.
local function civil_at(s: integer, n: integer): Time.Civil
  local days, into = s // DAY, s % DAY
  local c = civil_from_days(days)
  c.hour, c.minute, c.second = into // 3600, into % 3600 // 60, into % 60
  c.nanosecond = n
  c.weekday = (days + 3) % 7 + 1
  c.yday = days - days_from_civil(c.year, 1, 1) + 1
  return c
end

-- Zones.

--- What a zone says of a span of time.
local record Kind
  --- Seconds east of UTC.
  offset: integer
  abbreviation: string
  dst: boolean
end

--- How a POSIX TZ rule names a day of the year.
local enum Form
  --- `Jn`: 1 through 365, February 29 never counted.
  "J"
  --- `n`: 0 through 365, February 29 counted.
  "n"
  --- `Mm.w.d`: weekday d (0 is Sunday) of week w (5 is the last) of
  --- month m.
  "M"
end

--- One of a POSIX TZ string's two yearly changes: a day, and the local
--- time on it, in seconds, the change happens at.
local record Rule
  form: Form
  day: integer
  month: integer
  week: integer
  weekday: integer
  time: integer
end

--- A POSIX TZ string (POSIX.1-2017 8.3, with RFC 8536's version 3
--- extensions): standard time, and daylight saving time with the rules
--- it starts and ends by, if there is any.
local record Posix
  std: Kind
  dst: Kind
  start: Rule
  finish: Rule
  --- Each year's two changes, as seconds since the epoch, once worked
  --- out: at most one per year a moment can fall in.
  years: {integer:{integer}}
end

--- Everything a zone knows: the moments its offset changed, what it was
--- from each, what it was before the first, and the TZ string that
--- carries it on past the last.
local record Rules
  --- Seconds since the epoch, ascending.
  transitions: {integer}
  --- What the zone said from each transition on.
  kinds: {Kind}
  --- What it said before the first.
  first: Kind
  --- The TZ string for moments after the last transition, if any.
  footer: Posix
  --- The zone's name: what `Zone.name` reads, and what every message
  --- and `zone_name` write, whatever a caller does to the record.
  name: string
  --- Whether the name is one RFC 9557 can write, which `zone_name` can.
  named: boolean
end

--- Each zone's rules, kept apart from the record a caller holds.
local rules_of: {Time.Zone:Rules} = setmetatable({}, { __mode = "k" })

--- A zone for `rules`, named `name`. Zones are shared -- `zone` answers
--- one per name, to every caller in the process -- so the record is
--- read-only: `name` is answered from the rules, a write raises, and the
--- metatable is hidden. `rawset` can still shadow `name` on the record,
--- but nothing here reads it there: every message and `zone_name`
--- write the rules' name.
local function make_zone(name: string, rules: Rules): Time.Zone
  rules.name = name
  local zone: Time.Zone = {}
  local hidden: metatable<Time.Zone> = {
    __index = function(_: Time.Zone, key: string): any
      if key == "name" then return name end
      return nil
    end,
    __newindex = function(_: Time.Zone, key: string)
      error("time: a zone is read-only; it has no field " .. tostring(key) .. " to set", 2)
    end,
  }
  -- Teal's metatable record has no `__metatable`; Lua reads it all the same.
  rawset(hidden, "__metatable", false)
  setmetatable(zone, hidden)
  rules_of[zone] = rules
  return zone
end

--- The rules of `zone`; raises, on behalf of the public function's
--- caller, for a table no function here made.
local function rules_for(zone: Time.Zone): Rules
  local rules = rules_of[zone]
  if rules == nil then
    error("time: not a zone Time.zone made", 3)
  end
  return rules
end

local UTC_KIND <const>: Kind = { offset = 0, abbreviation = "UTC", dst = false }

Time.UTC = make_zone("UTC", { transitions = {}, kinds = {}, first = UTC_KIND, named = true })

--- The day, as days since the epoch, `r` names in `year`.
local function rule_day(r: Rule, year: integer): integer
  local jan1 = days_from_civil(year, 1, 1)
  if r.form == "J" then
    return jan1 + r.day - 1 + ((r.day >= 60 and leap(year)) and 1 or 0)
  elseif r.form == "n" then
    return jan1 + r.day
  end
  local first = days_from_civil(year, r.month, 1)
  -- 1970-01-01 was a Thursday, weekday 4 counting Sunday as 0.
  local day = first + (r.weekday - (first + 4) % 7 + 7) % 7 + (r.week - 1) * 7
  local last = first + month_days(year, r.month) - 1
  while day > last do day = day - 7 end
  return day
end

--- What the TZ string `p` says of `s` seconds since the epoch: the
--- latest change at or before it, from the years around it, where a
--- start of daylight saving time wins a tie with an end, so a zone whose
--- rules end it the moment they start it again keeps it all year.
local function posix_kind(p: Posix, s: integer): Kind
  if p.dst == nil then return p.std end
  local year = civil_from_days((s + p.std.offset) // DAY).year
  local best, starts = math.mininteger, false
  for y = year - 2, year + 1 do
    local changes = p.years[y]
    if changes == nil then
      changes = { rule_day(p.start, y) * DAY + p.start.time - p.std.offset,
                  rule_day(p.finish, y) * DAY + p.finish.time - p.dst.offset }
      p.years[y] = changes
    end
    if changes[2] <= s and changes[2] > best then
      best, starts = changes[2], false
    end
    if changes[1] <= s and changes[1] >= best then
      best, starts = changes[1], true
    end
  end
  return starts and p.dst or p.std
end

--- What `rules` say of `s` seconds since the epoch.
local function kind_at(rules: Rules, s: integer): Kind
  local t = rules.transitions
  local n = #t
  if n == 0 or s < t[1] then
    -- RFC 8536 3.2: with no transitions, the footer holds for every
    -- moment; before the first, local time type 0 does.
    if n == 0 and rules.footer ~= nil then return posix_kind(rules.footer, s) end
    return rules.first
  end
  if s > t[n] and rules.footer ~= nil then return posix_kind(rules.footer, s) end
  local lo, hi = 1, n
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if t[mid] <= s then lo = mid else hi = mid - 1 end
  end
  return rules.kinds[lo]
end

--- Every offset `rules` give some moment within two days of `s`
--- seconds since the epoch, which is every offset a local time `s` can
--- have been made with, since no offset a zone can have (26 hours at
--- most) reaches two days. A footer's two are both counted, near a
--- change or not.
local function offsets_near(rules: Rules, s: integer): {integer}
  local lo, hi = s - 2 * DAY, s + 2 * DAY
  local seen: {integer:boolean} = {}
  local out: {integer} = {}
  local function add(kind: Kind)
    if not seen[kind.offset] then
      seen[kind.offset] = true
      out[#out + 1] = kind.offset
    end
  end
  add(kind_at(rules, lo))
  local t = rules.transitions
  local first, last = 1, #t + 1
  while first < last do
    local mid = (first + last) // 2
    if t[mid] > lo then last = mid else first = mid + 1 end
  end
  while first <= #t and t[first] <= hi do
    add(rules.kinds[first])
    first = first + 1
  end
  local footer = rules.footer
  if footer ~= nil and (#t == 0 or hi > t[#t]) then
    add(footer.std)
    if footer.dst ~= nil then add(footer.dst) end
  end
  return out
end

--- `offset` seconds east of UTC as RFC 3339 writes one, `-05:00`, with
--- seconds after when it has any, as local mean time does.
local function offset_text(offset: integer): string
  local a = math.abs(offset)
  local text = ("%s%02d:%02d"):format(offset < 0 and "-" or "+", a // 3600, a % 3600 // 60)
  if a % 60 ~= 0 then text = text .. (":%02d"):format(a % 60) end
  return text
end

--- `offset` rounded to the nearest whole minute, which is all an RFC 3339
--- offset can say.
local function whole_minutes(offset: integer): integer
  return (offset + 30) // 60 * 60
end

--- A POSIX TZ string as a `Posix`, or nil and why: `EST5EDT`,
--- `EST5EDT,M3.2.0,M11.1.0`, `<+0330>-3:30`, `AEST-10AEDT,M10.1.0,M4.1.0/3`.
--- An offset is west of UTC, as POSIX has it, through 24 hours; a rule's
--- time may be negative and through 167 hours, as RFC 8536's version 3
--- allows. Daylight saving time with no rules takes the United States'
--- since 2007, `M3.2.0,M11.1.0`, as glibc and tzcode do.
local function parse_posix(tz: string): Posix | nil, string
  if #tz > 256 then return nil, "a TZ string is at most 256 bytes, not " .. #tz end
  local at = 1

  local function abbreviation(what: string): string | nil, string
    if tz:sub(at, at) == "<" then
      local close = tz:find(">", at + 1, true)
      if close == nil then return nil, ("%s at byte %d: no \">\" closes it"):format(what, at) end
      local body = tz:sub(at + 1, close - 1)
      if #body < 3 or body:find("[^%w+%-]") ~= nil then
        return nil, ("%s at byte %d: expected three or more letters, digits, \"+\" or \"-\" " ..
          "between \"<\" and \">\""):format(what, at)
      end
      at = close + 1
      return body, ""
    end
    local last = at
    while tz:find("^[A-Za-z]", last) ~= nil do last = last + 1 end
    if last - at < 3 then
      return nil, ("%s at byte %d: expected three or more letters"):format(what, at)
    end
    local body = tz:sub(at, last - 1)
    at = last
    return body, ""
  end

  local function number(most: integer, lo: integer, hi: integer, what: string): integer | nil, string
    local first = at
    local n = 0
    while at - first < most do
      local b = tz:byte(at)
      if b == nil or b < 48 or b > 57 then break end
      n = n * 10 + (b - 48)
      at = at + 1
    end
    if at == first then return nil, ("%s at byte %d: expected a number"):format(what, first) end
    if n < lo or n > hi then
      return nil, ("%s %d at byte %d is not %d through %d"):format(what, n, first, lo, hi)
    end
    return n, ""
  end

  -- [+-]hh[:mm[:ss]], as seconds.
  local function duration(hours: integer, what: string): integer | nil, string
    local sign = 1
    local c = tz:sub(at, at)
    if c == "+" or c == "-" then
      if c == "-" then sign = -1 end
      at = at + 1
    end
    local h, why = number(3, 0, hours, what .. "'s hours")
    if h == nil then return nil, why end
    local m, sec = 0, 0
    if tz:sub(at, at) == ":" then
      at = at + 1
      m, why = number(2, 0, 59, what .. "'s minutes")
      if m == nil then return nil, why end
      if tz:sub(at, at) == ":" then
        at = at + 1
        sec, why = number(2, 0, 59, what .. "'s seconds")
        if sec == nil then return nil, why end
      end
    end
    return sign * (h * 3600 + m * 60 + sec), ""
  end

  local function expect(want: string, what: string): string
    if tz:sub(at, at) ~= want then
      return ("expected %q %s at byte %d"):format(want, what, at)
    end
    at = at + 1
    return nil
  end

  local function rule(what: string): Rule | nil, string
    local r: Rule = { time = 7200 }
    local why: string
    local c = tz:sub(at, at)
    if c == "J" then
      at = at + 1
      r.form = "J"
      r.day, why = number(3, 1, 365, what .. "'s day")
      if r.day == nil then return nil, why end
    elseif c == "M" then
      at = at + 1
      r.form = "M"
      r.month, why = number(2, 1, 12, what .. "'s month")
      if r.month == nil then return nil, why end
      why = expect(".", "after " .. what .. "'s month")
      if why ~= nil then return nil, why end
      r.week, why = number(1, 1, 5, what .. "'s week")
      if r.week == nil then return nil, why end
      why = expect(".", "after " .. what .. "'s week")
      if why ~= nil then return nil, why end
      r.weekday, why = number(1, 0, 6, what .. "'s weekday")
      if r.weekday == nil then return nil, why end
    else
      r.form = "n"
      r.day, why = number(3, 0, 365, what .. "'s day")
      if r.day == nil then return nil, why end
    end
    if tz:sub(at, at) == "/" then
      at = at + 1
      r.time, why = duration(167, what .. "'s time")
      if r.time == nil then return nil, why end
    end
    return r, ""
  end

  local std_name, why = abbreviation("standard time's abbreviation")
  if std_name == nil then return nil, why end
  local west, west_why = duration(24, "standard time's offset")
  if west == nil then return nil, west_why end
  local p: Posix = { std = { offset = -west, abbreviation = std_name, dst = false }, years = {} }
  if at > #tz then return p, "" end
  local dst_name, dst_why = abbreviation("daylight saving time's abbreviation")
  if dst_name == nil then return nil, dst_why end
  local offset = p.std.offset + 3600
  if at <= #tz and tz:sub(at, at) ~= "," then
    local dst_west, offset_why = duration(24, "daylight saving time's offset")
    if dst_west == nil then return nil, offset_why end
    offset = -dst_west
  end
  p.dst = { offset = offset, abbreviation = dst_name, dst = true }
  if at > #tz then
    p.start = { form = "M", month = 3, week = 2, weekday = 0, time = 7200 }
    p.finish = { form = "M", month = 11, week = 1, weekday = 0, time = 7200 }
    return p, ""
  end
  why = expect(",", "before daylight saving time's rules")
  if why ~= nil then return nil, why end
  local start, start_why = rule("daylight saving time's start")
  if start == nil then return nil, start_why end
  why = expect(",", "between daylight saving time's start and end")
  if why ~= nil then return nil, why end
  local finish, finish_why = rule("daylight saving time's end")
  if finish == nil then return nil, finish_why end
  if at <= #tz then return nil, ("unexpected text at byte %d"):format(at) end
  p.start, p.finish = start, finish
  return p, ""
end

--- The big-endian unsigned 32-bit integer at `at` in `s`.
local function u32(s: string, at: integer): integer
  local a, b, c, d = s:byte(at, at + 3)
  return (a << 24) | (b << 16) | (c << 8) | d
end

--- The big-endian signed 32-bit integer at `at` in `s`.
local function i32(s: string, at: integer): integer
  local n = u32(s, at)
  return n >= 0x80000000 and n - 0x100000000 or n
end

--- The big-endian signed 64-bit integer at `at` in `s`: the shift wraps
--- into the sign as two's complement does.
local function i64(s: string, at: integer): integer
  return (u32(s, at) << 32) | u32(s, at + 4)
end

--- A TZif file's counts, from the header at `at`: `isutcnt`,
--- `isstdcnt`, `leapcnt`, `timecnt`, `typecnt` and `charcnt`.
local function tzif_counts(data: string, at: integer): {integer} | nil, string
  if #data < at + 43 then
    return nil, ("truncated: a TZif header at byte %d needs 44 bytes, and %d remain"):format(at,
      #data - at + 1)
  end
  if data:sub(at, at + 3) ~= "TZif" then
    return nil, ("expected \"TZif\" at byte %d"):format(at)
  end
  local counts: {integer} = {}
  for i = 1, 6 do counts[i] = u32(data, at + 16 + 4 * i) end
  return counts, ""
end

--- A TZif file (RFC 8536, versions 1 through 4) as `Rules`, or nil and
--- why. A version 2 or later file is read from its 64-bit block and its
--- footer; a version 1 file from its 32-bit block alone. Every count is
--- checked against the bytes there are before anything is read, so the
--- work is bounded by the input's length, and nothing raises. A file
--- with leap second records (a `right/` zone) is refused: cosmic time
--- has no leap seconds.
local function parse_tzif(data: string): Rules | nil, string
  local counts, why = tzif_counts(data, 1)
  if counts == nil then return nil, why end
  local version = data:byte(5)
  if version ~= 0 and (version < 0x32 or version > 0x34) then
    return nil, ("version byte 0x%02x is not 0, \"2\", \"3\" or \"4\""):format(version)
  end
  local at, size = 45, 4
  if version ~= 0 then
    local isut, isstd, leaps, times, types, chars =
      counts[1], counts[2], counts[3], counts[4], counts[5], counts[6]
    local second = at + times * 5 + types * 6 + chars + leaps * 8 + isstd + isut
    counts, why = tzif_counts(data, second)
    if counts == nil then return nil, "the version 2 header: " .. why end
    if data:byte(second + 4) ~= version then
      return nil, ("the version 2 header at byte %d names version byte 0x%02x, not 0x%02x"):format(
        second, data:byte(second + 4), version)
    end
    at, size = second + 44, 8
  end
  local isut, isstd, leaps, times, types, chars =
    counts[1], counts[2], counts[3], counts[4], counts[5], counts[6]
  if types == 0 then return nil, "typecnt is 0: a zone has at least one local time type" end
  if chars == 0 then return nil, "charcnt is 0: a zone has at least one abbreviation" end
  if isut ~= 0 and isut ~= types then
    return nil, ("isutcnt %d is neither 0 nor typecnt, %d"):format(isut, types)
  end
  if isstd ~= 0 and isstd ~= types then
    return nil, ("isstdcnt %d is neither 0 nor typecnt, %d"):format(isstd, types)
  end
  if leaps ~= 0 then
    return nil, ("%d leap second records: cosmic time has no leap seconds"):format(leaps)
  end
  local length = times * (size + 1) + types * 6 + chars + isstd + isut
  if at + length - 1 > #data then
    return nil, ("truncated: the data block at byte %d needs %d bytes, and %d remain"):format(at,
      length, #data - at + 1)
  end

  local transitions: {integer} = {}
  for i = 1, times do
    local t = size == 8 and i64(data, at) or i32(data, at)
    if i > 1 and t <= transitions[i - 1] then
      return nil, ("transition %d at byte %d is not after the one before it"):format(i, at)
    end
    transitions[i] = t
    at = at + size
  end
  local indices: {integer} = {}
  for i = 1, times do
    local index = data:byte(at)
    if index >= types then
      return nil, ("transition %d names local time type %d, and there are %d"):format(i, index, types)
    end
    indices[i] = index + 1
    at = at + 1
  end
  local kinds: {Kind} = {}
  local names_at = at + types * 6
  -- An index is one byte, and cosmic caps an abbreviation at 255 bytes
  -- -- its own limit, far past tzcode's 50 for all of them -- so only
  -- the first 511 bytes of the abbreviations can hold one: each index's
  -- NUL is found in one pass back over them, never by a search that
  -- could run the length of the file once per type.
  local window = math.min(chars, 511)
  local nul_after: {integer:integer} = {}
  local next_nul: integer = nil
  for k = window - 1, 0, -1 do
    if data:byte(names_at + k) == 0 then next_nul = k end
    nul_after[k] = next_nul
  end
  local abbreviations: {integer:string} = {}
  for i = 1, types do
    local offset, dst, name = i32(data, at), data:byte(at + 4), data:byte(at + 5)
    if offset < -89999 or offset > 93599 then
      return nil, ("local time type %d's offset %d is not -89999 through 93599"):format(i - 1, offset)
    end
    if dst > 1 then
      return nil, ("local time type %d's isdst %d is not 0 or 1"):format(i - 1, dst)
    end
    if name >= chars then
      return nil, ("local time type %d's abbreviation index %d is past charcnt, %d"):format(i - 1,
        name, chars)
    end
    local abbreviation = abbreviations[name]
    if abbreviation == nil then
      local nul = nul_after[name]
      if nul == nil or nul - name > 255 then
        return nil, ("local time type %d's abbreviation has no NUL within 255 bytes and before " ..
          "the end of the abbreviations"):format(i - 1)
      end
      abbreviation = data:sub(names_at + name, names_at + nul - 1)
      abbreviations[name] = abbreviation
    end
    kinds[i] = { offset = offset, dst = dst == 1, abbreviation = abbreviation }
    at = at + 6
  end
  at = at + chars
  for i = 1, isstd + isut do
    if data:byte(at) > 1 then
      return nil, ("indicator %d at byte %d is not 0 or 1"):format(i, at)
    end
    at = at + 1
  end
  local rules: Rules = { transitions = transitions, kinds = {}, first = kinds[1] }
  for i = 1, times do rules.kinds[i] = kinds[indices[i]] end

  if version ~= 0 then
    if data:sub(at, at) ~= "\n" then
      return nil, ("the footer at byte %d does not begin with a newline"):format(at)
    end
    local close = data:find("\n", at + 1, true)
    if close == nil then return nil, "the footer has no newline ending it" end
    local tz = data:sub(at + 1, close - 1)
    if tz ~= "" then
      local footer, footer_why = parse_posix(tz)
      if footer == nil then
        local shown = #tz > 64 and tz:sub(1, 64) .. "..." or tz
        return nil, ("the footer's TZ string %q: %s"):format(shown, footer_why)
      end
      rules.footer = footer
    end
    at = close + 1
  end
  if at <= #data then
    return nil, ("%d bytes past the end, at byte %d"):format(#data - at + 1, at)
  end
  return rules, ""
end

--- Files in a zoneinfo directory that are no zone of their own.
local NOT_ZONES <const>: {string:boolean} = { localtime = true, posixrules = true }

--- Why `name` is no zone name, or nil when it could be one: a relative
--- path of letters, digits and `_+-.`, no part of it empty, `.` or
--- `..`, so it can only ever name a file under a zoneinfo directory --
--- and not one of the files there that is no zone of its own:
--- `localtime` (on Debian a link to /etc/localtime, the host's zone),
--- `posixrules`, or a zone under `posix/` or `right/`.
local function name_problem(name: string): string
  if name == "" then return "a zone name is not empty" end
  if #name > 255 then return ("a zone name is at most 255 bytes, not %d"):format(#name) end
  local bad = name:find("[^A-Za-z0-9_+./%-]")
  if bad ~= nil then
    return ("zone name %q holds %q at byte %d: a zone name is letters, digits and \"_+-./\""):format(
      name, name:sub(bad, bad), bad)
  end
  if name:sub(1, 1) == "/" then
    return ("zone name %q begins with \"/\": a zone name is relative"):format(name)
  end
  for part in (name .. "/"):gmatch("([^/]*)/") do
    if part == "" or part == "." or part == ".." then
      return ("zone name %q has a part %q: a zone name has no empty, \".\" or \"..\" part"):format(
        name, part)
    end
  end
  if NOT_ZONES[name] or name:find("^posix/") ~= nil or
      name:find("^right/") ~= nil then
    return ("%q is a file in a zoneinfo directory, not a zone name"):format(name)
  end
  return nil
end

--- Whether RFC 9557 can write `name` in a suffix: a zone name each of
--- whose parts begins with a letter, `.` or `_` (its `time-zone-initial`).
local function writable(name: string): boolean
  if name_problem(name) ~= nil then return false end
  for part in (name .. "/"):gmatch("([^/]*)/") do
    if part:find("^[A-Za-z._]") == nil then return false end
  end
  return true
end

--- Every zone `zone` has loaded, by name.
local zones: {string:Time.Zone} = {}

--- Why each name `zone` found no zone for was refused, so text naming
--- unknown zones over and over looks none up twice; emptied when it
--- reaches `REFUSED_KEPT` names, which bounds it.
local refused_names: {string:string} = {}
local refused_count = 0
local REFUSED_KEPT <const> = 1024

--- IANA's zone `name`, as "America/New_York" or "UTC", from the copy of
--- the tz database the binary carries. The host's zone files are never
--- read, so a name gives the same rules on every host, whatever tz
--- release it has or whether it has one at all. Nil and why when
--- `name` is no zone name (empty, absolute, with a `..` part, or with a
--- character other than letters, digits and `_+-./`) or the binary
--- carries no such zone. A zone is read once a process and the same
--- `Zone` answered from then on, and a name found to be no zone is not
--- looked for again.
function Time.zone(name: string): Time.Zone | nil, string
  local cached = zones[name]
  if cached ~= nil then return cached, "" end
  local refused = refused_names[name]
  if refused ~= nil then return nil, refused end
  local function refuse(why: string): string
    if refused_count >= REFUSED_KEPT then
      refused_names, refused_count = {}, 0
    end
    refused_names[name], refused_count = why, refused_count + 1
    return why
  end
  local problem = name_problem(name)
  if problem ~= nil then return nil, refuse(problem) end
  local Store = require("cosmic.store")
  local carried, _ = Store.zoneinfo(name)
  if carried == nil then
    return nil, refuse(("no time zone %s: this binary's tz database has none"):format(name))
  end
  local rules, why = parse_tzif(carried)
  if rules == nil then
    return nil, refuse(("the binary's time zone %s: %s"):format(name, why))
  end
  rules.named = writable(name)
  local zone = make_zone(name, rules)
  zones[name] = zone
  return zone, ""
end

--- The zone TZif bytes (RFC 8536) describe, named `name`, or nil and
--- why they are no TZif file cosmic reads. `name` is written by
--- `format_rfc3339`'s `zone_name` when it is a zone name RFC 9557 can
--- write.
function Time.zone_from_tzif(data: string, name: string): Time.Zone | nil, string
  local rules, why = parse_tzif(data)
  if rules == nil then return nil, why end
  rules.named = writable(name)
  return make_zone(name, rules), ""
end

--- The zone a POSIX TZ string describes, as `EST5EDT,M3.2.0,M11.1.0` or
--- `<+0330>-3:30`, named by the string itself, or nil and why it is none.
--- Offsets are west of UTC, as POSIX has them; a rule's time may be
--- negative or past 24 hours, as RFC 8536's version 3 allows; and
--- daylight saving time named with no rules takes the United States',
--- `M3.2.0,M11.1.0`, as glibc does.
function Time.zone_from_posix(tz: string): Time.Zone | nil, string
  local p, why = parse_posix(tz)
  if p == nil then return nil, why end
  return make_zone(tz, { transitions = {}, kinds = {}, first = p.std, footer = p, named = false }), ""
end

--- The zone name a path names by where it sits, as
--- `/usr/share/zoneinfo/Europe/Berlin` names Europe/Berlin: what
--- follows its last `zoneinfo/`, less a `posix/` or `right/` before it,
--- or nil when that is no zone name.
local function zoneinfo_name(path: string): string
  local name = path:match(".*zoneinfo/(.+)$")
  if name == nil then return nil end
  name = name:gsub("^posix/", ""):gsub("^right/", "")
  if name_problem(name) ~= nil then return nil end
  return name
end

--- The zone name /etc/localtime's link names, following links that
--- name none -- as NixOS's goes through /etc/zoneinfo -- a few deep.
local function linked_name(path: string): string
  for _ = 1, 8 do
    local target, _ = Fs.readlink(path)
    if target == nil then return nil end
    local name = zoneinfo_name(target)
    if name ~= nil then return name end
    if target:sub(1, 1) ~= "/" then
      target = (path:match("^(.*/)") or "") .. target
    end
    path = target
  end
  return nil
end

--- The zone name /etc/timezone holds, as Debian writes it: its first
--- line, less the space around it.
local function written_name(path: string): string
  local text, _ = Fs.read(path)
  if text == nil then return nil end
  local name = text:match("^[^\n]*"):match("^%s*(.-)%s*$")
  if name_problem(name) ~= nil then return nil end
  return name
end

--- The host's zone when `TZ` is unset: the carried zone the
--- /etc/localtime link names, else the one /etc/timezone names, else UTC.
local function host_zone(localtime: string, timezone: string): Time.Zone
  for _, name in ipairs({ linked_name(localtime) or "", written_name(timezone) or "" }) do
    if name ~= "" then
      local zone, _ = Time.zone(name)
      if zone ~= nil then return zone end
    end
  end
  return Time.UTC
end

--- Every zone `local_zone` has answered with no options, by `TZ`, and
--- the one for `TZ` unset.
local locals: {string:Time.Zone} = {}
local unset_local: Time.Zone = nil

--- The host's own zone, as Java and ICU find it: the host names a zone
--- and the binary's tz database gives its rules, as `zone` does -- the
--- host's zone files are never read. With `TZ` unset, the zone the
--- /etc/localtime link names by where it points (`.../zoneinfo/Europe/Berlin`),
--- else the one the first line of /etc/timezone names, else UTC: an
--- /etc/localtime that is a copy rather than a link, or none at all,
--- is UTC unless /etc/timezone says otherwise, and never a failure.
--- `TZ` set and empty, or `TZ=:`, is UTC. `TZ=:Name` and `TZ=Name` are
--- `zone(Name)`, and `TZ=:/path` the zone its path names the same way
--- as the link; any other `TZ` is a POSIX TZ string
--- (`zone_from_posix`). Nil and why only for a `TZ` that names no zone
--- the binary carries and is no POSIX TZ string. `opts.tz` stands in
--- for `TZ` (nil reads the environment's, unless `opts.unset` reads as
--- though it were unset), `opts.localtime` for /etc/localtime and
--- `opts.timezone` for /etc/timezone; with no options, the answer is
--- read once a process.
function Time.local_zone(opts?: Time.LocalOptions): Time.Zone | nil, string
  local tz: string = nil
  local localtime, timezone = "/etc/localtime", "/etc/timezone"
  if opts ~= nil then
    tz = opts.tz
    localtime = opts.localtime or localtime
    timezone = opts.timezone or timezone
  end
  if tz == nil and not (opts ~= nil and opts.unset) then tz = sys.getenv("TZ") end
  local cacheable = opts == nil
  if cacheable then
    local cached: Time.Zone
    if tz == nil then cached = unset_local else cached = locals[tz] end
    if cached ~= nil then return cached, "" end
  end
  local zone: Time.Zone
  -- Empty or a bare ":": UTC.
  if tz ~= nil and tz:gsub("^:", "") == "" then
    zone = Time.UTC
  elseif tz == nil then
    zone = host_zone(localtime, timezone)
  elseif tz:sub(1, 1) == ":" then
    local name = tz:sub(2)
    if name:sub(1, 1) == "/" then
      name = zoneinfo_name(name)
      if name == nil then
        return nil, ("TZ=%s: a path names a zone only by what follows its \"zoneinfo/\""):format(tz)
      end
    end
    local why: string
    zone, why = Time.zone(name)
    if zone == nil then return nil, ("TZ=%s: %s"):format(tz, why) end
  else
    if name_problem(tz) == nil then
      local named, _ = Time.zone(tz)
      zone = named
    end
    if zone == nil then
      local p, why = parse_posix(tz)
      if p == nil then
        return nil, ("TZ=%s names no zone this binary carries, and is no POSIX TZ string: %s"):format(
          tz, why)
      end
      zone = make_zone(tz, { transitions = {}, kinds = {}, first = p.std, footer = p, named = false })
    end
  end
  if cacheable then
    if tz == nil then unset_local = zone else locals[tz] = zone end
  end
  return zone, ""
end

--- `ns` on the calendar of `zone`, UTC's by default, with the offset,
--- abbreviation and daylight saving time it has there. Every integer is
--- a moment in range. Raises for a `zone` no function here made.
function Time.civil(ns: integer, zone?: Time.Zone): Time.Civil
  local s, n = ns // NS, ns % NS
  local kind = zone ~= nil and kind_at(rules_for(zone), s) or UTC_KIND
  local c = civil_at(s + kind.offset, n)
  c.offset, c.abbreviation, c.dst = kind.offset, kind.abbreviation, kind.dst
  return c
end

local DISAMBIGUATIONS <const>: {string:boolean} = {
  reject = true, earlier = true, later = true, compatible = true,
}

--- `c` as a zone writes local time: `2026-03-08T02:30`, with seconds
--- when it has any.
local function local_text(c: Time.Civil): string
  local text = ("%04d-%02d-%02dT%02d:%02d"):format(c.year, c.month, c.day, c.hour, c.minute)
  if c.second ~= 0 or c.nanosecond ~= 0 then text = text .. (":%02d"):format(c.second) end
  return text
end

--- The nanoseconds `c` names on the calendar of `zone`, UTC's by
--- default, or nil and which field is out of its range (month 13,
--- February 30, hour 24) or not an integer (a float such as 2026.0
--- included), or that the moment is outside what an integer holds.
--- Nothing is normalized: day 32 is refused, not carried into the next
--- month. A local time a zone skipped or passed twice is resolved as
--- `opts.disambiguation` says, and refused by default, naming the
--- change; passed twice, the moment whose offset is `c.offset` is taken
--- whatever the disambiguation, so `from_civil(civil(ns, zone), zone)`
--- is always `ns`. Raises for a `disambiguation` that is none of
--- `Disambiguation`'s, or a `zone` no function here made.
function Time.from_civil(c: Time.Civil, zone?: Time.Zone, opts?: Time.CivilOptions): integer | nil, string
  local how = opts ~= nil and opts.disambiguation or "reject"
  if not DISAMBIGUATIONS[how] then
    error("time: disambiguation is \"reject\", \"earlier\", \"later\" or \"compatible\", not " ..
      tostring(how), 2)
  end
  if zone == nil then return moment(c, 0) end
  local rules = rules_for(zone)
  local s, why = seconds_of(c)
  if s == nil then return nil, why end
  -- Each offset in effect near the local time makes a moment of it, and
  -- one that has the offset it was made with is a moment it names. The
  -- earliest such moment has the offset before any change there, and
  -- the latest the offset after it.
  local offsets = offsets_near(rules, s)
  local found: {integer} = {}
  local lowest, highest = offsets[1], offsets[1]
  for _, offset in ipairs(offsets) do
    if kind_at(rules, s - offset).offset == offset then found[#found + 1] = s - offset end
    lowest, highest = math.min(lowest, offset), math.max(highest, offset)
  end
  table.sort(found)
  local before, after = kind_at(rules, s - highest).offset, kind_at(rules, s - lowest).offset
  local chosen: integer
  if #found == 0 then
    if how == "reject" then
      return nil, ("%s does not exist in %s: clocks moved from %s to %s"):format(local_text(c),
        rules.name, offset_text(before), offset_text(after))
    end
    chosen = how == "earlier" and s - after or s - before
  elseif #found == 1 then
    chosen = found[1]
  else
    for _, t in ipairs(found) do
      if s - t == c.offset then chosen = t end
    end
    if chosen == nil then
      if how == "reject" then
        return nil, ("%s happens twice in %s: clocks moved from %s to %s; disambiguation " ..
          "\"earlier\" or \"later\" picks one"):format(local_text(c), rules.name,
          offset_text(before), offset_text(after))
      end
      chosen = how == "later" and found[#found] or found[1]
    end
  end
  return instant(chosen, c.nanosecond)
end

--- `ns` moved by a calendar amount on the calendar of `opts.zone`, UTC's
--- by default: the years and months first, keeping the day and the
--- local time of day, then the days, and the local time reached read
--- back as `from_civil` reads it, with `opts.disambiguation`, so a day
--- across a change of offset is not 86400 seconds. A local time reached
--- that the zone passes twice is the moment with `ns`'s own offset when
--- one of the two has it, whatever the disambiguation. Nil and why when the
--- day the years and months reach is past its month's end and
--- `opts.overflow` is not "clamp", when the local time reached is in a
--- gap or a fold the disambiguation refuses, when a field is not an
--- integer or is past its bound (which only keeps the arithmetic from
--- wrapping), or when the result is outside the range. Raises for an
--- `overflow` or a `disambiguation` that is none of its type's. An
--- exact duration needs no call: add its nanoseconds.
function Time.add_calendar(ns: integer, change: Time.Change,
    opts?: Time.AddOptions): integer | nil, string
  local years, months, days = change.years or 0, change.months or 0, change.days or 0
  local why = outside("years", years, -10000, 10000) or outside("months", months, -120000, 120000)
    or outside("days", days, -3650000, 3650000)
  if why ~= nil then return nil, why end
  local overflow = opts ~= nil and opts.overflow or "reject"
  if overflow ~= "reject" and overflow ~= "clamp" then
    error("time: overflow is \"reject\" or \"clamp\", not " .. tostring(overflow), 2)
  end
  local zone = opts ~= nil and opts.zone or nil
  local how = opts ~= nil and opts.disambiguation or "reject"
  if not DISAMBIGUATIONS[how] then
    error("time: disambiguation is \"reject\", \"earlier\", \"later\" or \"compatible\", not " ..
      tostring(how), 2)
  end
  local c = Time.civil(ns, zone)
  local index = c.year * 12 + (c.month - 1) + years * 12 + months
  c.year, c.month = index // 12, index % 12 + 1
  local last = month_days(c.year, c.month)
  if c.day > last then
    if overflow ~= "clamp" then
      return nil, ("%04d-%02d has no day %d; overflow \"clamp\" takes its last"):format(
        c.year, c.month, c.day)
    end
    c.day = last
  end
  local moved = civil_from_days(days_from_civil(c.year, c.month, c.day) + days)
  c.year, c.month, c.day = moved.year, moved.month, moved.day
  -- The offset of the moment moved from still chooses, when the local
  -- time reached is passed twice and one of the two has it -- cosmic's
  -- own choice: Temporal resolves a nonzero amount "compatible", taking
  -- the earlier -- so an amount of nothing moves nothing, even in a fold.
  return Time.from_civil(c, zone, { disambiguation = how })
end

--- The seconds of `ns` on the calendar of `zone`, UTC's when nil.
local function local_seconds(ns: integer, zone: Time.Zone): integer
  local s = ns // NS
  if zone == nil then return s end
  return s + kind_at(rules_for(zone), s).offset
end

--- Whole days from `from`'s date to `to`'s, on the calendar of `zone`
--- (UTC's by default), negative when `to`'s is earlier; the time of day
--- does not count.
function Time.days_between(from: integer, to: integer, zone?: Time.Zone): integer
  return local_seconds(to, zone) // DAY - local_seconds(from, zone) // DAY
end

--- Whole calendar months from `from` to `to`, negative when `to` is
--- earlier, as Java's `ChronoUnit.MONTHS.between` counts them on the
--- calendar of `zone`, UTC's by default: `to`'s date steps a day toward
--- `from`'s when its local time of day has not reached `from`'s, then a
--- month counts once the day of the month does. January 31 to February
--- 29 is 0; to March 31, 2. Whole years are this divided by 12,
--- truncated toward zero.
function Time.months_between(from: integer, to: integer, zone?: Time.Zone): integer
  local a_s, b_s = local_seconds(from, zone), local_seconds(to, zone)
  local a_day, b_day = a_s // DAY, b_s // DAY
  local a_time, b_time = a_s % DAY * NS + from % NS, b_s % DAY * NS + to % NS
  if b_day > a_day and b_time < a_time then
    b_day = b_day - 1
  elseif b_day < a_day and b_time > a_time then
    b_day = b_day + 1
  end
  local a, b = civil_from_days(a_day), civil_from_days(b_day)
  local packed = ((b.year * 12 + b.month) * 32 + b.day) - ((a.year * 12 + a.month) * 32 + a.day)
  -- Toward zero, as Java's integer division.
  return packed >= 0 and packed // 32 or -((-packed) // 32)
end

--- `ns` as RFC 3339 text, `2026-09-25T04:09:21Z` in UTC, with a fraction
--- as `opts.digits` says (`2026-09-25T04:09:21.5Z` by default). With
--- `opts.zone`, the zone's local time and its offset,
--- `2026-09-25T00:09:21-04:00`, and with `opts.zone_name` its IANA name
--- after, as RFC 9557 has it: `2026-09-25T00:09:21-04:00[America/New_York]`.
--- An offset with seconds (local mean time's, before a zone kept
--- standard time) is rounded to the minute, with the local time moved
--- to match, so the text still names `ns`. A cut in the range's first
--- second names a moment before it, which `parse_rfc3339` refuses.
--- Raises when `digits` is not 0 through 9, when `zone_name` is set
--- without a zone or for one with no IANA name, or for a `zone` no
--- function here made.
function Time.format_rfc3339(ns: integer, opts?: Time.FormatOptions): string
  local digits = opts ~= nil and opts.digits or nil
  if digits ~= nil and outside("digits", digits, 0, 9) ~= nil then
    error("time: " .. outside("digits", digits, 0, 9), 2)
  end
  local zone = opts ~= nil and opts.zone or nil
  local zone_name = opts ~= nil and opts.zone_name or false
  local s, n = ns // NS, ns % NS
  local shift, tail = 0, "Z"
  if zone ~= nil then
    local rules = rules_for(zone)
    shift = whole_minutes(kind_at(rules, s).offset)
    tail = offset_text(shift)
    if zone_name then
      if not rules.named then
        error(("time: zone %q has no IANA name for zone_name to write"):format(rules.name), 2)
      end
      tail = tail .. "[" .. rules.name .. "]"
    end
  elseif zone_name then
    error("time: zone_name writes the name of opts.zone, and there is none", 2)
  end
  local c = civil_at(s + shift, n)
  local fraction = ("%09d"):format(c.nanosecond)
  if digits == nil then
    fraction = fraction:gsub("0+$", "")
  else
    fraction = fraction:sub(1, digits)
  end
  return ("%04d-%02d-%02dT%02d:%02d:%02d%s%s%s"):format(c.year, c.month, c.day,
    c.hour, c.minute, c.second, fraction ~= "" and "." or "", fraction, tail)
end

--- The integer the `count` ASCII digits at `at` in `text` spell, or nil.
local function digits_at(text: string, at: integer, count: integer): integer
  local n = 0
  for i = at, at + count - 1 do
    local b = text:byte(i)
    if b == nil or b < 48 or b > 57 then return nil end
    n = n * 10 + (b - 48)
  end
  return n
end

--- The integer the `count` digits at `at` in `text` spell, or nil and
--- that the field `name` is not there.
local function field(text: string, at: integer, count: integer, name: string): integer | nil, string
  local n = digits_at(text, at, count)
  if n == nil then
    return nil, ("%s: expected %d digits at byte %d"):format(name, count, at)
  end
  return n, ""
end

--- Nil when `text` holds `want` at `at`, where `t` stands for `T`, or
--- why not.
local function byte_is(text: string, at: integer, want: string, name: string): string
  local got = text:sub(at, at + #want - 1)
  if got ~= want and not (want == "T" and got == "t") then
    return ("expected %q %s at byte %d"):format(want, name, at)
  end
  return nil
end

--- The index in `names` of the name at `at` in `text`, or nil and that
--- `what` is not there.
local function name_at(text: string, at: integer, names: {string}, what: string): integer | nil, string
  for i, name in ipairs(names) do
    if text:sub(at, at + #name - 1) == name then return i, "" end
  end
  return nil, ("expected %s at byte %d"):format(what, at)
end

--- `YYYY-MM-DD` at the start of `text` into `c`, or why not.
local function date_into(text: string, c: Time.Civil): string
  local why: string
  c.year, why = field(text, 1, 4, "year")
  if c.year == nil then return why end
  why = byte_is(text, 5, "-", "after the year")
  if why ~= nil then return why end
  c.month, why = field(text, 6, 2, "month")
  if c.month == nil then return why end
  why = byte_is(text, 8, "-", "after the month")
  if why ~= nil then return why end
  c.day, why = field(text, 9, 2, "day")
  if c.day == nil then return why end
  return nil
end

--- `hh:mm:ss` at `at` in `text` into `c`, or why not.
local function clock_into(text: string, at: integer, c: Time.Civil): string
  local why: string
  c.hour, why = field(text, at, 2, "hour")
  if c.hour == nil then return why end
  why = byte_is(text, at + 2, ":", "after the hour")
  if why ~= nil then return why end
  c.minute, why = field(text, at + 3, 2, "minute")
  if c.minute == nil then return why end
  why = byte_is(text, at + 5, ":", "after the minute")
  if why ~= nil then return why end
  c.second, why = field(text, at + 6, 2, "second")
  if c.second == nil then return why end
  if c.second == 60 then return "second 60 is not 0 through 59: cosmic time has no leap seconds" end
  return nil
end

--- Why the RFC 9557 suffix tag `body`, the text between one `[` and
--- its `]` less a leading `!`, is no `key=value`, or nil when it is one.
local function tag_problem(body: string): string
  local key = body:match("^([a-z_][a-z0-9_%-]*)=")
  if key == nil then return "expected a key of lowercase letters, digits, \"_\" and \"-\"" end
  local value = body:sub(#key + 2)
  if value == "" or value:find("[^%w%-]") ~= nil or value:sub(1, 1) == "-" or
      value:sub(-1) == "-" or value:find("--", 1, true) ~= nil then
    return ("%s's value %q is not letters and digits joined by \"-\""):format(key, value)
  end
  return nil
end

--- RFC 3339 text and its RFC 9557 suffix: `parse_rfc3339`'s and
--- `parse_rfc3339_zoned`'s work.
--- The offset `+hh:mm` or `-hh:mm` at `at` in `text` spells, in seconds
--- east of UTC, or nil and why not: hours through 23, minutes through 59.
local function offset_at(text: string, at: integer, what: string): integer | nil, string
  local sign = text:sub(at, at)
  if sign ~= "+" and sign ~= "-" then
    return nil, ("expected \"+\" or \"-\" to begin %s at byte %d"):format(what, at)
  end
  local hours, minutes: integer, integer
  local why: string
  hours, why = field(text, at + 1, 2, what .. "'s hour")
  if hours == nil then return nil, why end
  why = byte_is(text, at + 3, ":", "in " .. what)
  if why ~= nil then return nil, why end
  minutes, why = field(text, at + 4, 2, what .. "'s minute")
  if minutes == nil then return nil, why end
  why = outside(what .. "'s hour", hours, 0, 23) or outside(what .. "'s minute", minutes, 0, 59)
  if why ~= nil then return nil, why end
  local offset = (hours * 60 + minutes) * 60
  return sign == "-" and -offset or offset, ""
end

--- The zones a numeric RFC 9557 suffix names, by offset: each always
--- that offset, named as the suffix spells it.
local fixed: {integer:Time.Zone} = {}

local function fixed_zone(offset: integer): Time.Zone
  local zone = fixed[offset]
  if zone == nil then
    local name = offset_text(offset)
    zone = make_zone(name, { transitions = {}, kinds = {},
      first = { offset = offset, abbreviation = name, dst = false }, named = true })
    fixed[offset] = zone
  end
  return zone
end

local function parse(text: string): Time.Zoned | nil, string
  local c: Time.Civil = {}
  local why = date_into(text, c)
  if why ~= nil then return nil, why end
  why = byte_is(text, 11, "T", "between the date and the time")
  if why ~= nil then return nil, why end
  why = clock_into(text, 12, c)
  if why ~= nil then return nil, why end
  c.nanosecond = 0
  local at = 20
  if text:sub(at, at) == "." then
    local first = at + 1
    at = first
    while digits_at(text, at, 1) ~= nil do at = at + 1 end
    local count = at - first
    if count == 0 or count > 9 then
      return nil, ("fraction at byte %d: expected 1 to 9 digits, not %d"):format(first, count)
    end
    c.nanosecond = digits_at(text, first, count)
    for _ = count + 1, 9 do c.nanosecond = c.nanosecond * 10 end
  end
  local offset = 0
  -- `Z` and `-00:00` say the local offset is unknown (RFC 9557 2.2), so
  -- a zone after either is not held to the offset.
  local unknown = true
  local mark = text:sub(at, at)
  if mark == "Z" or mark == "z" then
    at = at + 1
  elseif mark == "+" or mark == "-" then
    local read, offset_why = offset_at(text, at, "the offset")
    if read == nil then return nil, offset_why end
    offset = read
    unknown = mark == "-" and offset == 0
    at = at + 6
  else
    return nil, ("expected \"Z\" or an offset at byte %d"):format(at)
  end
  local ns, range_why = moment(c, offset)
  if ns == nil then return nil, range_why end
  local zoned: Time.Zoned = { ns = ns }
  local first = true
  while text:sub(at, at) == "[" do
    local close = text:find("]", at + 1, true)
    if close == nil then return nil, ("suffix at byte %d: no \"]\" closes it"):format(at) end
    local body = text:sub(at + 1, close - 1)
    local critical = body:sub(1, 1) == "!"
    if critical then body = body:sub(2) end
    if body:find("=", 1, true) ~= nil then
      local problem = tag_problem(body)
      if problem ~= nil then return nil, ("suffix at byte %d: %s"):format(at, problem) end
      if critical then
        return nil, ("suffix at byte %d: [!%s] is critical, and cosmic knows no such tag"):format(at,
          body)
      end
    elseif not first then
      return nil, ("suffix at byte %d: a time zone comes first, before any tag, and once"):format(at)
    elseif body:find("^[+-]") ~= nil then
      local annotated, annotated_why = offset_at(body, 1, "the suffix's offset")
      if annotated == nil or #body ~= 6 then
        return nil, ("suffix at byte %d: %s"):format(at, annotated_why ~= "" and annotated_why or
          "expected an offset as +hh:mm")
      end
      if not unknown and annotated ~= offset then
        return nil, ("offset %s does not match the suffix's, %s"):format(offset_text(offset),
          offset_text(annotated))
      end
      zoned.zone = fixed_zone(annotated)
    else
      local problem = name_problem(body)
      if problem == nil and not writable(body) then
        problem = ("zone name %q has a part that does not begin with a letter, \".\" or \"_\""):format(
          body)
      end
      if problem ~= nil then return nil, ("suffix at byte %d: %s"):format(at, problem) end
      local zone, zone_why = Time.zone(body)
      if zone == nil then return nil, ("suffix at byte %d: %s"):format(at, zone_why) end
      if not unknown then
        local want = whole_minutes(kind_at(rules_for(zone), ns // NS).offset)
        if want ~= offset then
          return nil, ("offset %s is not %s's at that moment, %s"):format(offset_text(offset),
            body, offset_text(want))
        end
      end
      zoned.zone = zone
    end
    first = false
    at = close + 1
  end
  if at <= #text then
    return nil, ("unexpected text at byte %d"):format(at)
  end
  return zoned, ""
end

--- The nanoseconds an RFC 3339 timestamp names, as
--- `2026-09-25T04:09:21.5+05:30`: `T` or `t` between date and time, one
--- to nine digits of fraction, and `Z`, `z` or a numeric offset, where
--- `-00:00` is UTC too. An RFC 9557 suffix may follow: a zone,
--- `[America/New_York]` (or `[!America/New_York]`) or an offset,
--- `[+05:30]`, then any elective
--- `[key=value]` tags, which are ignored. The offset still names the
--- moment, and must be the zone's then, to the minute, unless it is `Z`
--- or `-00:00`, which say the local offset is unknown. Nil and why for
--- anything else, a leap second, a moment outside the range, a zone
--- neither the host nor the binary has, an offset the zone does not
--- have then, or a critical `[!key=value]` tag.
function Time.parse_rfc3339(text: string): integer | nil, string
  local zoned, why = parse(text)
  if zoned == nil then return nil, why end
  return zoned.ns, ""
end

--- `parse_rfc3339`'s moment, with the zone its suffix names -- for an
--- offset, `[+05:30]`, a zone always that offset, named "+05:30" -- and
--- nil when the text names none.
function Time.parse_rfc3339_zoned(text: string): Time.Zoned | nil, string
  return parse(text)
end

--- `ns`'s date on the calendar of `zone`, UTC's by default,
--- `2026-09-25`. Raises for a `zone` no function here made.
function Time.format_date(ns: integer, zone?: Time.Zone): string
  local c = Time.civil(ns, zone)
  return ("%04d-%02d-%02d"):format(c.year, c.month, c.day)
end

--- The first moment of the date `YYYY-MM-DD` names, as `2026-09-25`, on
--- the calendar of `zone`, UTC's by default, as Temporal's `startOfDay`
--- has it: its midnight -- the earlier, where midnight happens twice --
--- or, where the zone's clocks skipped midnight, the moment they
--- moved, which is the first the day has (Toronto's 1919-03-31 began at
--- 00:30-04:00). A day a zone skipped whole begins where the next one
--- does, so `format_date` of it can name the next day (Apia's
--- 2011-12-30 answers 2011-12-31's first moment). Nil and why for
--- anything else, a day its month does not have, or a date whose first
--- moment is outside the range, as the range's first, 1677-09-21, in
--- UTC. Raises for a `zone` no function here made.
function Time.parse_date(text: string, zone?: Time.Zone): integer | nil, string
  local c: Time.Civil = { hour = 0, minute = 0, second = 0, nanosecond = 0 }
  local why = date_into(text, c)
  if why ~= nil then return nil, why end
  if #text > 10 then return nil, "unexpected text at byte 11" end
  if zone == nil then return moment(c, 0) end
  local rules = rules_for(zone)
  local midnight, midnight_why = seconds_of(c)
  if midnight == nil then return nil, midnight_why end
  local earliest, earliest_why = Time.from_civil(c, zone, { disambiguation = "earlier" })
  if earliest == nil then return nil, earliest_why end
  local lo = earliest // NS
  if lo + kind_at(rules, lo).offset == midnight then return earliest, "" end
  -- Skipped: `lo`, before the gap, is still the day before; find the
  -- first second whose local time has reached the day.
  local hi = lo + 2 * DAY
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if mid + kind_at(rules, mid).offset >= midnight then hi = mid else lo = mid end
  end
  return instant(hi, 0)
end

local SHORT_DAYS <const> = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local LONG_DAYS <const> = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  "Sunday" }
local MONTHS <const> = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
  "Nov", "Dec" }

--- `ns` as an HTTP date, RFC 9110's IMF-fixdate: `Fri, 25 Sep 2026
--- 05:22:21 GMT`, the fraction of a second cut toward the past. A cut
--- in the range's first second names a moment before it, which
--- `parse_http` refuses.
function Time.format_http(ns: integer): string
  local c = Time.civil(ns)
  return ("%s, %02d %s %04d %02d:%02d:%02d GMT"):format(SHORT_DAYS[c.weekday], c.day,
    MONTHS[c.month], c.year, c.hour, c.minute, c.second)
end

--- The nanoseconds an HTTP date names, in any of RFC 9110's three forms
--- (section 5.6.7): IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`; the
--- obsolete RFC 850 form, `Sunday, 06-Nov-94 08:49:37 GMT`; and
--- asctime's, `Sun Nov  6 08:49:37 1994`, whose day is two digits or
--- a space and one. Names are case-sensitive, as the grammar has them.
--- The day name must be one of the seven, in its form's length, but
--- need not be the date's: `Mon, 26 Jul 1997 05:00:00 GMT`, a Saturday,
--- is read as its date says, as recipients commonly do. An RFC 850 year
--- of 69 through 99 is 1969 through 1999 and one of 00 through 68 is
--- 2000 through 2068, as POSIX's `%y`, so the answer does not hang on
--- the clock as RFC 9110's fifty years ahead would. Nil and why for
--- anything else, a leap second, or a moment outside the range.
function Time.parse_http(text: string): integer | nil, string
  local c: Time.Civil = { nanosecond = 0 }
  local day_name, why: integer, string
  local stop: integer
  local separator = text:sub(4, 4)
  if separator == "," then
    day_name, why = name_at(text, 1, SHORT_DAYS, "a day name")
    if day_name == nil then return nil, why end
    why = byte_is(text, 4, ", ", "after the day name")
    if why ~= nil then return nil, why end
    c.day, why = field(text, 6, 2, "day")
    if c.day == nil then return nil, why end
    why = byte_is(text, 8, " ", "after the day")
    if why ~= nil then return nil, why end
    c.month, why = name_at(text, 9, MONTHS, "a month name")
    if c.month == nil then return nil, why end
    why = byte_is(text, 12, " ", "after the month")
    if why ~= nil then return nil, why end
    c.year, why = field(text, 13, 4, "year")
    if c.year == nil then return nil, why end
    why = byte_is(text, 17, " ", "after the year")
      or clock_into(text, 18, c)
      or byte_is(text, 26, " GMT", "after the time")
    if why ~= nil then return nil, why end
    stop = 29
  elseif separator == " " then
    day_name, why = name_at(text, 1, SHORT_DAYS, "a day name")
    if day_name == nil then return nil, why end
    c.month, why = name_at(text, 5, MONTHS, "a month name")
    if c.month == nil then return nil, why end
    why = byte_is(text, 8, " ", "after the month")
    if why ~= nil then return nil, why end
    if text:sub(9, 9) == " " then
      c.day, why = field(text, 10, 1, "day")
    else
      c.day, why = field(text, 9, 2, "day")
    end
    if c.day == nil then return nil, why end
    why = byte_is(text, 11, " ", "after the day")
      or clock_into(text, 12, c)
      or byte_is(text, 20, " ", "after the time")
    if why ~= nil then return nil, why end
    c.year, why = field(text, 21, 4, "year")
    if c.year == nil then return nil, why end
    stop = 24
  else
    day_name, why = name_at(text, 1, LONG_DAYS, "a day name")
    if day_name == nil then return nil, why end
    local at = #LONG_DAYS[day_name] + 1
    why = byte_is(text, at, ", ", "after the day name")
    if why ~= nil then return nil, why end
    c.day, why = field(text, at + 2, 2, "day")
    if c.day == nil then return nil, why end
    why = byte_is(text, at + 4, "-", "after the day")
    if why ~= nil then return nil, why end
    c.month, why = name_at(text, at + 5, MONTHS, "a month name")
    if c.month == nil then return nil, why end
    why = byte_is(text, at + 8, "-", "after the month")
    if why ~= nil then return nil, why end
    c.year, why = field(text, at + 9, 2, "year")
    if c.year == nil then return nil, why end
    c.year = c.year + (c.year >= 69 and 1900 or 2000)
    why = byte_is(text, at + 11, " ", "after the year")
      or clock_into(text, at + 12, c)
      or byte_is(text, at + 20, " GMT", "after the time")
    if why ~= nil then return nil, why end
    stop = at + 23
  end
  if #text > stop then
    return nil, ("unexpected text at byte %d"):format(stop + 1)
  end
  return moment(c, 0)
end

--- The wall clock in nanoseconds, which can step backwards when the host
--- adjusts it. Unlike os.time, it is not calendar seconds: `civil` and
--- `format_rfc3339` name it on the UTC calendar. Raises when the clock
--- cannot be read, which a host that runs cosmic at all never refuses.
function Time.now_ns(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_REALTIME)
  if reading == nil then
    error("clock_gettime(CLOCK_REALTIME): " .. trouble, 2)
  end
  return reading
end

--- A clock that only moves forward, for measuring elapsed duration in
--- nanoseconds. Use it for timing in place of os.clock; it measures wall
--- duration rather than process CPU time. Raises when the clock cannot
--- be read, which a host that runs cosmic at all never refuses.
function Time.monotonic_ns(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if reading == nil then
    error("clock_gettime(CLOCK_MONOTONIC): " .. trouble, 2)
  end
  return reading
end

--- Sleeps, as `sleep` or `nanosleep` does, resuming the wait when a
--- signal interrupts it.
function Time.sleep_ns(nanoseconds: integer): boolean, string
  local ok, trouble = sys.nanosleep(nanoseconds)
  if not ok then
    return false, trouble
  end
  return true, ""
end

return Time
