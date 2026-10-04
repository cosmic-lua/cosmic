--- The calendar, in UTC and in time zones, and the clocks and spans of
--- [`cosmic.clock`], answered here under the same names. Every reading
--- is in nanoseconds, so nothing above this module carries a unit it has
--- to remember. A moment is an integer of nanoseconds since
--- 1970-01-01T00:00:00Z without leap seconds, so the calendar spans
--- what 64 bits hold: 1677-09-21T00:12:43.145224192Z through
--- 2262-04-11T23:47:16.854775807Z, on the proleptic Gregorian calendar.
---
--- A span of exact time is an integer of nanoseconds too, which [`ms`],
--- [`seconds`], [`minutes`] and [`hours`] make from a count
--- (`Time.seconds(5)`). The clocks and these constructors live in
--- [`cosmic.clock`], which a module that needs no calendar requires
--- instead; this module keeps them as aliases. A span the calendar
--- measures, whole years, months and days and a remainder, is a
--- [`Duration`]. [`add_calendar`] moves a moment by one, [`between`]
--- answers one, and [`parse_duration`] and [`format_duration`] read and
--- write one as text.
---
--- A zone says what offset from UTC, abbreviation and daylight saving
--- time each moment has somewhere: IANA's, by name (`zone`), from the
--- copy of the tz database the binary carries -- never the host's zone
--- files, so a name means the same rules on every host; the host's own
--- ([`local_zone`]), the carried zone `TZ`, /etc/localtime or
--- /etc/timezone names, or the POSIX TZ string `TZ` holds; or one read
--- from TZif bytes (RFC 8536).
---
--- Every function that reads or writes the calendar takes its zone
--- right after the data it works on, and its options last:
--- `civil(ns, zone?)`, `from_civil(c, zone?, opts?)`,
--- `add_calendar(ns, duration, zone?, opts?)`, `between(from, to,
--- zone?)` and `format_rfc3339(ns, zone?, opts?)`. Each reads the UTC
--- calendar without a zone.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local String = require("cosmic.string")
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
    --- Nanoseconds after the second, 0 through 999999999.
    ns: integer
    --- ISO 8601's: 1 (Monday) through 7 (Sunday). [`from_civil`] ignores it.
    weekday: integer
    --- The day of the year, 1 through 366. [`from_civil`] ignores it.
    yday: integer
    --- Seconds east of UTC the local time is: 0 on the UTC calendar.
    --- [`from_civil`] reads it only to choose between the two moments a
    --- zone gives one local time when its clocks go back.
    offset: integer
    --- What the zone calls its time then, as "EDT"; "UTC" on the UTC
    --- calendar. [`from_civil`] ignores it.
    abbreviation: string
    --- Whether the zone counts it daylight saving time. [`from_civil`]
    --- ignores it.
    dst: boolean
  end

  --- A time zone: the offset from UTC, abbreviation and daylight saving
  --- time it gives each moment. `zone`, [`local_zone`] and
  --- [`zone_from_tzif`] make one; a table made by hand is refused.
  record Zone
    --- IANA's name for it, as "America/New_York" -- the one
    --- [`format_rfc3339`]'s `zone_name` writes -- or else the POSIX TZ
    --- string it was read from, or the name [`zone_from_tzif`] was given.
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

  --- What [`add_calendar`] does with a day its month does not have, as
  --- January 31 plus a month: "reject" refuses it, "clamp" takes the
  --- month's last day.
  enum Overflow
    "reject"
    "clamp"
  end

  --- What [`from_civil`] and [`add_calendar`], the functions that build
  --- or move a moment, may be told beside the zone they take as an
  --- argument. Every field is optional, and a function reads only the
  --- fields it has use for.
  record AddOptions
    --- For a local time in a gap or a fold of the zone; "reject" when
    --- absent.
    disambiguation: Time.Disambiguation
    --- Only [`add_calendar`] reads it: "reject" when absent.
    overflow: Time.Overflow
  end

  --- What [`format_rfc3339`] may be told. Every field is optional.
  record FormatOptions
    --- Digits of fraction to write, 0 through 9, cut toward the past; by
    --- default as many as the nanoseconds need, none when they are zero.
    digits: integer
    --- Also write the zone's IANA name after the offset, as RFC 9557
    --- does: `[America/New_York]`.
    zone_name: boolean
  end

  --- What [`local_zone`] reads in place of the host's.
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

  --- A moment read from RFC 3339 text, and the zone it names.
  record Zoned
    --- The moment, in nanoseconds since the Unix epoch.
    ns: integer
    --- The zone its RFC 9557 suffix names or, with none, its offset's:
    --- a zone always that offset, named "+05:30". UTC for `Z` and
    --- `-00:00`, which say the local offset is unknown.
    zone: Time.Zone
  end

  --- A span of time as people write it, `1y2mo3d4h5m6s`: a calendar
  --- part, which [`add_calendar`] moves along a calendar, and an exact
  --- part in nanoseconds. Every field has the duration's one sign: a
  --- negative duration has each field at most zero. A missing field is
  --- zero.
  record Duration
    --- Whole years of the calendar part.
    years: integer
    --- Whole months of the calendar part.
    months: integer
    --- Whole days of the calendar part.
    days: integer
    --- The hours, minutes and seconds, as nanoseconds. [`between`]'s can
    --- exceed a day, where the day step would overshoot into a fold or a
    --- skipped day.
    ns: integer
  end

  --- Coordinated Universal Time, the zone every other is an offset from.
  UTC: Time.Zone

  --- [`cosmic.clock`]'s [`Clock.now_ns`], kept here under its old name.
  now_ns: function(): integer
  --- [`cosmic.clock`]'s [`Clock.monotonic_ns`], kept here under its old name.
  monotonic_ns: function(): integer
  --- [`cosmic.clock`]'s [`Clock.sleep_ns`], kept here under its old name.
  sleep_ns: function(integer): boolean, string
  --- [`cosmic.clock`]'s [`Clock.ms`], kept here under its old name.
  ms: function(number): integer
  --- [`cosmic.clock`]'s [`Clock.seconds`], kept here under its old name.
  seconds: function(number): integer
  --- [`cosmic.clock`]'s [`Clock.minutes`], kept here under its old name.
  minutes: function(number): integer
  --- [`cosmic.clock`]'s [`Clock.hours`], kept here under its old name.
  hours: function(number): integer
  --- [`cosmic.clock`]'s [`Clock.ceil`], kept here under its old name.
  ceil: function(integer, integer): integer
end

local NS <const> = 1000000000
local DAY <const> = 86400

