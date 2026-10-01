--- `cosmic time`: the clock and the calendar the same on every host, for
--- the ten-second question ("what is this timestamp in Tokyo?", "how many
--- days from then to now?") that GNU and BSD `date` answer in different
--- dialects. Zones come from the tz database the binary carries and the
--- arithmetic from [`cosmic.time`], so a command means one thing on Linux,
--- macOS and Windows; only the default zone (the host's own, which
--- `TZ` and /etc/localtime name) is the host's.
---
--- Like `cosmic json` it ends in no verdict line: its standard output is
--- data for a pipe or a `$(...)`, and complaints go to standard error.
--- Its exit status is the verdict: 0 done, 1 an `add` whose answer does
--- not exist (the day its month lacks, a moment outside what the calendar
--- holds, a result in a gap a zone skipped, under `--disambiguate
--- reject`), 2 a command line, a time, a duration or a zone it cannot
--- read. So a local time a zone skipped or repeated that the user typed,
--- read under `reject`, is bad input (2), while one an `add` lands in is
--- an answer that does not exist (1). build/dispatch.tl's `bare` names
--- the verb.
---
--- Local times a zone skips or repeats: `YYYY-MM-DDTHH:MM[:SS]` read in a
--- zone that had no such time (a spring-forward gap) or two (a fall-back
--- overlap) is resolved by `--disambiguate`, "compatible" by default: a
--- time in a gap lands after the gap (02:30 in a gap from 02:00 to 03:00
--- is 03:30, the offset before the change applied), and a time in an
--- overlap is the earlier of its two moments. "earlier" and "later" take
--- the moment before or after in both cases; "reject" refuses it.
---
--- `--json` prints one object. `now`, `convert` and `add` print the moment:
--- `epoch` (whole seconds, floored), `rfc3339`, `zone` (the IANA name,
--- "UTC", or an offset like "+05:30"), `offset` (seconds east of UTC),
--- `abbreviation`, `dst`, and the civil fields `year`, `month`, `day`,
--- `hour`, `minute`, `second`, `nanosecond`, `weekday` (1 Monday) and
--- `yday`. `between` prints `unit` ("days", "months", "seconds" or
--- "duration"), `value` (a number, or the duration text) and the moments
--- `from` and `to` as above.
---
--- `between` counts calendar days and months on the calendar of `--zone`,
--- else of the first time's own zone (else the host's); `--seconds` is
--- elapsed time and ignores the calendar. Its default duration reads
--- months as `--clamp` does (a day the month lacks is its last), so
--- feeding it back to `add` may need `--clamp`.
---
--- `add` moves years and months first, keeping the day of the month and
--- the local time of day, then days along the calendar, then the exact
--- hours, minutes and seconds. A month with no such day (January 31 plus
--- 1mo) is refused, [`cosmic.time`]'s rule; `--clamp` takes the month's last
--- day instead (February 28 or 29).

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Json = require("cosmic.json")
local Time = require("cosmic.time")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")

--- The `cosmic time` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The wall clock, in nanoseconds since 1970.
    now: function(): integer
    --- The host's zone, or nil and why.
    local_zone: function(): Time.Zone | nil, string
  end
end

local NS <const> = 1000000000

local spec = Cli.verbs.time.spec

local usage = "cosmic time now [--zone Z] [--format F] [--json] | " ..
  "convert <time> [--from Z] [--to Z] [--format F] [--json] [--disambiguate H] | " ..
  "between <a> <b> [--zone Z] [--days|--months|--seconds] [--json] [--disambiguate H] | " ..
  "add <time> <duration> [--zone Z] [--format F] [--json] [--clamp] [--disambiguate H]; " ..
  "a negative duration follows its time, as `add 2026-01-31 -1d`"

--- The options each subcommand takes: any other is a usage error.
local takes: {string:{string}} = {
  now = { "--zone", "--format", "--json" },
  convert = { "--from", "--to", "--format", "--json", "--disambiguate" },
  between = { "--zone", "--days", "--months", "--seconds", "--json", "--disambiguate" },
  add = { "--zone", "--format", "--json", "--clamp", "--disambiguate" },
}

