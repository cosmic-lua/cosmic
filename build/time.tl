--- `cosmic time`: the clock and the calendar the same on every host, for
--- the ten-second question ("what is this timestamp in Tokyo?", "how many
--- days from then to now?") that GNU and BSD `date` answer in different
--- dialects. Zones come from the tz database the binary carries and the
--- arithmetic from `cosmic.time`, so a command means one thing on Linux,
--- macOS and Windows; only the default zone (the host's own, which
--- `TZ` and /etc/localtime name) is the host's.
---
--- Like `cosmic json` it ends in no verdict line: its standard output is
--- data for a pipe or a `$(...)`. Its exit status is the verdict: 0 done,
--- 1 an `add` whose answer does not exist (the day its month lacks, a
--- moment outside what the calendar holds, a result in a gap a zone
--- skipped, under `--disambiguate reject`), 2 a command line, a time, a
--- duration or a zone it cannot read. So a local time a zone skipped or
--- repeated that the user TYPED, read under `reject`, is bad input (2),
--- while one an `add` LANDS in is an answer that does not exist (1). Complaints go to standard error. build/dispatch.tl's
--- `bare` names it.
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
--- 1mo) is refused, `cosmic.time`'s rule; `--clamp` takes the month's last
--- day instead (February 28 or 29).

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Time = require("cosmic.time")
local verb_spec = require("build.verb_spec")

--- The `cosmic time` verb: `run` is what `build/dispatch.tl` calls.
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

local spec = Cli.options.time

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
    rfc3339 = Time.format_rfc3339(seen.ns, { zone = seen.zone }),
    zone = seen.zone.name == "Etc/UTC" and "UTC" or seen.zone.name,
    offset = c.offset,
    abbreviation = c.abbreviation,
    dst = c.dst,
    year = c.year, month = c.month, day = c.day,
    hour = c.hour, minute = c.minute, second = c.second, nanosecond = c.nanosecond,
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

--- `seen` in the format the command line named.
local function shown(seen: Seen, format: string, digits?: integer): string
  if format == "epoch" then return epoch_text(seen.ns) end
  if format == "date" then return Time.format_date(seen.ns, seen.zone) end
  if format == "http" then return Time.format_http(seen.ns) end
  return Time.format_rfc3339(seen.ns, { zone = seen.zone, digits = digits })
end

