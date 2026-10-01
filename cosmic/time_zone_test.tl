--- Time zones in [`cosmic.time`]: IANA's zones by name, from the copy the
--- binary carries and never the host's files; POSIX TZ strings; `TZ`,
--- /etc/localtime and /etc/timezone; and what a zone does to the
--- calendar, RFC 3339 text and local times its clocks skip or repeat.

local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local Test = require("cosmic.test")

--- A fat tzif file, America/New_York as tzdata 2025b's zic wrote it
--- with a full version 1 block (Ubuntu's, public domain), which the
--- binary's slim copy is not. No zone is read from the host's files: a
--- program reads only the zones it carries. The test that starts the
--- program, to see what its environment names, is
--- cosmic/time_zone_tool_test.tl's.
Test.needs{ reads = { "testdata/tzif/America-New_York.fat" } }

local NS <const> = 1000000000

local function zone(name: string): Time.Zone
  local z, why = Time.zone(name)
  assert(z ~= nil, why)
  return z
end

local function at(text: string): integer
  local ns, why = Time.parse_rfc3339(text)
  assert(ns ~= nil, why)
  return ns
end

local function civil(year: integer, month: integer, day: integer, hour?: integer, minute?: integer,
    second?: integer): Time.Civil
  return { year = year, month = month, day = day, hour = hour or 0, minute = minute or 0,
    second = second or 0, ns = 0 }
end

--- `text` read on `z`'s calendar: its local time, offset, abbreviation
--- and daylight saving time.
local function says(z: Time.Zone, text: string, want: string, offset: integer, abbreviation: string,
    dst: boolean)
  local ns = at(text)
  local got = Time.format_rfc3339(ns, z)
  assert(got == want, ("%s in %s: got %s, want %s"):format(text, z.name, got, want))
  local c = Time.civil(ns, z)
  assert(c.offset == offset and c.abbreviation == abbreviation and c.dst == dst,
    ("%s in %s: %d %s %s"):format(text, z.name, c.offset, c.abbreviation, tostring(c.dst)))
end

local function test_new_york_springs_forward_and_falls_back()
  local ny = zone("America/New_York")
  says(ny, "2026-03-08T06:59:59Z", "2026-03-08T01:59:59-05:00", -18000, "EST", false)
  says(ny, "2026-03-08T07:00:00Z", "2026-03-08T03:00:00-04:00", -14400, "EDT", true)
  says(ny, "2026-11-01T05:59:59Z", "2026-11-01T01:59:59-04:00", -14400, "EDT", true)
  says(ny, "2026-11-01T06:00:00Z", "2026-11-01T01:00:00-05:00", -18000, "EST", false)
  -- Past the file's last transition, its footer's rules carry it on.
  says(ny, "2200-07-01T00:00:00Z", "2200-06-30T20:00:00-04:00", -14400, "EDT", true)
end

local function test_london_keeps_summer_time()
  local london = zone("Europe/London")
  says(london, "2026-03-29T00:59:59Z", "2026-03-29T00:59:59+00:00", 0, "GMT", false)
  says(london, "2026-03-29T01:00:00Z", "2026-03-29T02:00:00+01:00", 3600, "BST", true)
  says(london, "2026-10-25T00:59:59Z", "2026-10-25T01:59:59+01:00", 3600, "BST", true)
  says(london, "2026-10-25T01:00:00Z", "2026-10-25T01:00:00+00:00", 0, "GMT", false)
end

--- Lord Howe Island moves its clocks half an hour.
local function test_lord_howe_moves_half_an_hour()
  local howe = zone("Australia/Lord_Howe")
  says(howe, "2026-04-04T14:59:59Z", "2026-04-05T01:59:59+11:00", 39600, "+11", true)
  says(howe, "2026-04-04T15:00:00Z", "2026-04-05T01:30:00+10:30", 37800, "+1030", false)
  says(howe, "2026-10-03T15:29:59Z", "2026-10-04T01:59:59+10:30", 37800, "+1030", false)
  says(howe, "2026-10-03T15:30:00Z", "2026-10-04T02:30:00+11:00", 39600, "+11", true)
  local skipped, why = Time.from_civil(civil(2026, 10, 4, 2, 15), howe)
  assert(skipped == nil and why ==
    "2026-10-04T02:15 does not exist in Australia/Lord_Howe: clocks moved from +10:30 to +11:00", why)
end

local function test_kolkata_is_half_past_with_no_changes()
  local kolkata = zone("Asia/Kolkata")
  says(kolkata, "2026-01-15T12:00:00Z", "2026-01-15T17:30:00+05:30", 19800, "IST", false)
  says(kolkata, "2026-07-15T12:00:00Z", "2026-07-15T17:30:00+05:30", 19800, "IST", false)
end

--- Samoa crossed the date line: 2011-12-30 never happened in Apia.
local function test_apia_skipped_a_whole_day()
  local apia = zone("Pacific/Apia")
  says(apia, "2011-12-30T09:59:59Z", "2011-12-29T23:59:59-10:00", -36000, "-10", true)
  says(apia, "2011-12-30T10:00:00Z", "2011-12-31T00:00:00+14:00", 50400, "+14", true)
  local v, why = Time.from_civil(civil(2011, 12, 30, 12), apia)
  assert(v == nil and why ==
    "2011-12-30T12:00 does not exist in Pacific/Apia: clocks moved from -10:00 to +14:00", why)
  assert(Time.from_civil(civil(2011, 12, 30, 12), apia, { disambiguation = "later" }) ==
    at("2011-12-30T22:00:00Z"))
  assert(Time.from_civil(civil(2011, 12, 30, 12), apia, { disambiguation = "earlier" }) ==
    at("2011-12-29T22:00:00Z"))
  -- Two hours, though the date went from the 29th to the 31st: the day
  -- between was skipped, and so is no day of the span.
  local span = assert(Time.between(at("2011-12-30T09:00:00Z"), at("2011-12-30T11:00:00Z"), apia))
  assert(span.days == 0 and span.ns == 2 * 3600 * NS, Time.format_duration(span))
end

--- Ireland's standard time is summer's; winter is its daylight saving
--- time, an hour back.
local function test_dublin_saves_daylight_backwards()
  local dublin = zone("Europe/Dublin")
  says(dublin, "2026-01-15T12:00:00Z", "2026-01-15T12:00:00+00:00", 0, "GMT", true)
  says(dublin, "2026-07-15T12:00:00Z", "2026-07-15T13:00:00+01:00", 3600, "IST", false)
end

local function test_utc_is_the_calendar_without_a_zone()
  local ns = at("2026-09-25T04:09:21Z")
  for _, z in ipairs({ Time.UTC, zone("UTC"), zone("Etc/UTC") }) do
    local c = Time.civil(ns, z)
    assert(c.offset == 0 and c.abbreviation == "UTC" and c.dst == false and c.hour == 4, z.name)
    assert(Time.from_civil(c, z) == ns)
  end
  local c = Time.civil(ns)
  assert(c.offset == 0 and c.abbreviation == "UTC" and c.dst == false)
  assert(Time.format_rfc3339(ns, Time.UTC, { zone_name = true }) == "2026-09-25T04:09:21+00:00[UTC]")
end

--- Every disambiguation, in New York's gap and in its fold.
local function test_disambiguation_resolves_gaps_and_folds()
  local ny = zone("America/New_York")
  local gap, fold = civil(2026, 3, 8, 2, 30), civil(2026, 11, 1, 1, 30)
  local v, why = Time.from_civil(gap, ny)
  assert(v == nil and why ==
    "2026-03-08T02:30 does not exist in America/New_York: clocks moved from -05:00 to -04:00", why)
  v, why = Time.from_civil(fold, ny, { disambiguation = "reject" })
  assert(v == nil and why == "2026-11-01T01:30 happens twice in America/New_York: clocks moved " ..
    "from -04:00 to -05:00; disambiguation \"earlier\" or \"later\" picks one", why)
  local want: {Time.Disambiguation:{string}} = {
    earlier = { "2026-03-08T06:30:00Z", "2026-11-01T05:30:00Z" },
    later = { "2026-03-08T07:30:00Z", "2026-11-01T06:30:00Z" },
    compatible = { "2026-03-08T07:30:00Z", "2026-11-01T05:30:00Z" },
  }
  for how, pair in pairs(want) do
    local opts: Time.AddOptions = { disambiguation = how }
    assert(Time.from_civil(gap, ny, opts) == at(pair[1]), how)
    assert(Time.from_civil(fold, ny, opts) == at(pair[2]), how)
  end
  -- An unambiguous local time is the same moment whatever is asked.
  local every: {Time.Disambiguation} = { "reject", "earlier", "later", "compatible" }
  for _, how in ipairs(every) do
    assert(Time.from_civil(civil(2026, 7, 1, 12), ny, { disambiguation = how })
      == at("2026-07-01T16:00:00Z"))
  end
  local ok, err = pcall(Time.from_civil, gap, ny, { disambiguation = "nearest" as Time.Disambiguation })
  assert(not ok and tostring(err):find("disambiguation", 1, true), tostring(err))
  ok, err = pcall(Time.from_civil, gap, nil, { disambiguation = "nearest" as Time.Disambiguation })
  assert(not ok, "an unknown disambiguation raises without a zone too")
end

--- A local time a zone passes twice is read back as the moment it came
--- from: its offset chooses.
local function test_civil_then_from_civil_is_the_same_moment_in_a_fold()
  local ny = zone("America/New_York")
  for _, text in ipairs({ "2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-03-08T07:00:00Z",
      "1883-11-18T17:00:00Z", "1800-01-01T00:00:00Z" }) do
    local ns = at(text)
    assert(Time.from_civil(Time.civil(ns, ny), ny) == ns, text)
  end
end

--- Zones are shared across the process, so none can be renamed: a
--- write raises, and what every message and suffix writes is the name
--- it was made with.
local function test_a_zone_is_read_only()
  local ny = assert(Time.zone("America/New_York"))
  local ok, err = pcall(function(): string
    ny.name = "X][!evil=1"
    return ""
  end)
  assert(not ok and tostring(err):find("read-only", 1, true), tostring(err))
  assert(ny.name == "America/New_York")
  assert(Time.format_rfc3339(0, ny, { zone_name = true }) ==
    "1969-12-31T19:00:00-05:00[America/New_York]")
  local utc_ok = pcall(function() Time.UTC.name = "x" end)
  assert(not utc_ok and Time.UTC.name == "UTC")
  assert(not getmetatable(ny), "the metatable is hidden")
  -- rawset can shadow the field, but what is written is the zone's own.
  rawset(ny as {string:string}, "name", "X][!evil=1")
  assert(Time.format_rfc3339(0, ny, { zone_name = true }) ==
    "1969-12-31T19:00:00-05:00[America/New_York]")
  rawset(ny as {string:string}, "name", nil)
  assert(ny.name == "America/New_York")
end

local function test_a_zone_made_by_hand_is_refused()
  local fake: Time.Zone = { name = "America/New_York" }
  local ok, err = pcall(Time.civil, 0, fake)
  assert(not ok and tostring(err):find("not a zone", 1, true), tostring(err))
  local formatted, format_err = pcall(Time.format_rfc3339, 0, fake)
  assert(not formatted and tostring(format_err):find("not a zone", 1, true), tostring(format_err))
end

local function test_zone_names_are_checked_before_any_file_is_read()
  for _, name in ipairs({ "", "/etc/passwd", "../etc/passwd", "America/../../etc/passwd", "a//b",
      "America/", ".", "./UTC", "a b", "a\0b", "America/New_York\n", "Zone;rm", ("a"):rep(256),
      "localtime", "posixrules", "posix/Europe/Berlin", "right/UTC" }) do
    local z, why = Time.zone(name)
    assert(z == nil and why ~= "", name)
  end
  local z, why = Time.zone("Nowhere/Nothing")
  assert(z == nil and why:find("Nowhere/Nothing", 1, true), why)
  local names = assert(Store.zone_names())
  assert(names["America/New_York"] and not names["Nowhere/Nothing"])
  assert(not why:find("zoneinfo", 1, true), "the reason names no host path: " .. why)
  -- Asked again, the answer is remembered rather than looked for.
  local again, again_why = Time.zone("Nowhere/Nothing")
  assert(again == nil and again_why == why)
end

local function test_a_zone_is_read_once()
  local a, b = assert(Time.zone("Europe/Paris")), assert(Time.zone("Europe/Paris"))
  assert(rawequal(a, b), "the second lookup answers the first zone")
end

--- A tzif file, as `zic` writes one: a version 1 block, and for later
--- versions a 64-bit block and the footer after it.
local function tzif(version: string, times: {integer}, indices: {integer}, types: {{integer}},
    chars: string, footer: string): string
  local function block(wide: boolean): string
    local parts = { "TZif", version, ("\0"):rep(15),
      string.pack(">I4I4I4I4I4I4", 0, 0, 0, #times, #types, #chars) }
    for _, t in ipairs(times) do parts[#parts + 1] = string.pack(wide and ">i8" or ">i4", t) end
    for _, i in ipairs(indices) do parts[#parts + 1] = string.char(i) end
    for _, t in ipairs(types) do parts[#parts + 1] = string.pack(">i4BB", t[1], t[2], t[3]) end
    parts[#parts + 1] = chars
    return table.concat(parts)
  end
  if version == "\0" then return block(false) end
  return block(false) .. block(true) .. "\n" .. footer .. "\n"
end

local function test_tzif_reads_every_version()
  local types = { { 3600, 0, 0 }, { 7200, 1, 4 } }
  local times, indices = { 0, 1000 }, { 1, 0 }
  for _, version in ipairs({ "\0", "2", "3", "4" }) do
    local z, why = Time.zone_from_tzif(tzif(version, times, indices, types, "ONE\0TWO\0", ""), "Test/Zone")
    assert(z ~= nil, why)
    assert(Time.civil(-1, z).abbreviation == "ONE", "type 0 before the first transition")
    assert(Time.civil(0, z).offset == 7200 and Time.civil(0, z).dst)
    assert(Time.civil(999 * NS, z).abbreviation == "TWO")
    assert(Time.civil(1000 * NS, z).abbreviation == "ONE")
    assert(Time.format_rfc3339(0, z, { zone_name = true }) == "1970-01-01T02:00:00+02:00[Test/Zone]")
  end
  -- A footer carries it on past the last transition; with none, the
  -- footer holds for every moment.
  local z = assert(Time.zone_from_tzif(tzif("2", times, indices, types, "ONE\0TWO\0", "XYZ-5"), "x"))
  assert(Time.civil(1001 * NS, z).offset == 18000)
  assert(Time.civil(1000 * NS, z).offset == 3600, "the last transition's own type at it")
  z = assert(Time.zone_from_tzif(tzif("2", {}, {}, { { 0, 0, 0 } }, "UTC\0", "EST5EDT"), "x"))
  assert(Time.civil(at("2026-07-01T00:00:00Z"), z).abbreviation == "EDT")
end

--- A real zone's file, whose structure is zic's own, read slim -- the
--- binary's copy -- or fat, with a version 1 block of every transition
--- before the 64-bit one; the two agree on the settled past, monthly
--- from 1970 through 2019.
local function test_tzif_reads_a_real_fat_or_slim_file()
  local slim = assert(Store.zoneinfo("America/New_York"))
  local fat = assert(Fs.read("testdata/tzif/America-New_York.fat"))
  for label, data in pairs({ slim = slim, fat = fat }) do
    -- The version 1 block's transition count: none in a slim file.
    local transitions = string.unpack(">I4", data, 33)
    assert((transitions > 0) == (label == "fat"), label .. ": " .. transitions .. " transitions")
  end
  local carried = assert(Time.zone_from_tzif(slim, "America/New_York"))
  local read = assert(Time.zone_from_tzif(fat, "America/New_York"))
  for ns = 0, at("2020-01-01T00:00:00Z"), 30 * 86400 * NS + 7 * 3600 * NS do
    local a, b = Time.civil(ns, read), Time.civil(ns, carried)
    assert(a.offset == b.offset and a.abbreviation == b.abbreviation,
      ("%s: fat %d %s, slim %d %s"):format(Time.format_rfc3339(ns), a.offset, a.abbreviation,
      b.offset, b.abbreviation))
  end
end

local function test_tzif_refuses_malformed_files()
  local good = tzif("2", { 0 }, { 0 }, { { 0, 0, 0 } }, "UTC\0", "UTC0")
  assert(Time.zone_from_tzif(good, "x"))
  local cases: {string:string} = {
    ["empty"] = "",
    ["not tzif"] = "TZxf" .. good:sub(5),
    ["version"] = good:sub(1, 4) .. "5" .. good:sub(6),
    ["truncated header"] = good:sub(1, 30),
    ["truncated block"] = good:sub(1, #good - 12),
    ["trailing"] = good .. "x",
    ["no footer newline"] = good:sub(1, -2),
    ["no types"] = tzif("2", {}, {}, {}, "UTC\0", ""),
    ["no chars"] = tzif("2", {}, {}, { { 0, 0, 0 } }, "", ""),
    ["unsorted"] = tzif("2", { 5, 5 }, { 0, 0 }, { { 0, 0, 0 } }, "UTC\0", ""),
    ["type index"] = tzif("2", { 5 }, { 1 }, { { 0, 0, 0 } }, "UTC\0", ""),
    ["isdst"] = tzif("2", {}, {}, { { 0, 2, 0 } }, "UTC\0", ""),
    ["offset"] = tzif("2", {}, {}, { { 100000, 0, 0 } }, "UTC\0", ""),
    ["abbreviation index"] = tzif("2", {}, {}, { { 0, 0, 4 } }, "UTC\0", ""),
    ["abbreviation nul"] = tzif("2", {}, {}, { { 0, 0, 0 } }, "UTCX", ""),
    ["footer"] = tzif("2", {}, {}, { { 0, 0, 0 } }, "UTC\0", "not a tz"),
  }
  for what, data in pairs(cases) do
    local z, why = Time.zone_from_tzif(data, "x")
    assert(z == nil and why ~= "", what)
  end
  -- Leap second records: a right/ zone.
  local head = "TZif2" .. ("\0"):rep(15) .. string.pack(">I4I4I4I4I4I4", 0, 0, 1, 0, 1, 4) ..
    string.pack(">i4BB", 0, 0, 0) .. "UTC\0"
  local leap = head .. string.pack(">i4i4", 78796800, 1) .. head .. string.pack(">i8i4", 78796800, 1) ..
    "\n\n"
  local z, why = Time.zone_from_tzif(leap, "right/UTC")
  assert(z == nil and why:find("leap second", 1, true), why)
end

--- A file of many local time types whose abbreviations run to one NUL
--- at the end of many bytes is refused in time linear in its length,
--- not searched from every type to the end.
local function test_tzif_with_long_abbreviations_is_read_in_linear_time()
  local count = 80000
  local data = table.concat({ "TZif", "\0", ("\0"):rep(15),
    string.pack(">I4I4I4I4I4I4", 0, 0, 0, 0, count, count * 6),
    string.pack(">i4BB", 0, 0, 0):rep(count), ("A"):rep(count * 6 - 1), "\0" })
  local started = Time.monotonic_ns()
  local z, why = Time.zone_from_tzif(data, "x")
  local elapsed = Time.monotonic_ns() - started
  assert(z == nil and why:find("NUL", 1, true), why)
  assert(elapsed < 2 * NS, ("%d types took %d ms"):format(count, elapsed // 1000000))
  -- With a NUL near, every type reads its abbreviation, found once.
  data = table.concat({ "TZif", "\0", ("\0"):rep(15),
    string.pack(">I4I4I4I4I4I4", 0, 0, 0, 0, count, count * 6),
    string.pack(">i4BB", 3600, 0, 4):rep(count), "UTC\0CET\0", ("A"):rep(count * 6 - 9), "\0" })
  started = Time.monotonic_ns()
  z, why = Time.zone_from_tzif(data, "x")
  elapsed = Time.monotonic_ns() - started
  assert(z ~= nil, why)
  assert(Time.civil(0, z).abbreviation == "CET")
  assert(elapsed < 2 * NS, ("%d types took %d ms"):format(count, elapsed // 1000000))
end

--- The zone `tz` names as a POSIX TZ string, which `local_zone` reads
--- when the binary carries no zone of that name.
local function posix(tz: string): Time.Zone
  local z, why = Time.local_zone({ tz = tz })
  assert(z ~= nil, tz .. ": " .. why)
  return z
end

local function test_posix_strings_name_offsets_and_rules()
  local us = posix("EST5EDT,M3.2.0,M11.1.0")
  says(us, "2026-03-08T06:59:59Z", "2026-03-08T01:59:59-05:00", -18000, "EST", false)
  says(us, "2026-03-08T07:00:00Z", "2026-03-08T03:00:00-04:00", -14400, "EDT", true)
  says(us, "2026-11-01T05:59:59Z", "2026-11-01T01:59:59-04:00", -14400, "EDT", true)
  says(us, "2026-11-01T06:00:00Z", "2026-11-01T01:00:00-05:00", -18000, "EST", false)
  -- Daylight saving time with no rules takes the United States'.
  local bare = posix("AAA5BBB")
  for _, text in ipairs({ "2026-03-08T07:00:00Z", "2026-11-01T05:59:59Z", "2026-11-01T06:00:00Z" }) do
    assert(Time.civil(at(text), bare).offset == Time.civil(at(text), us).offset, text)
  end
  says(posix("<+0330>-3:30"), "2026-01-01T00:00:00Z", "2026-01-01T03:30:00+03:30", 12600, "+0330", false)
  says(posix("UTC0"), "2026-01-01T00:00:00Z", "2026-01-01T00:00:00+00:00", 0, "UTC", false)
  says(posix("<-03>3"), "2026-01-01T00:00:00Z", "2025-12-31T21:00:00-03:00", -10800, "-03", false)
  local named = posix("EST5EDT,M3.2.0,M11.1.0")
  assert(named.name == "EST5EDT,M3.2.0,M11.1.0")
  local ok, err = pcall(Time.format_rfc3339, 0, named, { zone_name = true })
  assert(not ok and tostring(err):find("IANA", 1, true), tostring(err))
end

--- The southern hemisphere saves daylight across the new year.
local function test_posix_rules_wrap_the_year_end()
  local sydney = posix("AEST-10AEDT,M10.1.0,M4.1.0/3")
  says(sydney, "2026-01-15T00:00:00Z", "2026-01-15T11:00:00+11:00", 39600, "AEDT", true)
  says(sydney, "2026-07-15T00:00:00Z", "2026-07-15T10:00:00+10:00", 36000, "AEST", false)
  says(sydney, "2026-04-04T15:59:59Z", "2026-04-05T02:59:59+11:00", 39600, "AEDT", true)
  says(sydney, "2026-04-04T16:00:00Z", "2026-04-05T02:00:00+10:00", 36000, "AEST", false)
  says(sydney, "2026-10-03T15:59:59Z", "2026-10-04T01:59:59+10:00", 36000, "AEST", false)
  says(sydney, "2026-10-03T16:00:00Z", "2026-10-04T03:00:00+11:00", 39600, "AEDT", true)
  says(sydney, "2026-12-31T13:00:00Z", "2027-01-01T00:00:00+11:00", 39600, "AEDT", true)
  local carried = zone("Australia/Sydney")
  for ns = at("2024-01-01T00:00:00Z"), at("2028-01-01T00:00:00Z"), 86400 * NS + 3 * 3600 * NS do
    assert(Time.civil(ns, sydney).offset == Time.civil(ns, carried).offset, Time.format_rfc3339(ns))
  end
end

local function test_posix_day_forms_and_extended_times()
  -- Jn never counts February 29; n does.
  local julian = posix("AAA0BBB,J60/0,J300/0")
  assert(Time.civil(at("2024-03-01T00:00:00Z"), julian).dst)
  assert(not Time.civil(at("2024-02-29T23:59:59Z"), julian).dst)
  local zero = posix("AAA0BBB,59/0,300/0")
  assert(Time.civil(at("2024-02-29T00:00:00Z"), zero).dst, "day 59 is February 29 in a leap year")
  assert(not Time.civil(at("2023-02-28T23:59:59Z"), zero).dst)
  assert(Time.civil(at("2023-03-01T00:00:00Z"), zero).dst, "and March 1 otherwise")
  -- Version 3: a negative time, and one past a day.
  local negative = posix("AAA0BBB,M3.2.0/-1,M11.1.0/26")
  assert(not Time.civil(at("2026-03-07T22:59:59Z"), negative).dst)
  assert(Time.civil(at("2026-03-07T23:00:00Z"), negative).dst)
  assert(Time.civil(at("2026-11-02T00:59:59Z"), negative).dst)
  assert(not Time.civil(at("2026-11-02T01:00:00Z"), negative).dst)
  -- Daylight saving time all year, ending as it starts again.
  local always = posix("EST5EDT4,0/0,J365/25")
  for _, text in ipairs({ "2026-01-01T00:00:00Z", "2026-01-01T05:00:00Z", "2026-07-01T00:00:00Z",
      "2026-12-31T23:59:59Z", "2028-12-31T12:00:00Z" }) do
    assert(Time.civil(at(text), always).abbreviation == "EDT", text)
  end
  local hours = posix("AAA0BBB,M3.2.0/167,M11.1.0/-167")
  assert(Time.civil(at("2026-07-01T00:00:00Z"), hours).dst)
end

local function test_posix_refuses_what_is_not_a_tz_string()
  for _, tz in ipairs({ "E5", "AAA", "EST+", "EST5ED", "EST25", "EST5EDT,M13.1.0,M11.1.0",
      "EST5EDT,M3.6.0,M11.1.0", "EST5EDT,M3.2.7,M11.1.0", "EST5EDT,M3.2.0", "EST5EDT,J0,J1",
      "EST5EDT,366,1", "EST5EDT,M3.2.0/168,M11.1.0", "EST5EDT,M3.2.0,M11.1.0x", "<AB>5",
      "<ABC5", "EST5:60", "EST5EDT;M3.2.0,M11.1.0", ("A"):rep(300) .. "5" }) do
    local z, why = Time.local_zone({ tz = tz })
    assert(z == nil and why ~= "", tz)
  end
end

--- Where a TZ string stops being one, and what it wanted there.
local function test_a_bad_tz_string_says_where_and_what_it_wanted()
  local cases: {string:string} = {
    ["EST5EDT,M13.1.0,M11.1.0"] = "daylight saving time's start's month 13 at byte 10 is not 1 through 12",
    ["E5"] = "standard time's abbreviation at byte 1: expected three or more letters",
    ["AAA"] = "standard time's offset's hours: expected a number at byte 4",
    ["AAA5BBB,M3"] = "expected \".\" after daylight saving time's start's month at byte 11",
    ["AAA5BBB,M3.2.0"] = "expected \",\" between daylight saving time's start and end at byte 15",
    ["AAA5BBB,M3.2.0,M11.1.0x"] = "unexpected text at byte 23",
    ["AAA5:60"] = "standard time's offset's minutes 60 at byte 6 is not 0 through 59",
    ["<AB>5"] = "standard time's abbreviation at byte 1: expected three or more letters, digits",
  }
  for tz, want in pairs(cases) do
    local z, why = Time.local_zone({ tz = tz })
    assert(z == nil and why:find(want, 1, true), tz .. ": " .. tostring(why))
  end
end

local function test_format_writes_a_zones_offset_and_name()
  local ny = zone("America/New_York")
  local ns = at("2026-09-25T04:09:21.5Z")
  assert(Time.format_rfc3339(ns, ny) == "2026-09-25T00:09:21.5-04:00")
  assert(Time.format_rfc3339(ns, ny, { zone_name = true, digits = 0 }) ==
    "2026-09-25T00:09:21-04:00[America/New_York]")
  -- Local mean time's offset, -4:56:02, rounds to the minute, and the
  -- local time with it, so the text names the same moment.
  local lmt = at("1800-01-01T00:00:00Z")
  local text = Time.format_rfc3339(lmt, ny, { zone_name = true })
  assert(text == "1799-12-31T19:04:00-04:56[America/New_York]", text)
  assert(Time.parse_rfc3339(text) == lmt)
  local ok, err = pcall(Time.format_rfc3339, 0, nil, { zone_name = true })
  assert(not ok and tostring(err):find("zone_name", 1, true), tostring(err))
end

local function test_parse_reads_a_zone_suffix()
  local want = at("2026-07-01T16:00:00Z")
  for _, text in ipairs({ "2026-07-01T12:00:00-04:00[America/New_York]",
      "2026-07-01T12:00:00-04:00[!America/New_York]", "2026-07-01T16:00:00Z[America/New_York]",
      "2026-07-01T16:00:00-00:00[America/New_York]", "2026-07-01T12:00:00-04:00[-04:00]",
      "2026-07-01T12:00:00-04:00[America/New_York][u-ca=iso8601]",
      "2026-07-01T12:00:00-04:00[u-ca=iso8601][x_y=a-b]", "2026-07-01T16:00:00Z[_x.y/Etc_UTC]" }) do
    local ns, why = Time.parse_rfc3339(text)
    if text:find("_x.y", 1, true) then
      assert(ns == nil and why:find("_x.y/Etc_UTC", 1, true), why)
    else
      assert(ns == want, text .. ": " .. why)
    end
  end
  -- A numeric suffix names a zone always that offset.
  local fixed = assert(Time.parse_rfc3339_zoned("2026-07-01T21:30:00+05:30[+05:30]"))
  assert(fixed.ns == want and fixed.zone.name == "+05:30")
  assert(Time.format_rfc3339(want, fixed.zone, { zone_name = true }) ==
    "2026-07-01T21:30:00+05:30[+05:30]")
  assert(Time.civil(0, fixed.zone).offset == 19800)
  local zoned = assert(Time.parse_rfc3339_zoned("2026-07-01T12:00:00-04:00[America/New_York]"))
  assert(zoned.ns == want and zoned.zone.name == "America/New_York")
  zoned = assert(Time.parse_rfc3339_zoned("2026-07-01T16:00:00Z"))
  assert(zoned.ns == want and zoned.zone == Time.UTC)
  zoned = assert(Time.parse_rfc3339_zoned("2026-07-01T21:30:00+05:30"))
  assert(zoned.ns == want and zoned.zone.name == "+05:30" and zoned.zone == fixed.zone)
  local ny = zone("America/New_York")
  local ns = at("2026-11-01T05:30:00Z")
  assert(Time.parse_rfc3339(Time.format_rfc3339(ns, ny, { zone_name = true })) == ns)
end

local function test_parse_refuses_a_suffix_that_disagrees()
  local cases: {string:string} = {
    ["2026-07-01T12:00:00-05:00[America/New_York]"] = "offset -05:00 is not America/New_York's " ..
      "at that moment, -04:00",
    ["2026-07-01T12:00:00-04:00[Nowhere/Nothing]"] = "Nowhere/Nothing",
    ["2026-07-01T12:00:00-04:00[../etc/passwd]"] = "..",
    ["2026-07-01T12:00:00-04:00[!u-ca=iso8601]"] = "critical",
    ["2026-07-01T12:00:00-04:00[America/New_York"] = "closes",
    ["2026-07-01T12:00:00-04:00[-05:00]"] = "does not match",
    ["2026-07-01T12:00:00-04:00[+4]"] = "hour",
    ["2026-07-01T12:00:00-04:00[+99:99]"] = "hour 99",
    ["2026-07-01T12:00:00-04:00[+04:99]"] = "minute 99",
    ["2026-07-01T12:00:00-04:00[-04:00x]"] = "+hh:mm",
    ["2026-07-01T12:00:00-04:00[1America/New_York]"] = "begin with a letter",
    ["2026-07-01T12:00:00-04:00[America/9York]"] = "begin with a letter",
    ["2026-07-01T12:00:00-04:00[u-ca=iso8601][America/New_York]"] = "comes first",
    ["2026-07-01T12:00:00-04:00[America/New_York][Europe/Paris]"] = "comes first",
    ["2026-07-01T12:00:00-04:00[U=x]"] = "key",
    ["2026-07-01T12:00:00-04:00[u=-x]"] = "value",
    ["2026-07-01T12:00:00-04:00[America/New_York]x"] = "unexpected",
  }
  for text, reason in pairs(cases) do
    local ns, why = Time.parse_rfc3339(text)
    assert(ns == nil and why:find(reason, 1, true), text .. ": " .. tostring(why))
  end
end

local function test_add_calendar_keeps_local_time_across_a_change()
  local ny = zone("America/New_York")
  local before = at("2026-03-07T17:00:00Z") -- noon EST
  local after = assert(Time.add_calendar(before, { days = 1 }, ny))
  assert(Time.format_rfc3339(after, ny) == "2026-03-08T12:00:00-04:00")
  assert(after - before == 23 * 3600 * NS, "the day was 23 hours long")
  assert(Time.add_calendar(before, { days = 1 }) - before == 86400 * NS, "UTC's are all 24")
  local night = at("2026-03-07T07:30:00Z") -- 02:30 EST
  local v, why = Time.add_calendar(night, { days = 1 }, ny)
  assert(v == nil and why:find("does not exist in America/New_York", 1, true), why)
  local moved = assert(Time.add_calendar(night, { days = 1 }, ny, { disambiguation = "compatible" }))
  assert(Time.format_rfc3339(moved, ny) == "2026-03-08T03:30:00-04:00")
  -- In a fold, the offset of the moment moved from chooses, as Temporal
  -- keeps it.
  local eve = at("2026-10-31T05:30:00Z") -- 01:30 EDT
  local earlier = assert(Time.add_calendar(eve, { days = 1 }, ny))
  assert(Time.format_rfc3339(earlier, ny) == "2026-11-01T01:30:00-04:00")
  local winter = at("2026-01-01T06:30:00Z") -- 01:30 EST
  local later = assert(Time.add_calendar(winter, { months = 10 }, ny))
  assert(Time.format_rfc3339(later, ny) == "2026-11-01T01:30:00-05:00")
  -- So nothing added is nothing moved, at either moment of a fold.
  for _, text in ipairs({ "2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z" }) do
    assert(Time.add_calendar(at(text), {}, ny) == at(text), text)
    assert(Time.add_calendar(at(text), { days = 0 }, ny, { disambiguation = "later" }) ==
      at(text), text)
  end
  local sofia = zone("Europe/Sofia")
  local folded = at("2026-10-25T00:30:00Z") -- 03:30 EEST, then 03:30 EET again
  assert(Time.add_calendar(folded, {}, sofia) == folded)
  local month = assert(Time.add_calendar(at("2026-01-31T15:00:00Z"), { months = 1 },
    ny, { overflow = "clamp" }))
  assert(Time.format_rfc3339(month, ny) == "2026-02-28T10:00:00-05:00")
  local ok, err = pcall(Time.add_calendar, 0, { days = 1 }, ny,
    { disambiguation = "nearest" as Time.Disambiguation })
  assert(not ok and tostring(err):find("disambiguation", 1, true), tostring(err))
end

local function test_between_follows_the_zones_calendar()
  local ny = zone("America/New_York")
  -- 23:30 and 00:30 New York time: the same UTC date, two local ones.
  local a, b = at("2026-06-02T03:30:00Z"), at("2026-06-02T04:30:00Z")
  assert(assert(Time.between(a, b)).days == 0)
  local next_day = assert(Time.between(a, b, ny))
  assert(next_day.days == 0 and next_day.ns == 3600 * NS, "one hour, whatever the dates")
  local jan31, feb28 = at("2026-02-01T04:00:00Z"), at("2026-03-01T04:00:00Z")
  local utc = assert(Time.between(jan31, feb28))
  assert(utc.months == 1 and utc.days == 0, "UTC: February 1 to March 1")
  local york = assert(Time.between(jan31, feb28, ny))
  assert(york.months == 0 and york.days == 28, "New York: January 31 to February 28")
  local noon = assert(Time.between(at("2026-01-15T17:00:00Z"), at("2026-07-15T16:00:00Z"), ny))
  assert(noon.months == 6 and noon.days == 0 and noon.ns == 0, "noon to noon, across the change")
end

--- `local_zone` takes only a zone's name from the host -- from `TZ`,
--- the /etc/localtime link, or /etc/timezone -- and the rules from the
--- binary's copy; with no name to take, UTC.
local function test_local_zone_names_a_carried_zone(tmp: string)
  local missing = tmp .. "/none"
  local function lz(tz: string, localtime?: string, timezone?: string): Time.Zone
    local z, why = Time.local_zone({ tz = tz, unset = tz == nil, localtime = localtime or missing,
      timezone = timezone or missing })
    assert(z ~= nil, tostring(tz) .. ": " .. why)
    return z
  end
  assert(rawequal(lz(nil), Time.UTC), "no /etc/localtime and no /etc/timezone is UTC")

  -- The host's file at the link's end holds Tokyo's rules: it is never
  -- read, only its path.
  local tokyo = assert(Store.zoneinfo("Asia/Tokyo"))
  assert(Fs.mkdirs(tmp .. "/share/zoneinfo/Europe"))
  assert(Fs.mkdirs(tmp .. "/share/zoneinfo/right/Europe"))
  assert(Fs.write(tmp .. "/share/zoneinfo/Europe/Berlin", tokyo))
  assert(Fs.symlink(tmp .. "/share/zoneinfo/Europe/Berlin", tmp .. "/linked"))
  local summer = at("2026-07-01T12:00:00Z")
  local linked = lz(nil, tmp .. "/linked")
  assert(rawequal(linked, zone("Europe/Berlin")), linked.name)
  assert(Time.civil(summer, linked).abbreviation == "CEST")
  assert(Time.format_rfc3339(summer, linked, { zone_name = true }) ==
    "2026-07-01T14:00:00+02:00[Europe/Berlin]")
  -- A link to a link that names no zone is followed, relative or not,
  -- as NixOS's /etc/localtime goes through /etc/zoneinfo.
  assert(Fs.symlink("linked", tmp .. "/hop"))
  assert(lz(nil, tmp .. "/hop").name == "Europe/Berlin")
  -- The zone right/ or posix/ holds is the one of its name.
  assert(Fs.symlink(tmp .. "/share/zoneinfo/right/Europe/Berlin", tmp .. "/right"))
  assert(lz(nil, tmp .. "/right").name == "Europe/Berlin")

  -- A copy, not a link, names nothing: /etc/timezone does, else UTC.
  assert(Fs.write(tmp .. "/copied", tokyo))
  assert(Fs.write(tmp .. "/timezone", "  Asia/Kolkata \nsecond line\n"))
  assert(rawequal(lz(nil, tmp .. "/copied"), Time.UTC))
  assert(lz(nil, tmp .. "/copied", tmp .. "/timezone").name == "Asia/Kolkata")
  assert(lz(nil, missing, tmp .. "/timezone").name == "Asia/Kolkata")
  -- The link wins over /etc/timezone, which may be stale.
  assert(lz(nil, tmp .. "/linked", tmp .. "/timezone").name == "Europe/Berlin")
  -- A link to a zone the binary does not carry, or /etc/timezone
  -- naming none, is passed over.
  assert(Fs.symlink(tmp .. "/share/zoneinfo/Nowhere/Nothing", tmp .. "/unknown"))
  assert(lz(nil, tmp .. "/unknown", tmp .. "/timezone").name == "Asia/Kolkata")
  -- /etc/timezone's first line that is neither blank nor a comment.
  assert(Fs.write(tmp .. "/commented", "\239\187\191# written by hand\n\n\tAsia/Kolkata\r\n"))
  assert(lz(nil, tmp .. "/copied", tmp .. "/commented").name == "Asia/Kolkata")
  assert(Fs.write(tmp .. "/garbage", "../../etc/passwd\n"))
  assert(rawequal(lz(nil, tmp .. "/unknown", tmp .. "/garbage"), Time.UTC))

  -- TZ set and empty, or ":", is UTC, as glibc, musl and tzcode have it,
  -- /etc/localtime or not.
  assert(rawequal(lz("", tmp .. "/linked"), Time.UTC))
  assert(rawequal(lz(":", tmp .. "/linked"), Time.UTC))
  -- TZ=:/path names its zone by where the path sits, as the link does,
  -- or where it links: TZ=:/etc/localtime, as glibc documents it.
  local path = lz(":" .. tmp .. "/share/zoneinfo/Europe/Berlin")
  assert(rawequal(path, zone("Europe/Berlin")))
  assert(lz(":" .. tmp .. "/linked").name == "Europe/Berlin")
  assert(lz(tmp .. "/share/zoneinfo/Europe/Berlin").name == "Europe/Berlin", "no colon, as glibc")
  assert(lz(":posix/Europe/Berlin").name == "Europe/Berlin")
  assert(lz("right/Europe/Berlin").name == "Europe/Berlin")
  -- A loop of links names nothing, and ends.
  assert(Fs.symlink(tmp .. "/loop-b", tmp .. "/loop-a"))
  assert(Fs.symlink(tmp .. "/loop-a", tmp .. "/loop-b"))
  assert(rawequal(lz(nil, tmp .. "/loop-a"), Time.UTC))
  assert(lz(":Asia/Kolkata").name == "Asia/Kolkata")
  assert(lz("Asia/Kolkata").name == "Asia/Kolkata")
  local rules = lz("EST5EDT,M3.2.0,M11.1.0")
  assert(rules.name == "EST5EDT,M3.2.0,M11.1.0" and Time.civil(summer, rules).abbreviation == "EDT")
  local utc0 = lz("UTC0")
  assert(Time.civil(summer, utc0).offset == 0 and utc0.name == "UTC0")
  -- A name the binary carries is its zone, before a POSIX string.
  assert(lz("EST5EDT").name == "EST5EDT")

  for _, tz in ipairs({ "!!!", ":Nowhere/Nothing", ":" .. tmp .. "/copied", "Nowhere/Nothing",
      ":" .. tmp .. "/loop-a",
      ":" .. tmp .. "/share/zoneinfo/Nowhere" }) do
    local z, why = Time.local_zone({ tz = tz, localtime = missing, timezone = missing })
    assert(z == nil and why ~= "", tz)
  end
end

--- A date on a zone's calendar, and a date read as the first moment of
--- that day there -- which, where clocks moved forward at midnight, is
--- the moment the day began rather than a refusal.
local function test_dates_follow_a_zones_calendar()
  local ny = zone("America/New_York")
  local late = at("2026-06-02T03:30:00Z") -- 23:30 on June 1 in New York
  assert(Time.format_date(late) == "2026-06-02")
  assert(Time.format_date(late, ny) == "2026-06-01")
  assert(Time.parse_date("2026-06-01", ny) == at("2026-06-01T04:00:00Z"))
  assert(Time.parse_date("2026-06-01") == at("2026-06-01T00:00:00Z"))
  local havana = zone("America/Havana")
  local skipped = Time.parse_date("2026-03-08", havana)
  assert(skipped == at("2026-03-08T05:00:00Z"), tostring(skipped))
  assert(Time.format_rfc3339(skipped, havana) == "2026-03-08T01:00:00-04:00")
  local v, why = Time.parse_date("2026-02-30", ny)
  assert(v == nil and why ~= "")
end

--- A day begins at its midnight, or at the moment the zone's clocks
--- skipped past it; a day skipped whole begins where the next does.
local function test_a_date_begins_where_the_zone_says()
  local toronto = zone("America/Toronto")
  local began = assert(Time.parse_date("1919-03-31", toronto))
  assert(Time.format_rfc3339(began, toronto) == "1919-03-31T00:30:00-04:00",
    Time.format_rfc3339(began, toronto))
  local apia = zone("Pacific/Apia")
  local skipped = assert(Time.parse_date("2011-12-30", apia))
  assert(skipped == at("2011-12-30T10:00:00Z"))
  assert(Time.format_date(skipped, apia) == "2011-12-31")
  local ny = zone("America/New_York")
  assert(Time.parse_date("2026-11-01", ny) == at("2026-11-01T04:00:00Z"))
end

--- A directory of the tz database is no zone.
local function test_a_directory_is_no_zone()
  local z, why = Time.zone("America")
  assert(z == nil and why:find("America", 1, true), why)
end

--- A zone the carried database lacks may be one IANA added since: the
--- refusal says how to get a newer database.
local function test_a_missing_zone_names_the_way_to_a_newer_database()
  local missing, why = Time.zone("Nowhere/Newly_Added")
  assert(missing == nil)
  assert(why:find("no time zone Nowhere/Newly_Added", 1, true), why)
  assert(why:find("`cosmic refresh tzdata --binary <this program> -o <copy>`", 1, true), why)
end

--- A bare `TZ` written as a zone name the carried database lacks says
--- the same: it may be a zone IANA added since.
local function test_a_tz_naming_a_missing_zone_names_the_way_to_a_newer_database()
  local missing, why = Time.local_zone({ tz = "Nowhere/Newly_Added" })
  assert(missing == nil)
  assert(why:find("TZ=Nowhere/Newly_Added names no zone this binary carries", 1, true), why)
  assert(why:find("`cosmic refresh tzdata --binary <this program> -o <copy>`", 1, true), why)
end