--- The first and last moments an integer holds, as whole seconds and the
--- nanoseconds past them.
local MIN_S <const> = math.mininteger // NS
local MIN_NS <const> = math.mininteger % NS
local MAX_S <const> = math.maxinteger // NS
local MAX_NS <const> = math.maxinteger % NS
--- What a failure of this module answers, nil and `why` under the
--- module's name. Only a public function answers through it: the
--- private readers (the parsers, the TZif reader, the zone cache) answer
--- a bare `why`, so a message that quotes one -- a zone's, the footer's --
--- is not prefixed twice.
local function refuse(why: string): nil, string
  return nil, "time: " .. why
end

local RANGE <const> = "outside 1677-09-21T00:12:43.145224192Z through " ..
  "2262-04-11T23:47:16.854775807Z, what an integer of nanoseconds holds"

--- Days since 1970-01-01 of a proleptic Gregorian date: Howard Hinnant's
--- [`days_from_civil`], with floor division.
local function days_from_civil(y: integer, m: integer, d: integer): integer
  y = m <= 2 and y - 1 or y
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (m > 2 and m - 3 or m + 9) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

--- The inverse of [`days_from_civil`]: Hinnant's [`civil_from_days`].
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

--- Raises, blaming the caller of the public function that calls this, for
--- a field `name` whose `value` is no integer: a float such as 2026.0, or
--- an absent field.
local function integral(name: string, value: any)
  if math.type(value) ~= "integer" then
    error(("time: %s is not an integer: %s %s"):format(name, math.type(value) or type(value),
      tostring(value)), 3)
  end
end

--- The seconds the fields of `c` name on the UTC calendar, or nil and
--- which field is wrong. A year either side of the range is let through,
--- so an offset can still reach the range's edges.
local function seconds_of(c: Time.Civil): integer | nil, string
  local why = outside("year", c.year, math.mininteger, math.maxinteger) or
    outside("month", c.month, 1, 12)
  if why ~= nil then return nil, why end
  if c.year < 1676 or c.year > 2263 then return nil, RANGE end
  why = outside("day", c.day, 1, month_days(c.year, c.month)) or
    outside("hour", c.hour, 0, 23) or
    outside("minute", c.minute, 0, 59) or
    outside("second", c.second, 0, 59) or
    outside("ns", c.ns, 0, NS - 1)
  if why ~= nil then return nil, why end
  return days_from_civil(c.year, c.month, c.day) * DAY +
    c.hour * 3600 + c.minute * 60 + c.second, ""
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
  return instant(s - offset, c.ns)
end

--- The calendar fields of `s` seconds and `n` nanoseconds on the UTC
--- calendar.
local function civil_at(s: integer, n: integer): Time.Civil
  local days, into = s // DAY, s % DAY
  local c = civil_from_days(days)
  c.hour, c.minute, c.second = into // 3600, into % 3600 // 60, into % 60
  c.ns = n
  c.weekday = (days + 3) % 7 + 1
  c.yday = days - days_from_civil(c.year, 1, 1) + 1
  return c
end

-- Text.