--- `cosmic time [subcommand] ...`: prints what it is asked and returns the
--- exit code: 0 done, 1 an `add` with no answer, 2 a command line or an input it
--- cannot read.
--- @param argv the command line, `time` at slot 1
--- @param io where the text is written and the clock read; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to: verb.Io = io or {
    out = function(text: string): boolean, string
      return Fs.put(Fs.stdout, text)
    end,
    err = function(line: string)
      local _, _ = Fs.put(Fs.stderr, line .. "\n")
    end,
    now = Time.now_ns,
    local_zone = function(): Time.Zone | nil, string
      return Time.local_zone()
    end,
  }
  local function complain(line: string)
    to.err("cosmic: time: " .. line)
  end
  local function refuse(line: string): integer
    complain(line .. "; " .. usage)
    return 2
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
    local ok, why = to.out(text)
    if ok then return 0 end
    complain("standard output: " .. why)
    return 2
  end
  local function print_seen(seen: Seen, digits?: integer): integer
    if as_json then
      local encoded, why = Json.encode(record_of(seen), { pretty = true })
      if encoded == nil then
        complain(why)
        return 2
      end
      return written(encoded .. "\n")
    end
    return written(shown(seen, format, digits) .. "\n")
  end
  --- What a time argument names: nil after a complaint.
  local function read_time(text: string, zone: Time.Zone): Time.Zoned | nil
    local zoned, why = Time.parse_input(text, zone, { disambiguation = disambiguation })
    if zoned == nil then
      complain(("%q: %s"):format(text, why))
      return nil
    end
    return zoned
  end

  if sub == "now" then
    local zone = zone_of("--zone")
    if zone == nil then return 2 end
    local now = to.now()
    return print_seen({ ns = now - now % NS, zone = zone }, 0)
  end

  if sub == "convert" then
    local from = zone_of("--from")
    if from == nil then return 2 end
    local zoned = read_time(parsed.words[2], from)
    if zoned == nil then return 2 end
    local target = zone_of("--to")
    if target == nil then return 2 end
    return print_seen({ ns = zoned.ns, zone = target })
  end

  -- The calendar the arithmetic runs on: --zone, else the first time's
  -- own zone, else the host's.
  local fallback = zone_of("--zone")
  if fallback == nil then return 2 end
  local first = read_time(parsed.words[2], fallback)
  if first == nil then return 2 end
  local calendar = parsed.values["--zone"] ~= nil and fallback or first.zone or fallback

  if sub == "add" then
    local duration, why = Time.parse_duration(parsed.words[3])
    if duration == nil then
      complain(("%q: %s"):format(parsed.words[3], why))
      return 2
    end
    local moved, moved_why = Time.add_calendar(first.ns,
      { years = duration.years, months = duration.months, days = duration.days }, {
        zone = calendar, overflow = parsed.set["--clamp"] and "clamp" or "reject",
        disambiguation = disambiguation,
      })
    if moved == nil then
      complain((moved_why:gsub('overflow "clamp" takes its last', "--clamp takes its last")))
      return 1
    end
    local exact = moved + duration.nanoseconds
    if (duration.nanoseconds > 0 and exact < moved) or (duration.nanoseconds < 0 and exact > moved) then
      complain("outside 1677-09-21T00:12:43.145224192Z through 2262-04-11T23:47:16.854775807Z, " ..
        "what an integer of nanoseconds holds")
      return 1
    end
    return print_seen({ ns = exact, zone = calendar })
  end

  local second = read_time(parsed.words[3], calendar)
  if second == nil then return 2 end
  local modes: {string} = {}
  for _, name in ipairs({ "--days", "--months", "--seconds" }) do
    if parsed.set[name] then modes[#modes + 1] = name end
  end
  if #modes > 1 then return refuse("name one of " .. table.concat(modes, " and ") .. ", not both") end
  local unit = #modes == 1 and modes[1]:sub(3) or "duration"
  local value: integer | string
  if unit == "days" then
    value = Time.days_between(first.ns, second.ns, calendar)
  elseif unit == "months" then
    value = Time.months_between(first.ns, second.ns, calendar)
  elseif unit == "seconds" then
    local whole = second.ns // NS - first.ns // NS
    local fraction = second.ns % NS - first.ns % NS
    if whole > 0 and fraction < 0 then whole = whole - 1 elseif whole < 0 and fraction > 0 then whole = whole + 1 end
    value = whole
  else
    local months = Time.months_between(first.ns, second.ns, calendar)
    local options: Time.AddOptions = { zone = calendar, overflow = "clamp", disambiguation = "compatible" }
    local anchor, why = Time.add_calendar(first.ns, { months = months }, options)
    if anchor == nil then
      complain(why)
      return 1
    end
    local days = Time.days_between(anchor, second.ns, calendar)
    local moved, days_why = Time.add_calendar(anchor, { days = days }, options)
    -- A whole day past the second is one too many.
    if moved ~= nil and ((days > 0 and moved > second.ns) or (days < 0 and moved < second.ns)) then
      days = days > 0 and days - 1 or days + 1
      moved, days_why = Time.add_calendar(anchor, { days = days }, options)
    end
    if moved == nil then
      complain(days_why)
      return 1
    end
    local sign = (months < 0 or days < 0 or second.ns < moved) and -1 or 1
    local years = sign * (math.abs(months) // 12)
    value = Time.format_duration({
      years = years, months = sign * (math.abs(months) % 12), days = days,
      nanoseconds = second.ns - moved,
    })
  end
  if as_json then
    local encoded, why = Json.encode({
      unit = unit, value = value,
      from = record_of({ ns = first.ns, zone = calendar }),
      to = record_of({ ns = second.ns, zone = calendar }),
    }, { pretty = true })
    if encoded == nil then
      complain(why)
      return 2
    end
    return written(encoded .. "\n")
  end
  return written(tostring(value) .. "\n")
end

--- The `time` verb as `build/verb_list.tl` lists it. Reads the clock and
--- the zones the binary carries, never the tree: never stale-checked.
verb.spec = {
  name = "time",
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  takes = "a subcommand and its times",
  exits = "`time` prints its answer and nothing after, exiting 1 when an `add` has none.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/time_test.tl)",
}

return verb