--- How many words each subcommand takes after its name.
local arity: {string:integer} = { now = 0, convert = 1, between = 2, add = 2 }

--- A negative duration or epoch begins with "-", which `Flags` reads as an
--- option; these forms are set aside under a name no option has and put
--- back.
local function protect(argv: {integer:string}): {integer:string}, {string:string}
  local out: {integer:string} = { [0] = argv[0] }
  local kept: {string:string} = {}
  local slot = 1
  local ended = false
  while argv[slot] ~= nil do
    local word = argv[slot]
    if word == "--" then ended = true end
    local before = slot > 1 and argv[slot - 1] or ""
    local option = spec[before]
    local is_value = false
    if option is Flags.Option then is_value = option.value ~= nil end
    if not ended and slot > 2 and not is_value and word:match("^%-%d") ~= nil then
      local name = "\1kept" .. slot
      kept[name] = word
      word = name
    end
    out[slot] = word
    slot = slot + 1
  end
  return out, kept
end

--- The words and options `argv` holds, or nil and why.
local function arguments(argv: {integer:string}): Flags.Parsed | nil, string
  local safe, kept = protect(argv)
  local parsed, trouble = Flags.parse(safe, 2, spec)
  if parsed == nil then return nil, trouble end
  for index, word in ipairs(parsed.words) do
    if kept[word] ~= nil then parsed.words[index] = kept[word] end
  end
  return parsed, ""
end

--- A moment in one zone, ready to print.
local record Seen
  ns: integer
  zone: Time.Zone
end

--- The record `--json` prints for a moment: its epoch, RFC 3339 text, zone,
--- offset and civil fields.
local function record_of(seen: Seen): {string:any}
  local c = Time.civil(seen.ns, seen.zone)
  return {
    epoch = seen.ns // NS,
    rfc3339 = Time.format_rfc3339(seen.ns, seen.zone),
    zone = seen.zone.name == "Etc/UTC" and "UTC" or seen.zone.name,
    offset = c.offset,
    abbreviation = c.abbreviation,
    dst = c.dst,
    year = c.year, month = c.month, day = c.day,
    hour = c.hour, minute = c.minute, second = c.second, nanosecond = c.ns,
    weekday = c.weekday, yday = c.yday,
  }
end

--- `ns` as seconds since 1970, with a fraction when it has one, signed as
--- `@` reads it back.
local function epoch_text(ns: integer): string
  local s, n = ns // NS, ns % NS
  local negative = ns < 0
  local whole, fraction = s, n
  if negative then
    if n > 0 then whole, fraction = -(s + 1), NS - n else whole = -s end
  end
  local text = ("%d"):format(whole)
  if fraction > 0 then
    local trimmed = ("%09d"):format(fraction):gsub("0+$", "")
    text = text .. "." .. trimmed
  end
  return (negative and "-" or "") .. text
end

-- TODO: [`fraction_ns`], the range bounds below and [`epoch_text`]'s
-- trimming copy cosmic.time's private [`fraction_ns`], `instant` and
-- `fraction_text`. Call them once cosmic.time exports a moment from whole
-- seconds and nanoseconds, and a fraction's digits both ways.

--- The first and last moments an integer of nanoseconds holds, as whole
--- seconds and the nanoseconds past them, and how `@` text refuses one
--- outside them.
local MIN_S <const> = math.mininteger // NS
local MIN_NS <const> = math.mininteger % NS
local MAX_S <const> = math.maxinteger // NS
local MAX_NS <const> = math.maxinteger % NS
local RANGE <const> = "outside 1677-09-21T00:12:43.145224192Z through " ..
  "2262-04-11T23:47:16.854775807Z, what an integer of nanoseconds holds"