--- The nanoseconds the digits of a fraction of a second spell, one to
--- nine of them: `5` is 500000000.
local function fraction_ns(digits: string): integer
  return math.tointeger(tonumber(digits .. ("0"):rep(9 - #digits)))
end

--- The fraction `ns` nanoseconds past a second writes as: with `digits`
--- digits, cut toward the past, or with none given as few as hold it,
--- trailing zeros dropped, and nothing for none.
local function fraction_text(ns: integer, digits?: integer): string
  local text = ("%09d"):format(ns)
  if digits == nil then return (text:gsub("0+$", "")) end
  return text:sub(1, digits)
end

--- What of a calendar moment [`civil_text`] writes.
local enum Part
  --- `2026-09-25`.
  "date"
  --- `04:09:21`.
  "clock"
  --- `2026-09-25T04:09`.
  "minute"
  --- `2026-09-25T04:09:21`.
  "second"
end

--- The `part` of `c`, zero-padded.
local function civil_text(c: Time.Civil, part: Part): string
  local date = ("%04d-%02d-%02d"):format(c.year, c.month, c.day)
  local clock = ("%02d:%02d:%02d"):format(c.hour, c.minute, c.second)
  if part == "date" then return date end
  if part == "clock" then return clock end
  return date .. "T" .. clock:sub(1, part == "minute" and 5 or 8)
end

--- Where a reader of `text` is, and why it stopped, if it has. The
--- first failure is kept and every read after it answers nil and moves
--- nothing, so a run of reads is checked once, by `why`.
local record Cursor
  text: string
  --- The byte the next read starts at.
  at: integer
  --- Why a read failed, with the byte it failed at; nil while none has.
  why: string
  metamethod __close: function(Cursor)
end

--- A cursor over `text`, of its own.
local function cursor(text: string): Cursor
  return { text = text, at = 1 }
end

local byte <const> = string.byte
local sub <const> = string.sub

--- What ends a borrowing: the text is let go, so a large one is not held
--- until the next read.
local lent_mt: metatable<Cursor> = {
  __close = function(cur: Cursor) cur.text = "" end,
}

local lent: Cursor = setmetatable(cursor(""), lent_mt)

--- A cursor over `text` that every caller shares, so the readers that
--- run on every request allocate none; hold it in a `<close>` variable.
--- It is safe because no code a reader calls borrows it again: nothing
--- reachable from `zone` (the store, and the TZif and POSIX readers,
--- which have a [`cursor`] of their own) calls `parse`, [`parse_date`] or
--- [`parse_http`], and the readers never yield. A module loaded in the
--- middle of one that came to call them would corrupt the read.
local function borrow(text: string): Cursor
  lent.text, lent.at, lent.why = text, 1, nil
  return lent
end

--- Fails the cursor with `why`, unless it has failed already.
local function fail(cur: Cursor, why: string)
  if cur.why == nil then cur.why = why end
end

--- The integer of the `most` ASCII digits at the cursor, or of at least
--- `least` and at most `most` of them when `least` is given, naming the
--- field `what` where it fails.
local function read_digits(cur: Cursor, most: integer, what: string, least?: integer): integer
  if cur.why ~= nil then return nil end
  local text, first = cur.text, cur.at
  local at, n = first, 0
  local stop = first + most
  while at < stop do
    local b = byte(text, at)
    if b == nil or b < 48 or b > 57 then break end
    n = n * 10 + (b - 48)
    at = at + 1
  end
  if at - first < (least or most) then
    fail(cur, ("%s: expected %s at byte %d"):format(what, least == nil and
        String.counted(most, "digit") or "a number", first))
    return nil
  end
  cur.at = at
  return n
end

--- Moves past `want`, which the text must hold here, or fails naming
--- what it stands for (`what`). A `T` is read as `t` too.
local function expect(cur: Cursor, want: string, what: string)
  if cur.why ~= nil then return end
  local at = cur.at
  local got = sub(cur.text, at, at + #want - 1)
  if got ~= want and not (want == "T" and got == "t") then
    fail(cur, ("expected %q %s at byte %d"):format(want, what, at))
    return
  end
  cur.at = at + #want
end

--- Moves past `want` and answers true when the text holds it here.
local function accept(cur: Cursor, want: string): boolean
  local at = cur.at
  if cur.why ~= nil or sub(cur.text, at, at + #want - 1) ~= want then return false end
  cur.at = at + #want
  return true
end

--- The index in `names` of the one the text holds here, moved past, or
--- a failure that `what` is not there.
local function name_of(cur: Cursor, names: {string}, what: string): integer
  if cur.why ~= nil then return nil end
  local text, at = cur.text, cur.at
  for i, name in ipairs(names) do
    if sub(text, at, at + #name - 1) == name then
      cur.at = at + #name
      return i
    end
  end
  fail(cur, ("expected %s at byte %d"):format(what, at))
  return nil
end

--- The nanoseconds of the one to nine digits of a fraction here.
local function read_fraction(cur: Cursor): integer
  if cur.why ~= nil then return nil end
  local digits = cur.text:match("^%d*", cur.at)
  if #digits == 0 or #digits > 9 then
    fail(cur, ("fraction at byte %d: expected 1 to 9 digits, not %d"):format(cur.at, #digits))
    return nil
  end
  cur.at = cur.at + #digits
  return fraction_ns(digits)
end

--- Fails when any text is left past the cursor.
local function finish(cur: Cursor)
  if cur.why == nil and cur.at <= #cur.text then
    fail(cur, ("unexpected text at byte %d"):format(cur.at))
  end
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
  --- The zone's name: what [`Zone.name`] reads, and what every message
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

--- The zone a POSIX TZ string's rules make, with no transitions of its
--- own: `p` holds every moment.
local function posix_zone(tz: string, p: Posix): Time.Zone
  return make_zone(tz, { transitions = {}, kinds = {}, first = p.std, footer = p, named = false })
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

--- A POSIX TZ string as a [`Posix`], or nil and why: `EST5EDT`,
--- `EST5EDT,M3.2.0,M11.1.0`, `<+0330>-3:30`, `AEST-10AEDT,M10.1.0,M4.1.0/3`.
--- An offset is west of UTC, as POSIX has it, through 24 hours; a rule's
--- time may be negative and through 167 hours, as RFC 8536's version 3
--- allows. Daylight saving time with no rules takes the United States'
--- since 2007, `M3.2.0,M11.1.0`, as glibc and tzcode do.
local function parse_posix(tz: string): Posix | nil, string
  if #tz > 256 then return nil, "a TZ string is at most 256 bytes, not " .. #tz end
  local cur = cursor(tz)

  local function abbreviation(what: string): string
    if cur.why ~= nil then return nil end
    local first = cur.at
    if tz:sub(first, first) == "<" then
      local close = tz:find(">", first + 1, true)
      if close == nil then
        fail(cur, ("%s at byte %d: no \">\" closes it"):format(what, first))
        return nil
      end
      local body = tz:sub(first + 1, close - 1)
      if #body < 3 or body:find("[^%w+%-]") ~= nil then
        fail(cur, ("%s at byte %d: expected three or more letters, digits, \"+\" or \"-\" " ..
          "between \"<\" and \">\""):format(what, first))
        return nil
      end
      cur.at = close + 1
      return body
    end
    local last = first
    while tz:find("^[A-Za-z]", last) ~= nil do last = last + 1 end
    if last - first < 3 then
      fail(cur, ("%s at byte %d: expected three or more letters"):format(what, first))
      return nil
    end
    cur.at = last
    return tz:sub(first, last - 1)
  end

  local function number(most: integer, lo: integer, hi: integer, what: string): integer
    local first = cur.at
    local n = read_digits(cur, most, what, 1)
    if n ~= nil and (n < lo or n > hi) then
      fail(cur, ("%s %d at byte %d is not %d through %d"):format(what, n, first, lo, hi))
      return nil
    end
    return n
  end

  -- [+-]hh[:mm[:ss]], as seconds.
  local function duration(hours: integer, what: string): integer
    local sign = accept(cur, "-") and -1 or 1
    if sign == 1 then accept(cur, "+") end
    local h = number(3, 0, hours, what .. "'s hours")
    local m, sec = 0, 0
    if accept(cur, ":") then
      m = number(2, 0, 59, what .. "'s minutes")
      if accept(cur, ":") then sec = number(2, 0, 59, what .. "'s seconds") end
    end
    if cur.why ~= nil then return nil end
    return sign * (h * 3600 + m * 60 + sec)
  end

  local function rule(what: string): Rule
    local r: Rule = { time = 7200 }
    if accept(cur, "J") then
      r.form = "J"
      r.day = number(3, 1, 365, what .. "'s day")
    elseif accept(cur, "M") then
      r.form = "M"
      r.month = number(2, 1, 12, what .. "'s month")
      expect(cur, ".", "after " .. what .. "'s month")
      r.week = number(1, 1, 5, what .. "'s week")
      expect(cur, ".", "after " .. what .. "'s week")
      r.weekday = number(1, 0, 6, what .. "'s weekday")
    else
      r.form = "n"
      r.day = number(3, 0, 365, what .. "'s day")
    end
    if accept(cur, "/") then r.time = duration(167, what .. "'s time") end
    return r
  end

  local std_name = abbreviation("standard time's abbreviation")
  local west = duration(24, "standard time's offset")
  if cur.why ~= nil then return nil, cur.why end
  local p: Posix = { std = { offset = -west, abbreviation = std_name, dst = false }, years = {} }
  if cur.at > #tz then return p, "" end
  local dst_name = abbreviation("daylight saving time's abbreviation")
  if cur.why ~= nil then return nil, cur.why end
  local offset = p.std.offset + 3600
  if cur.at <= #tz and tz:sub(cur.at, cur.at) ~= "," then
    local dst_west = duration(24, "daylight saving time's offset")
    if cur.why ~= nil then return nil, cur.why end
    offset = -dst_west
  end
  p.dst = { offset = offset, abbreviation = dst_name, dst = true }
  if cur.at > #tz then
    p.start = { form = "M", month = 3, week = 2, weekday = 0, time = 7200 }
    p.finish = { form = "M", month = 11, week = 1, weekday = 0, time = 7200 }
    return p, ""
  end
  expect(cur, ",", "before daylight saving time's rules")
  p.start = rule("daylight saving time's start")
  expect(cur, ",", "between daylight saving time's start and end")
  p.finish = rule("daylight saving time's end")
  finish(cur)
  if cur.why ~= nil then return nil, cur.why end
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

--- A TZif file (RFC 8536, versions 1 through 4) as [`Rules`], or nil and
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
    return nil, ("truncated: the data block at byte %d needs %s, and %d remain"):format(at,
      String.counted(length, "byte"), #data - at + 1)
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
    return nil, ("%s past the end, at byte %d"):format(String.counted(#data - at + 1, "byte"), at)
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
  if name == "" then return "the zone name is empty" end
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

--- Why RFC 9557 cannot write `name` in a suffix, or nil when it can: a
--- zone name each of whose parts begins with a letter, `.` or `_` (its
--- `time-zone-initial`).
local function writable_problem(name: string): string
  local problem = name_problem(name)
  if problem ~= nil then return problem end
  for part in (name .. "/"):gmatch("([^/]*)/") do
    if part:find("^[A-Za-z._]") == nil then
      return ("zone name %q has a part that does not begin with a letter, \".\" or \"_\""):format(
        name)
    end
  end
  return nil
end

--- Whether RFC 9557 can write `name` in a suffix ([`writable_problem`]).
local function writable(name: string): boolean
  return writable_problem(name) == nil
end

--- Every zone `zone` has loaded, by name.
local zones: {string:Time.Zone} = {}

--- Why each name `zone` found no zone for was refused, so text naming
--- unknown zones over and over looks none up twice; emptied when it
--- reaches `REFUSED_KEPT` names, which bounds it.
local refused_names: {string:string} = {}
local refused_count = 0
local REFUSED_KEPT <const> = 1024

--- Every zone name the binary carries, read at the first lookup.
local carried_names: {string:boolean} = nil

--- What a zone the carried database lacks says after it: a zone IANA
--- added since the database was built is one a newer database has, and
--- this is how this binary, or a program built with it, gets one.
local NEWER_ZONES <const> = "if the zone is new, `cosmic refresh tzdata --binary <this program> " ..
  "-o <copy>` writes a copy with a newer tz database"

--- The zone `name` names, as [`Time.zone`] answers for a name that is not
--- empty.
local function zone_of(name: string): Time.Zone | nil, string
  local problem = name_problem(name)
  if problem ~= nil then return nil, problem end
  local cached = zones[name]
  if cached ~= nil then return cached, "" end
  local refused = refused_names[name]
  if refused ~= nil then return nil, refused end
  -- Only an answer the database gave is remembered: a query that failed
  -- (EMFILE, a locked file) is this call's failure, and asked again.
  local function remember(why: string): string
    if refused_count >= REFUSED_KEPT then
      refused_names, refused_count = {}, 0
    end
    refused_names[name], refused_count = why, refused_count + 1
    return why
  end
  local Store = require("cosmic.store")
  if carried_names == nil then
    local names, trouble = Store.zone_names()
    if names == nil then return nil, ("time zone %s: %s"):format(name, trouble) end
    carried_names = names
  end
  if not carried_names[name] then
    return nil, remember(("no time zone %s: this binary's tz database has none; %s"):format(
      name, NEWER_ZONES))
  end
  local carried, trouble = Store.zoneinfo(name)
  if carried == nil then return nil, ("time zone %s: %s"):format(name, trouble) end
  local rules, why = parse_tzif(carried)
  if rules == nil then
    return nil, remember(("the binary's time zone %s: %s"):format(name, why))
  end
  rules.named = writable(name)
  local zone = make_zone(name, rules)
  zones[name] = zone
  return zone, ""
end

--- IANA's zone `name`, as "America/New_York" or "UTC", from the copy of
--- the tz database the binary carries. The host's zone files are never
--- read, so a name gives the same rules on every host, whatever tz
--- release it has or whether it has one at all. Nil and why when
--- `name` is no zone name (absolute, with a `..` part, or with a
--- character other than letters, digits and `_+-./`) or the binary
--- carries no such zone. An empty `name` raises. A zone is read once a
--- process and the same [`Zone`] answered from then on, and a name found
--- to be no zone is not looked for again.
function Time.zone(name: string): Time.Zone | nil, string
  if name == "" then error("time: the zone name is empty", 2) end
  local zone, why = zone_of(name)
  if zone == nil then return refuse(why) end
  return zone, ""
end

--- The zone TZif bytes (RFC 8536) describe, named `name`, or nil and
--- why they are no TZif file cosmic reads. `name` is written by
--- [`format_rfc3339`]'s `zone_name` when it is a zone name RFC 9557 can
--- write.
function Time.zone_from_tzif(data: string, name: string): Time.Zone | nil, string
  local rules, why = parse_tzif(data)
  if rules == nil then return refuse(why) end
  rules.named = writable(name)
  return make_zone(name, rules), ""
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

--- The zone name the link at `path` names, as /etc/localtime's does,
--- following links that name none -- as NixOS's goes through
--- /etc/zoneinfo -- a few deep.
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
--- line that is neither blank nor a `#` comment, less the space around
--- it and any byte order mark.
local function written_name(path: string): string
  local text, _ = Fs.read(path)
  if text == nil then return nil end
  text = text:gsub("^\239\187\191", "")
  for line in String.lines(text) do
    local name = String.trim(line)
    if name ~= "" and name:sub(1, 1) ~= "#" then
      if name_problem(name) ~= nil then return nil end
      return name
    end
  end
  return nil
end

--- The host's zone when `TZ` is unset: the carried zone the
--- /etc/localtime link names, else the one /etc/timezone names, else UTC.
--- TODO: say so when the host names a zone this binary does not carry
--- -- one IANA added since its database was built -- rather than taking
--- UTC in silence: [`local_zone`] answers no reason on this path today;
--- a warning, or a way to ask why, would carry `NEWER_ZONES`.
local function host_zone(localtime: string, timezone: string): Time.Zone
  local function carried(name: string): Time.Zone
    if name == nil then return nil end
    local zone, _ = zone_of(name)
    return zone
  end
  return carried(linked_name(localtime)) or carried(written_name(timezone)) or Time.UTC
end

--- The zone name a `TZ` of `:name` or `:/path` gives: a name as it is,
--- less a `posix/` or `right/` before it; a path by where it sits,
--- as [`zoneinfo_name`] reads it, else by where it links, as
--- `TZ=:/etc/localtime` does.
local function tz_name(rest: string): string
  if rest:sub(1, 1) ~= "/" then
    return (rest:gsub("^posix/", ""):gsub("^right/", ""))
  end
  return zoneinfo_name(rest) or linked_name(rest)
end

--- Every zone [`local_zone`] has answered with no options, by `TZ`, and
--- the one for `TZ` unset.
local locals: {string:Time.Zone} = {}
local unset_local: Time.Zone = nil

--- The host's own zone, as Java and ICU find it: the host names a zone
--- and the binary's tz database gives its rules, as `zone` does. The
--- host's zone files are never read.
---
--- With `TZ` unset, the zone is the one the /etc/localtime link names by
--- where it points (`.../zoneinfo/Europe/Berlin`), else the one the
--- first line of /etc/timezone names, else UTC. An /etc/localtime that is
--- a copy rather than a link, or is missing, gives UTC unless
--- /etc/timezone says otherwise, and never a failure.
---
--- With `TZ` set:
---
--- - Empty, or `:`, is UTC.
--- - `:Name` is `zone(Name)`, less a `posix/` or `right/` before it.
--- - `:/path` or `/path` is the zone its path names the same way the
---   link does, else the one it links to, as `TZ=:/etc/localtime` does.
--- - `Name` is `zone(Name)` when the binary carries it, else a POSIX TZ
---   string, as `EST5EDT,M3.2.0,M11.1.0` or `<+0330>-3:30`, which names
---   the zone it describes (its `name` is the string). Offsets are west
---   of UTC, as POSIX has them; a rule's time may be negative or past 24
---   hours, as RFC 8536's version 3 allows; and daylight saving time
---   named with no rules takes the United States', `M3.2.0,M11.1.0`, as
---   glibc does.
---
--- Nil and why only for a `TZ` it cannot use: a `:Name` or path naming no
--- zone the binary carries, or a bare `TZ` that is neither a carried zone
--- nor a POSIX TZ string.
---
--- `opts.tz` stands in for `TZ` (nil reads the environment's, unless
--- `opts.unset` reads as though it were unset), `opts.localtime` for
--- /etc/localtime and `opts.timezone` for /etc/timezone. With no options,
--- the answer is read once a process.
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
  elseif tz:sub(1, 1) == ":" or tz:sub(1, 1) == "/" then
    local name = tz_name((tz:gsub("^:", "")))
    if name == nil then
      return refuse(("TZ=%s: a path names a zone only by what follows its \"zoneinfo/\", " ..
        "or by where it links"):format(tz))
    end
    local why: string
    zone, why = zone_of(name)
    if zone == nil then return refuse(("TZ=%s: %s"):format(tz, why)) end
  else
    local name = tz_name(tz)
    local zone_name = name_problem(name) == nil
    if zone_name then
      local named, _ = zone_of(name)
      zone = named
    end
    if zone == nil then
      local p, why = parse_posix(tz)
      if p == nil then
        -- Written as a zone name, it may be one IANA added since.
        return refuse(("TZ=%s names no zone this binary carries, and is no POSIX TZ string: %s%s"):format(
          tz, why, zone_name and "; " .. NEWER_ZONES or ""))
      end
      zone = posix_zone(tz, p)
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

--- `how`, "reject" when nil; raises, blaming the caller of the
--- function that asks, for one that is none of [`Disambiguation`]'s.
local function disambiguation_of(how: Time.Disambiguation): Time.Disambiguation
  how = how or "reject"
  if not DISAMBIGUATIONS[how] then
    error("time: disambiguation is \"reject\", \"earlier\", \"later\" or \"compatible\", not " ..
        tostring(how), 3)
  end
  return how
end

--- The whole seconds since the epoch the local time of `c` names on the
--- calendar of `zone`, UTC's when nil, resolved as `how` says, or nil and
--- why: [`from_civil`] less its nanoseconds and their range.
local function resolve(c: Time.Civil, zone: Time.Zone, how: Time.Disambiguation): integer | nil, string
  if zone == nil then return seconds_of(c) end
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
      return nil, ("%s does not exist in %s: clocks moved from %s to %s"):format(
        civil_text(c, "minute"), rules.name, offset_text(before), offset_text(after))
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
          "\"earlier\" or \"later\" picks one"):format(civil_text(c, "minute"), rules.name,
            offset_text(before), offset_text(after))
      end
      chosen = how == "later" and found[#found] or found[1]
    end
  end
  return chosen, ""
end

--- The nanoseconds `c` names on the calendar of `zone`, UTC's by
--- default, or nil and which field is out of its range (month 13,
--- February 30, hour 24), or that the moment is outside what an integer
--- holds. A field that is no integer (a float such as 2026.0 included,
--- or one `c` lacks) raises. Nothing is normalized: day 32 is refused,
--- not carried into the next month. A local time a zone skipped or passed twice is resolved as
--- `opts.disambiguation` says, and refused by default, naming the
--- change; passed twice, the moment whose offset is `c.offset` is taken
--- whatever the disambiguation, so `from_civil(civil(ns, zone), zone)`
--- is always `ns`. Raises for a `disambiguation` that is none of
--- [`Disambiguation`]'s, or a `zone` no function here made.
function Time.from_civil(c: Time.Civil, zone?: Time.Zone, opts?: Time.AddOptions): integer | nil, string
  local how = disambiguation_of(opts ~= nil and opts.disambiguation or nil)
  integral("year", c.year)
  integral("month", c.month)
  integral("day", c.day)
  integral("hour", c.hour)
  integral("minute", c.minute)
  integral("second", c.second)
  integral("ns", c.ns)
  local s, why = resolve(c, zone, how)
  if s == nil then return refuse(why) end
  local ns, range_why = instant(s, c.ns)
  if ns == nil then return refuse(range_why) end
  return ns, ""
end

--- `ns` moved by the calendar part of `duration` on the calendar of
--- `zone`, UTC's by default: the years and months first, keeping the day
--- and the local time of day, then the days, and the local time reached
--- read back as [`from_civil`] reads it, with `opts.disambiguation`, so a
--- day across a change of offset is not 86400 seconds. Then its exact
--- part, `duration.ns`, is added as it is. A local time reached that the
--- zone passes twice is the moment with `ns`'s own offset when one of
--- the two has it, whatever the disambiguation. A missing field is zero.
--- Nil and why when the day the years and months reach is past its
--- month's end and `opts.overflow` is not "clamp", when the local time
--- reached is in a gap or a fold the disambiguation refuses, when a
--- field is past its bound (which only keeps the arithmetic from
--- wrapping), or when the result is outside the range. Raises for a
--- field that is no integer, an `overflow` or a `disambiguation` that is
--- none of its type's, or a `zone` no function here made.
function Time.add_calendar(ns: integer, duration: Time.Duration, zone?: Time.Zone,
                           opts?: Time.AddOptions): integer | nil, string
  local years, months, days = duration.years or 0, duration.months or 0, duration.days or 0
  local exact = duration.ns or 0
  integral("years", years)
  integral("months", months)
  integral("days", days)
  integral("ns", exact)
  local why = outside("years", years, -10000, 10000) or outside("months", months, -120000, 120000) or
    outside("days", days, -3650000, 3650000) or
    outside("ns", exact, math.mininteger, math.maxinteger)
  if why ~= nil then return refuse(why) end
  local overflow = opts ~= nil and opts.overflow or "reject"
  if overflow ~= "reject" and overflow ~= "clamp" then
    error("time: overflow is \"reject\" or \"clamp\", not " .. tostring(overflow), 2)
  end
  local how = disambiguation_of(opts ~= nil and opts.disambiguation or nil)
  local c = Time.civil(ns, zone)
  local index = c.year * 12 + (c.month - 1) + years * 12 + months
  c.year, c.month = index // 12, index % 12 + 1
  local last = month_days(c.year, c.month)
  if c.day > last then
    if overflow ~= "clamp" then
      return refuse(("%04d-%02d has no day %d; overflow \"clamp\" takes its last"):format(
        c.year, c.month, c.day))
    end
    c.day = last
  end
  local moved = civil_from_days(days_from_civil(c.year, c.month, c.day) + days)
  c.year, c.month, c.day = moved.year, moved.month, moved.day
  -- The offset of the moment moved from still chooses, when the local
  -- time reached is passed twice and one of the two has it -- cosmic's
  -- own choice: Temporal resolves a nonzero amount "compatible", taking
  -- the earlier -- so an amount of nothing moves nothing, even in a fold.
  local s, trouble = resolve(c, zone, how)
  if s == nil then return refuse(trouble) end
  -- The range is checked on the sum, so a local time just outside it that
  -- the exact part brings back is no refusal. One more than a year
  -- outside is, as [`from_civil`] holds every local time to.
  local n = c.ns + exact % NS
  s = s + exact // NS
  if n >= NS then s, n = s + 1, n - NS end
  local moved_ns, range_why = instant(s, n)
  if moved_ns == nil then return refuse(range_why) end
  return moved_ns, ""
end

--- The seconds of `ns` on the calendar of `zone`, UTC's when nil.
local function local_seconds(ns: integer, zone: Time.Zone): integer
  local s = ns // NS
  if zone == nil then return s end
  return s + kind_at(rules_for(zone), s).offset
end

--- Whole calendar months from `from` to `to`, negative when `to` is
--- earlier, as Java's `ChronoUnit.MONTHS.between` counts them on the
--- calendar of `zone`: `to`'s date steps a day toward `from`'s when its
--- local time of day has not reached `from`'s, then a month counts once
--- the day of the month does. January 31 to February 29 is 0; to March
--- 31, 2.
local function whole_months(from: integer, to: integer, zone: Time.Zone): integer
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

--- The whole years, months and days from `from` to `to` on the calendar
--- of `zone`, UTC's by default, and the rest as `ns`: a [`Duration`]
--- whose fields are all of one sign, negative when `to` is earlier, and
--- which [`add_calendar`] adds back to `to` exactly, as
--- `add_calendar(from, between(from, to, zone), zone, { overflow =
--- "clamp", disambiguation = "compatible" })`. The months are Java's
--- `ChronoUnit.MONTHS.between` (January 31 to February 29 is 0 months;
--- to March 31, 2), the years are their twelves, and the days are
--- counted from the date those months reach, where a month with no such
--- day gives its last. Where a gap, a fold or a day a zone skipped would
--- put that sum past `to`, the days and then the months are one fewer
--- until it is not, so the rest is never against the sign. The days are
--- the most that are not past `to`, so where one more would overshoot
--- into a fold or a day the zone skipped, `ns` can exceed a day (up to
--- about 47 hours in Apia).
function Time.between(from: integer, to: integer, zone?: Time.Zone): Time.Duration
  if from == to then return { years = 0, months = 0, days = 0, ns = 0 } end
  local dir = to > from and 1 or -1
  local options: Time.AddOptions = { overflow = "clamp", disambiguation = "compatible" }
  local months = whole_months(from, to, zone)
  if months * dir < 0 then months = 0 end
  while true do
    local anchor, _ = Time.add_calendar(from, { months = months }, zone, options)
    local first = 0
    if anchor ~= nil then
      first = local_seconds(to, zone) // DAY - local_seconds(anchor, zone) // DAY
      if first * dir < 0 then first = 0 end
    end
    for days = first, 0, -dir do
      local moved, _ = Time.add_calendar(from, { months = months, days = days }, zone, options)
      -- Out of the range is past `to`, or past `from`, for a step toward it.
      if moved ~= nil and (to - moved) * dir >= 0 then
        return {
          years = dir * (math.abs(months) // 12), months = dir * (math.abs(months) % 12),
          days = days, ns = to - moved,
        }
      end
    end
    -- With no months and no days the sum is `from`, which never is past `to`.
    if months == 0 then error("time: between found no span", 2) end
    months = months - dir
  end
end

--- `ns` as RFC 3339 text, `2026-09-25T04:09:21Z` in UTC, with a fraction
--- as `opts.digits` says (`2026-09-25T04:09:21.5Z` by default). With a
--- `zone`, its local time and its offset, `2026-09-25T00:09:21-04:00`,
--- and with `opts.zone_name` its IANA name after, as RFC 9557 has it:
--- `2026-09-25T00:09:21-04:00[America/New_York]`. An offset with seconds
--- (local mean time's, before a zone kept standard time) is rounded to
--- the minute, with the local time moved to match, so the text still
--- names `ns`. A cut in the range's first second names a moment before
--- it, which [`parse_rfc3339`] refuses. Raises when `digits` is not 0
--- through 9, when `zone_name` is set without a zone or for one with no
--- IANA name, or for a `zone` no function here made.
function Time.format_rfc3339(ns: integer, zone?: Time.Zone, opts?: Time.FormatOptions): string
  local digits = opts ~= nil and opts.digits or nil
  local bad = digits ~= nil and outside("digits", digits, 0, 9) or nil
  if bad ~= nil then error("time: " .. bad, 2) end
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
    error("time: zone_name writes the name of a zone, and there is none", 2)
  end
  local fraction = fraction_text(n, digits)
  return civil_text(civil_at(s + shift, n), "second") ..
    (fraction ~= "" and "." .. fraction or "") .. tail
end

--- `YYYY-MM-DD` at the cursor into `c`.
local function date_into(cur: Cursor, c: Time.Civil)
  c.year = read_digits(cur, 4, "year")
  expect(cur, "-", "after the year")
  c.month = read_digits(cur, 2, "month")
  expect(cur, "-", "after the month")
  c.day = read_digits(cur, 2, "day")
end

--- `hh:mm:ss` at the cursor into `c`.
local function clock_into(cur: Cursor, c: Time.Civil)
  c.hour = read_digits(cur, 2, "hour")
  expect(cur, ":", "after the hour")
  c.minute = read_digits(cur, 2, "minute")
  expect(cur, ":", "after the minute")
  c.second = read_digits(cur, 2, "second")
  if c.second == 60 then
    fail(cur, "second 60 is not 0 through 59: cosmic time has no leap seconds")
  end
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

--- The offset `+hh:mm` or `-hh:mm` at the cursor, in seconds east of
--- UTC: hours through 23, minutes through 59. `what` names it in a failure.
local function offset_at(cur: Cursor, what: string): integer
  local sign = cur.text:sub(cur.at, cur.at)
  if cur.why == nil and sign ~= "+" and sign ~= "-" then
    fail(cur, ("expected \"+\" or \"-\" to begin %s at byte %d"):format(what, cur.at))
  end
  cur.at = cur.at + 1
  local hours = read_digits(cur, 2, what .. "'s hour")
  expect(cur, ":", "in " .. what)
  local minutes = read_digits(cur, 2, what .. "'s minute")
  if cur.why ~= nil then return nil end
  local why = outside(what .. "'s hour", hours, 0, 23) or outside(what .. "'s minute", minutes, 0, 59)
  if why ~= nil then
    fail(cur, why)
    return nil
  end
  local offset = (hours * 60 + minutes) * 60
  return sign == "-" and -offset or offset
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

--- RFC 3339 text and its RFC 9557 suffix: [`parse_rfc3339`]'s and
--- [`parse_rfc3339_zoned`]'s work.
local function parse(text: string): Time.Zoned | nil, string
  local cur <close> = borrow(text)
  local c: Time.Civil = {}
  date_into(cur, c)
  expect(cur, "T", "between the date and the time")
  clock_into(cur, c)
  c.ns = accept(cur, ".") and read_fraction(cur) or 0
  if cur.why ~= nil then return nil, cur.why end
  local offset = 0
  -- `Z` and `-00:00` say the local offset is unknown (RFC 9557 2.2), so
  -- a zone after either is not held to the offset.
  local unknown = true
  local mark = text:sub(cur.at, cur.at)
  if mark == "+" or mark == "-" then
    offset = offset_at(cur, "the offset")
    if cur.why ~= nil then return nil, cur.why end
    unknown = mark == "-" and offset == 0
  elseif mark == "Z" or mark == "z" then
    cur.at = cur.at + 1
  else
    return nil, ("expected \"Z\" or an offset at byte %d"):format(cur.at)
  end
  local ns, range_why = moment(c, offset)
  if ns == nil then return nil, range_why end
  local zoned: Time.Zoned = { ns = ns }
  local first = true
  while text:sub(cur.at, cur.at) == "[" do
    local at = cur.at
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
      local inside = cursor(body)
      local annotated = offset_at(inside, "the suffix's offset")
      if inside.why ~= nil or #body ~= 6 then
        return nil, ("suffix at byte %d: %s"):format(at, inside.why or "expected an offset as +hh:mm")
      end
      if not unknown and annotated ~= offset then
        return nil, ("offset %s does not match the suffix's, %s"):format(offset_text(offset),
          offset_text(annotated))
      end
      zoned.zone = fixed_zone(annotated)
    else
      local problem = writable_problem(body)
      if problem ~= nil then return nil, ("suffix at byte %d: %s"):format(at, problem) end
      local zone, zone_why = zone_of(body)
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
    cur.at = close + 1
  end
  finish(cur)
  if cur.why ~= nil then return nil, cur.why end
  zoned.zone = zoned.zone or (unknown and Time.UTC or fixed_zone(offset))
  return zoned, ""
end

--- The nanoseconds an RFC 3339 timestamp names, as
--- `2026-09-25T04:09:21.5+05:30`: `T` or `t` between date and time, one
--- to nine digits of fraction, and `Z`, `z` or a numeric offset, where
--- `-00:00` is UTC too. An RFC 9557 suffix may follow: a zone,
--- `[America/New_York]` (or `[!America/New_York]`) or an offset,
--- `[+05:30]`, then any elective `[key=value]` tags, which are ignored.
--- The offset still names the moment, and must be the zone's then, to
--- the minute, unless it is `Z` or `-00:00`, which say the local offset
--- is unknown. Nil and why for anything else, a leap second, a moment
--- outside the range, a zone the binary does not carry, an offset the
--- zone does not have then, or a critical `[!key=value]` tag.
function Time.parse_rfc3339(text: string): integer | nil, string
  local zoned, why = parse(text)
  if zoned == nil then return refuse(why) end
  return zoned.ns, ""
end

--- [`parse_rfc3339`]'s moment, with the zone the text names: its RFC
--- 9557 suffix's -- for an offset, `[+05:30]`, a zone always that offset,
--- named "+05:30" -- else its offset's, a zone named for it the same way
--- (`+05:30`), or UTC for `Z` and `-00:00`.
function Time.parse_rfc3339_zoned(text: string): Time.Zoned | nil, string
  local zoned, why = parse(text)
  if zoned == nil then return refuse(why) end
  return zoned, ""
end

--- `ns`'s date on the calendar of `zone`, UTC's by default,
--- `2026-09-25`. Raises for a `zone` no function here made.
function Time.format_date(ns: integer, zone?: Time.Zone): string
  return civil_text(Time.civil(ns, zone), "date")
end

--- The first moment of the date `YYYY-MM-DD` names, as `2026-09-25`, on
--- the calendar of `zone`, UTC's by default, as Temporal's `startOfDay`
--- has it: its midnight -- the earlier, where midnight happens twice --
--- or, where the zone's clocks skipped midnight, the moment they
--- moved, which is the first the day has (Toronto's 1919-03-31 began at
--- 00:30-04:00). A day a zone skipped whole begins where the next one
--- does, so [`format_date`] of it can name the next day (Apia's
--- 2011-12-30 answers 2011-12-31's first moment). Nil and why for
--- anything else, a day its month does not have, or a date whose first
--- moment is outside the range, as the range's first, 1677-09-21, in
--- UTC. Raises for a `zone` no function here made.
function Time.parse_date(text: string, zone?: Time.Zone): integer | nil, string
  local c: Time.Civil = { hour = 0, minute = 0, second = 0, ns = 0 }
  local cur <close> = borrow(text)
  date_into(cur, c)
  finish(cur)
  if cur.why ~= nil then return refuse(cur.why) end
  if zone == nil then
    local ns, range_why = moment(c, 0)
    if ns == nil then return refuse(range_why) end
    return ns, ""
  end
  local rules = rules_for(zone)
  local midnight, midnight_why = seconds_of(c)
  if midnight == nil then return refuse(midnight_why) end
  local earliest, earliest_why = Time.from_civil(c, zone, { disambiguation = "earlier" })
  -- from_civil answers under the module's name already.
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
  local ns, range_why = instant(hi, 0)
  if ns == nil then return refuse(range_why) end
  return ns, ""
end

local SHORT_DAYS <const> = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local LONG_DAYS <const> = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  "Sunday" }
local MONTHS <const> = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
  "Nov", "Dec" }

--- `ns` as an HTTP date, RFC 9110's IMF-fixdate: `Fri, 25 Sep 2026
--- 05:22:21 GMT`, the fraction of a second cut toward the past. A cut
--- in the range's first second names a moment before it, which
--- [`parse_http`] refuses.
function Time.format_http(ns: integer): string
  local c = Time.civil(ns)
  return ("%s, %02d %s %04d %s GMT"):format(SHORT_DAYS[c.weekday], c.day, MONTHS[c.month],
    c.year, civil_text(c, "clock"))
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
  local c: Time.Civil = { ns = 0 }
  local cur <close> = borrow(text)
  local separator = text:sub(4, 4)
  if separator == "," then
    name_of(cur, SHORT_DAYS, "a day name")
    expect(cur, ", ", "after the day name")
    c.day = read_digits(cur, 2, "day")
    expect(cur, " ", "after the day")
    c.month = name_of(cur, MONTHS, "a month name")
    expect(cur, " ", "after the month")
    c.year = read_digits(cur, 4, "year")
    expect(cur, " ", "after the year")
    clock_into(cur, c)
    expect(cur, " GMT", "after the time")
  elseif separator == " " then
    name_of(cur, SHORT_DAYS, "a day name")
    expect(cur, " ", "after the day name")
    c.month = name_of(cur, MONTHS, "a month name")
    expect(cur, " ", "after the month")
    c.day = accept(cur, " ") and read_digits(cur, 1, "day") or read_digits(cur, 2, "day")
    expect(cur, " ", "after the day")
    clock_into(cur, c)
    expect(cur, " ", "after the time")
    c.year = read_digits(cur, 4, "year")
  else
    name_of(cur, LONG_DAYS, "a day name")
    expect(cur, ", ", "after the day name")
    c.day = read_digits(cur, 2, "day")
    expect(cur, "-", "after the day")
    c.month = name_of(cur, MONTHS, "a month name")
    expect(cur, "-", "after the month")
    local year = read_digits(cur, 2, "year")
    c.year = year ~= nil and year + (year >= 69 and 1900 or 2000) or nil
    expect(cur, " ", "after the year")
    clock_into(cur, c)
    expect(cur, " GMT", "after the time")
  end
  finish(cur)
  if cur.why ~= nil then return refuse(cur.why) end
  local ns, why = moment(c, 0)
  if ns == nil then return refuse(why) end
  return ns, ""
end

--- The most seconds a duration's exact part holds, so its nanoseconds
--- still fit an integer.
local MAX_SPAN_S <const> = math.maxinteger // NS

--- The duration `text` spells, or nil and why. It is an optional sign
--- and then each of `y`, `mo`, `d`, `h`, `m` and `s` at most once, in
--- that order, after a whole number (the seconds may have a fraction
--- of one to nine digits): `1y2mo3d4h5m6s`, `90m`, `-1d12h`, `+0.5s`.
--- The sign belongs to the whole duration. A number has at most nine
--- digits and the exact part is at most what nanoseconds hold, about
--- 292 years; a calendar part the range of [`add_calendar`] refuses is
--- refused there, not here.
function Time.parse_duration(text: string): Time.Duration | nil, string
  local at = 1
  local sign = 1
  local first = text:sub(1, 1)
  if first == "-" or first == "+" then
    sign = first == "-" and -1 or 1
    at = 2
  end
  if at > #text then return refuse("expected a duration such as 1y2mo3d4h5m6s, not nothing") end
  local units = { "y", "mo", "d", "h", "m", "s" }
  local seen = 0
  local values: {integer} = { 0, 0, 0, 0, 0, 0 }
  local fraction = 0
  while at <= #text do
    local digits = text:match("^%d+", at)
    if digits == nil then
      return refuse(("expected a number at byte %d of the duration"):format(at))
    end
    if #digits > 9 then
      return refuse(("the number at byte %d has %s: at most 9"):format(at,
        String.counted(#digits, "digit")))
    end
    local number = math.tointeger(tonumber(digits))
    at = at + #digits
    local unit = 0
    if text:sub(at, at + 1) == "mo" then
      unit = 2
    else
      for index, name in ipairs(units) do
        if text:sub(at, at) == name then unit = index end
      end
    end
    if text:sub(at, at) == "." then
      local frac = text:match("^%.(%d+)s", at)
      if frac == nil or #frac > 9 then
        return refuse(("expected 1 to 9 digits of fraction and then \"s\" at byte %d"):format(at))
      end
      fraction = fraction_ns(frac)
      at = at + 1 + #frac
      unit = 6
    end
    if unit == 0 then
      return refuse(("expected a unit y, mo, d, h, m or s at byte %d of the duration"):format(at))
    end
    if unit <= seen then
      return refuse(("unit %s at byte %d is repeated or out of order: y, mo, d, h, m, s"):format(
        units[unit], at))
    end
    seen = unit
    values[unit] = number
    at = at + #units[unit]
  end
  local seconds = values[4] * 3600 + values[5] * 60 + values[6]
  if seconds > MAX_SPAN_S or (seconds == MAX_SPAN_S and fraction > math.maxinteger % NS) then
    return refuse("the hours, minutes and seconds are more than 292 years")
  end
  return {
    years = sign * values[1], months = sign * values[2], days = sign * values[3],
    ns = sign * (seconds * NS + fraction),
  }, ""
end

--- `d` as [`parse_duration`] reads it, so the two round trip:
--- `1y2mo3d4h5m6.5s`, a `-` before a negative one, and `0s` for nothing.
--- Each calendar field is written as it is, `14mo` not `1y2mo`. Raises
--- for a duration whose fields are not all of one sign.
function Time.format_duration(d: Time.Duration): string
  local years, months, days, ns = d.years or 0, d.months or 0, d.days or 0, d.ns or 0
  local negative = years < 0 or months < 0 or days < 0 or ns < 0
  if negative and (years > 0 or months > 0 or days > 0 or ns > 0) then
    error("time: a duration's fields are all of one sign", 2)
  end
  local parts: {string} = {}
  local function put(n: integer, unit: string)
    if n ~= 0 then parts[#parts + 1] = ("%d%s"):format(math.abs(n), unit) end
  end
  put(years, "y")
  put(months, "mo")
  put(days, "d")
  local span = math.abs(ns)
  put(span // (3600 * NS), "h")
  put(span % (3600 * NS) // (60 * NS), "m")
  local seconds, nanos = span % (60 * NS) // NS, span % NS
  if seconds ~= 0 or nanos ~= 0 then
    local text = ("%d"):format(seconds)
    if nanos ~= 0 then text = text .. "." .. fraction_text(nanos) end
    parts[#parts + 1] = text .. "s"
  end
  if #parts == 0 then return "0s" end
  return (negative and "-" or "") .. table.concat(parts)
end

Time.now_ns = Clock.now_ns
Time.monotonic_ns = Clock.monotonic_ns
Time.sleep_ns = Clock.sleep_ns
Time.ms = Clock.ms
Time.seconds = Clock.seconds
Time.minutes = Clock.minutes
Time.hours = Clock.hours
Time.ceil = Clock.ceil

return Time