--- The nanoseconds the digits of a fraction of a second spell, one to
--- nine of them: `5` is 500000000.
local function fraction_ns(digits: string): integer
  return math.tointeger(tonumber(digits .. ("0"):rep(9 - #digits)))
end

--- What the text [`verb.parse_input`] reads may spell.
local INPUT_FORMS <const> = "expected RFC 3339 (2026-09-25T04:09:21Z), a date (2026-09-25), " ..
  "a local time (2026-09-25T04:09[:21]) or @<epoch seconds>"

--- [`verb.parse_input`] less the forms' names in its failures.
local function read_input(text: string, zone: Time.Zone | nil,
    how: Time.Disambiguation): Time.Zoned | nil, string
  if text:sub(1, 1) == "@" then
    local sign, whole, dot, frac = text:match("^@([+-]?)(%d+)(%.?)(%d*)$")
    if whole == nil or #whole > 10 or #frac > 9 or (dot == "." and frac == "") then
      return nil, "@ and seconds since 1970, as @1700000000 or @-1.5, at most 10 digits " ..
        "(the calendar ends in 2262) and 9 of fraction"
    end
    local s = math.tointeger(tonumber(whole))
    local n = frac == "" and 0 or fraction_ns(frac)
    if sign == "-" then
      s = -s
      if n > 0 then s, n = s - 1, NS - n end
    end
    if s < MIN_S or (s == MIN_S and n < MIN_NS) or s > MAX_S or (s == MAX_S and n > MAX_NS) then
      return nil, RANGE
    end
    return { ns = s * NS + n }, ""
  end
  if text:match("^%d%d%d%d%-%d%d%-%d%d$") then
    local ns, why = Time.parse_date(text, zone)
    if ns == nil then return nil, why end
    return { ns = ns }, ""
  end
  local year, month, day, hour, minute, tail = text:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d)(.*)$")
  if tail ~= nil and (tail == "" or tail:match("^:%d%d$") or tail:match("^:%d%d%.%d+$")) then
    local c: Time.Civil = {
      year = math.tointeger(tonumber(year)), month = math.tointeger(tonumber(month)),
      day = math.tointeger(tonumber(day)), hour = math.tointeger(tonumber(hour)),
      minute = math.tointeger(tonumber(minute)), second = 0, ns = 0,
    }
    if tail ~= "" then
      c.second = math.tointeger(tonumber(tail:sub(2, 3)))
      if c.second == 60 then
        return nil, "second 60 is not 0 through 59: cosmic time has no leap seconds"
      end
      if #tail > 3 then
        local digits = #tail - 4
        if digits > 9 then
          return nil, ("fraction: expected 1 to 9 digits, not %d"):format(digits)
        end
        c.ns = fraction_ns(tail:sub(5))
      end
    end
    local ns, from_why = Time.from_civil(c, zone, { disambiguation = how })
    if ns == nil then return nil, from_why end
    return { ns = ns }, ""
  end
  -- Seconds are optional as in the local form: `T12:00Z` is `T12:00:00Z`.
  local zoned, why: Time.Zoned | nil, string
  local minutes, rest = text:match("^(%d%d%d%d%-%d%d%-%d%d[Tt]%d%d:%d%d)([Zz+%-].*)$")
  if minutes ~= nil then
    zoned, why = Time.parse_rfc3339_zoned(minutes .. ":00" .. rest)
    if zoned == nil then
      -- The text parsed had ":00" at bytes 17 to 19: a byte past them is 3 earlier in the user's.
      why = why:gsub("byte (%d+)", function(n: string): string
        local at = math.tointeger(n) or 0
        return "byte " .. (at >= 17 and at - 3 or at)
      end)
    end
  else
    zoned, why = Time.parse_rfc3339_zoned(text)
  end
  if zoned == nil then return nil, why end
  return zoned, ""
end

--- The moment a user's text names, in whichever form they wrote it, or
--- nil and why: RFC 3339 as [`Time.parse_rfc3339_zoned`] reads it, whose
--- zone is the suffix's, or else the text's own offset (`Z` is UTC); a
--- date `2026-09-25`, its first moment on the calendar of `zone` (UTC's
--- when nil), as [`Time.parse_date`] has it; a local time
--- `2026-09-25T04:09` or `2026-09-25T04:09:21.5`, without `Z` or an
--- offset, on the calendar of `zone`, resolved as `how` says
--- ("compatible" when absent, as a wall clock would: a time in a gap
--- lands after the gap, and a time passed twice is the earlier); and `@`
--- and seconds since 1970, an integer with an optional sign and
--- fraction, `@1700000000`, `@-1.5`. Seconds are optional in the clock
--- of RFC 3339 text as in local text (`2026-09-25T04:09Z`), and a failure
--- names the forms, then the fault. The zone returned is nil for the
--- last three, which name none. Any text answers a moment or a failure.
--- Raises for a `zone` no function of [`cosmic.time`] made.
function verb.parse_input(text: string, zone?: Time.Zone, how?: Time.Disambiguation): Time.Zoned | nil, string
  local zoned, why = read_input(text, zone, how or "compatible")
  if zoned == nil then return nil, INPUT_FORMS .. ": " .. why end
  return zoned, ""
end

--- The whole days from the epoch to the local date `ns` falls on in `zone`.
local function local_day(ns: integer, zone: Time.Zone): integer
  return (ns // NS + Time.civil(ns, zone).offset) // 86400
end

--- `seen` in the format the command line named.
local function shown(seen: Seen, format: string, digits?: integer): string
  if format == "epoch" then return epoch_text(seen.ns) end
  if format == "date" then return Time.format_date(seen.ns, seen.zone) end
  if format == "http" then return Time.format_http(seen.ns) end
  return Time.format_rfc3339(seen.ns, seen.zone, { digits = digits })
end

--- `cosmic time [subcommand] ...`: prints what it is asked and returns the
--- exit code: 0 done, 1 an `add` with no answer, 2 a command line or an input it
--- cannot read.
--- @param argv the command line, `time` at slot 1
--- @param io where the text is written and the clock read; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to: verb.Io = io or {
    out = bare.out,
    err = bare.err,
    now = Time.now_ns,
    local_zone = function(): Time.Zone | nil, string
      return Time.local_zone()
    end,
  }
  local complain = bare.complainer("time", to.err)
  local function refuse(line: string): integer
    complain(line .. "; " .. usage)
    return bare.refused
  end
  local got, trouble = arguments(argv)
  if got == nil then return refuse(trouble) end
  local parsed: Flags.Parsed = got
  local sub = parsed.words[1]
  if sub == nil then return refuse("name now, convert, between or add") end
  local allowed = takes[sub]
  if allowed == nil then return refuse("no subcommand " .. sub) end
  local is_allowed: {string:boolean} = {}
  for _, name in ipairs(allowed) do is_allowed[name] = true end
  for _, name in ipairs(parsed.given) do
    if not is_allowed[name] then return refuse(name .. " is not an option of " .. sub) end
  end
  if #parsed.words - 1 ~= arity[sub] then
    return refuse(("%s takes %d word%s, not %d"):format(sub, arity[sub],
      arity[sub] == 1 and "" or "s", #parsed.words - 1))
  end
  local as_json = parsed.set["--json"] or false
  local format = parsed.values["--format"] or "rfc3339"
  if format ~= "rfc3339" and format ~= "date" and format ~= "http" and format ~= "epoch" then
    return refuse("--format is rfc3339, date, http or epoch, not " .. format)
  end
  if as_json and parsed.values["--format"] ~= nil then
    return refuse("--json prints a record, which --format does not shape")
  end
  local how = parsed.values["--disambiguate"] or "compatible"
  local choices: {string:Time.Disambiguation} = {
    reject = "reject", earlier = "earlier", later = "later", compatible = "compatible",
  }
  local disambiguation = choices[how]
  if disambiguation == nil then
    return refuse("--disambiguate is reject, earlier, later or compatible, not " .. how)
  end

  local host: Time.Zone | nil
  local function local_zone(): Time.Zone | nil
    if host == nil then
      local zone, why = to.local_zone()
      if zone == nil then
        complain("the host's time zone: " .. why .. "; name one with --zone, --from or --to")
        return nil
      end
      host = zone
    end
    return host
  end
  --- The zone an option names, the host's when it is not given; nil after
  --- a complaint.
  local function zone_of(name: string): Time.Zone | nil
    local text = parsed.values[name]
    if text == nil then return local_zone() end
    local zone, why = Time.zone(text)
    if zone == nil then
      complain(name .. ": " .. why)
      return nil
    end
    return zone
  end
  local function written(text: string): integer
    return bare.written(complain, to.out(text))
  end
  local function print_seen(seen: Seen, digits?: integer): integer
    if as_json then
      local encoded, why = Json.encode(record_of(seen), { pretty = true })
      if encoded == nil then
        complain(why)
        return bare.refused
      end
      return written(encoded .. "\n")
    end
    return written(shown(seen, format, digits) .. "\n")
  end
  --- What a time argument names: nil after a complaint.
  local function read_time(text: string, zone: Time.Zone): Time.Zoned | nil
    local zoned, why = verb.parse_input(text, zone, disambiguation)
    if zoned == nil then
      complain(("%q: %s"):format(text, why))
      return nil
    end
    return zoned
  end

  if sub == "now" then
    local zone = zone_of("--zone")
    if zone == nil then return bare.refused end
    local now = to.now()
    return print_seen({ ns = now - now % NS, zone = zone }, 0)
  end

  if sub == "convert" then
    local from = zone_of("--from")
    if from == nil then return bare.refused end
    local zoned = read_time(parsed.words[2], from)
    if zoned == nil then return bare.refused end
    local target = zone_of("--to")
    if target == nil then return bare.refused end
    return print_seen({ ns = zoned.ns, zone = target })
  end

  -- The calendar the arithmetic runs on: --zone, else the first time's
  -- own zone, else the host's.
  local fallback = zone_of("--zone")
  if fallback == nil then return bare.refused end
  local first = read_time(parsed.words[2], fallback)
  if first == nil then return bare.refused end
  local calendar = parsed.values["--zone"] ~= nil and fallback or first.zone or fallback

  if sub == "add" then
    local duration, why = Time.parse_duration(parsed.words[3])
    if duration == nil then
      complain(("%q: %s"):format(parsed.words[3], why))
      return bare.refused
    end
    local moved, moved_why = Time.add_calendar(first.ns, duration, calendar, {
      overflow = parsed.set["--clamp"] and "clamp" or "reject", disambiguation = disambiguation,
    })
    if moved == nil then
      complain((moved_why:gsub('overflow "clamp" takes its last', "--clamp takes its last")))
      return bare.failed
    end
    return print_seen({ ns = moved, zone = calendar })
  end

  local second = read_time(parsed.words[3], calendar)
  if second == nil then return bare.refused end
  local modes: {string} = {}
  for _, name in ipairs({ "--days", "--months", "--seconds" }) do
    if parsed.set[name] then modes[#modes + 1] = name end
  end
  if #modes > 1 then return refuse("name one of " .. table.concat(modes, " and ") .. ", not both") end
  local unit = #modes == 1 and modes[1]:sub(3) or "duration"
  local value: integer | string
  if unit == "days" then
    value = local_day(second.ns, calendar) - local_day(first.ns, calendar)
  elseif unit == "seconds" then
    local whole = second.ns // NS - first.ns // NS
    local fraction = second.ns % NS - first.ns % NS
    if whole > 0 and fraction < 0 then whole = whole - 1 elseif whole < 0 and fraction > 0 then whole = whole + 1 end
    value = whole
  else
    local span = Time.between(first.ns, second.ns, calendar)
    value = unit == "months" and span.years * 12 + span.months or Time.format_duration(span)
  end
  if as_json then
    local encoded, why = Json.encode({
      unit = unit, value = value,
      from = record_of({ ns = first.ns, zone = calendar }),
      to = record_of({ ns = second.ns, zone = calendar }),
    }, { pretty = true })
    if encoded == nil then
      complain(why)
      return bare.refused
    end
    return written(encoded .. "\n")
  end
  return written(tostring(value) .. "\n")
end

--- The `time` verb as [`build/verb_list.tl`] lists it. Reads the clock and
--- the zones the binary carries, never the tree: never stale-checked.
verb.spec = {
  name = "time",
  guide = "a quick question about a time",
  tests = { "build.time_test", "build.time_tool_test" },
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  takes = "a subcommand and its times",
  exits = "`time` prints its answer and nothing after, exiting 1 when an `add` has none.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/time_test.tl)",
}

return verb
