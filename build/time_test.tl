--- `cosmic time` (build/time.tl), run in this process with its clock,
--- host zone and output stood in for: each subcommand, zone conversion
--- across daylight saving time, how a local time in a gap or an overlap is
--- resolved, epoch input, month-end addition, and what a bad zone, time or
--- duration does. build/time_tool_test.tl starts the program for what a
--- process alone shows.

local Time = require("cosmic.time")
local time_verb = require("build.time")

local NS <const> = 1000000000

--- The fixed clock: 2026-03-08T12:00:00.123456789Z.
local NOW <const> = 1772971200 * NS + 123456789

local record Ran
  code: integer
  out: string
  err: string
end

--- One run of `cosmic time` with `words`, the clock at NOW and Tokyo the host's zone.
local function run(words: {string}, writes?: boolean): Ran
  local argv: {integer:string} = { [0] = "cosmic", [1] = "time" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = time_verb.run(argv, {
    out = function(text: string): boolean, string
      if writes == false then return false, "No space left on device" end
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    now = function(): integer return NOW end,
    local_zone = function(): Time.Zone | nil, string
      return Time.zone("Asia/Tokyo")
    end,
  })
  return ran
end

local function said(words: {string}): string
  local ran = run(words)
  assert(ran.code == 0 and ran.err == "", table.concat(words, " ") .. ": " .. ran.err)
  assert(not ran.out:find("PASS", 1, true) and not ran.out:find("FAIL", 1, true), "a verdict line")
  return ran.out
end

--- That a complaint opens `cosmic: time: ` and does not repeat it: the
--- failures of cosmic.time under it come without their own `time: `.
local function says_time_once(err: string)
  local _, count = err:gsub("time: ", "")
  assert(count == 1, err)
end

local function test_now_reads_the_clock_in_the_host_zone_by_default()
  assert(said({ "now" }) == "2026-03-08T21:00:00+09:00\n")
  assert(said({ "now", "--zone", "America/New_York" }) == "2026-03-08T08:00:00-04:00\n")
end

local function test_now_has_four_formats()
  assert(said({ "now", "--format", "date", "--zone", "Pacific/Auckland" }) == "2026-03-09\n")
  assert(said({ "now", "--format", "http" }) == "Sun, 08 Mar 2026 12:00:00 GMT\n")
  assert(said({ "now", "--format", "epoch" }) == "1772971200\n")
  assert(said({ "now", "--format", "rfc3339", "--zone", "UTC" }) == "2026-03-08T12:00:00+00:00\n")
  local bad = run({ "now", "--format", "unix" })
  assert(bad.code == 2 and bad.out == "" and bad.err:find("--format is rfc3339", 1, true), bad.err)
end

local function test_now_json_is_a_record_of_the_moment()
  local out = said({ "now", "--json", "--zone", "America/New_York" })
  for _, want in ipairs({ '"epoch": 1772971200', '"rfc3339": "2026-03-08T08:00:00-04:00"',
      '"zone": "America/New_York"', '"offset": -14400', '"dst": true', '"abbreviation": "EDT"',
      '"year": 2026', '"month": 3', '"day": 8', '"hour": 8', '"weekday": 7', '"yday": 67' }) do
    assert(out:find(want, 1, true), want .. " missing from " .. out)
  end
end

local function test_convert_follows_daylight_saving_time()
  local function ny(text: string): string
    return said({ "convert", text, "--to", "America/New_York" })
  end
  assert(ny("2026-03-08T06:59:59Z") == "2026-03-08T01:59:59-05:00\n")
  assert(ny("2026-03-08T07:00:00Z") == "2026-03-08T03:00:00-04:00\n")
  assert(ny("2026-11-01T05:59:59Z") == "2026-11-01T01:59:59-04:00\n")
  assert(ny("2026-11-01T06:00:00Z") == "2026-11-01T01:00:00-05:00\n")
  assert(said({ "convert", "2026-07-01T12:00:00+02:00", "--to", "Asia/Kolkata" }) == "2026-07-01T15:30:00+05:30\n")
  assert(said({ "convert", "2026-07-01T12:00:00Z" }) == "2026-07-01T21:00:00+09:00\n")
end

local function test_a_time_in_a_gap_lands_after_it_by_default()
  local function gap(...: string): string
    local words: {string} = { "convert", "2026-03-08T02:30", "--from", "America/New_York", "--to", "UTC" }
    for _, word in ipairs({ ... }) do words[#words + 1] = word end
    return said(words)
  end
  -- Clocks went from 02:00 EST to 03:00 EDT: 02:30 never happened.
  assert(gap() == "2026-03-08T07:30:00+00:00\n")
  assert(gap("--disambiguate", "compatible") == "2026-03-08T07:30:00+00:00\n")
  assert(gap("--disambiguate", "later") == "2026-03-08T07:30:00+00:00\n")
  assert(gap("--disambiguate", "earlier") == "2026-03-08T06:30:00+00:00\n")
  local rejected = run({ "convert", "2026-03-08T02:30", "--from", "America/New_York", "--disambiguate", "reject" })
  assert(rejected.code == 2 and rejected.out == "", rejected.out)
  assert(rejected.err:find("does not exist in America/New_York", 1, true), rejected.err)
end

local function test_a_time_in_an_overlap_is_the_earlier_by_default()
  local function overlap(...: string): string
    local words: {string} = { "convert", "2026-11-01T01:30", "--from", "America/New_York", "--to", "UTC" }
    for _, word in ipairs({ ... }) do words[#words + 1] = word end
    return said(words)
  end
  -- Clocks went from 02:00 EDT back to 01:00 EST: 01:30 happened twice.
  assert(overlap() == "2026-11-01T05:30:00+00:00\n")
  assert(overlap("--disambiguate", "earlier") == "2026-11-01T05:30:00+00:00\n")
  assert(overlap("--disambiguate", "later") == "2026-11-01T06:30:00+00:00\n")
  local rejected = run({ "convert", "2026-11-01T01:30", "--from", "America/New_York", "--disambiguate", "reject" })
  assert(rejected.code == 2 and rejected.err:find("happens twice", 1, true), rejected.err)
  -- An offset in the text says which one it is.
  assert(said({ "convert", "2026-11-01T01:30:00-05:00", "--to", "UTC", "--disambiguate", "reject" }) ==
      "2026-11-01T06:30:00+00:00\n")
end

local function test_convert_reads_epoch_dates_and_local_times()
  assert(said({ "convert", "@1700000000", "--to", "Europe/Berlin" }) == "2023-11-14T23:13:20+01:00\n")
  assert(said({ "convert", "@1700000000.5", "--to", "UTC" }) == "2023-11-14T22:13:20.5+00:00\n")
  assert(said({ "convert", "@-1", "--to", "UTC", "--format", "epoch" }) == "-1\n")
  assert(said({ "convert", "@-1.5", "--to", "UTC", "--format", "epoch" }) == "-1.5\n")
  assert(said({ "convert", "2026-05-01", "--from", "Asia/Tokyo", "--to", "UTC" }) == "2026-04-30T15:00:00+00:00\n")
  assert(said({ "convert", "2026-05-01T09:30:15", "--to", "UTC" }) == "2026-05-01T00:30:15+00:00\n")
  assert(said({ "convert", "2026-05-01T09:30", "--from", "Europe/Berlin", "--to", "UTC" }) ==
      "2026-05-01T07:30:00+00:00\n")
  assert(said({ "convert", "2026-05-01T00:00:00Z[Europe/Berlin]" }) == "2026-05-01T09:00:00+09:00\n")
end

local function test_between_counts_days_months_and_seconds()
  assert(said({ "between", "2026-01-01", "2026-09-28", "--days", "--zone", "UTC" }) == "270\n")
  assert(said({ "between", "2026-09-28", "2026-01-01", "--days", "--zone", "UTC" }) == "-270\n")
  assert(said({ "between", "2026-01-31", "2026-03-31", "--months", "--zone", "UTC" }) == "2\n")
  assert(said({ "between", "2026-01-31", "2026-02-28", "--months", "--zone", "UTC" }) == "0\n")
  assert(said({ "between", "2026-01-01T00:00:00Z", "2026-01-01T01:00:00Z", "--seconds" }) == "3600\n")
  assert(said({ "between", "@10.9", "@0", "--seconds" }) == "-10\n")
  -- The day the clocks spring forward is 23 hours long but one calendar day.
  assert(said({ "between", "2026-03-08T00:00", "2026-03-09T00:00", "--days", "--zone", "America/New_York" }) == "1\n")
  assert(said({ "between", "2026-03-08T00:00", "2026-03-09T00:00", "--seconds", "--zone", "America/New_York" }) ==
      "82800\n")
end

local function test_between_defaults_to_a_duration_add_reads_back()
  assert(said({ "between", "2026-01-31", "2026-03-01T12:30:15", "--zone", "UTC" }) == "1mo1d12h30m15s\n")
  assert(said({ "between", "2025-01-01", "2026-09-28T00:00:01.5", "--zone", "UTC" }) == "1y8mo27d1.5s\n")
  assert(said({ "between", "2026-03-01", "2026-01-31T05:00", "--zone", "UTC" }) == "-1mo19h\n")
  assert(said({ "between", "2026-01-01", "2026-01-01" }) == "0s\n")
  local start = "2025-01-31T10:00:00Z"
  local stop = "2027-03-01T03:04:05Z"
  local span = said({ "between", start, stop, "--zone", "UTC" }):gsub("\n", "")
  assert(said({ "add", start, span, "--clamp", "--zone", "UTC", "--format", "epoch" }) ==
      said({ "convert", stop, "--format", "epoch" }))
end

--- A day the zone skipped whole, as Apia's 2011-12-30, is no day of the span:
--- two hours go by while the date moves from the 29th to the 31st.
local function test_between_across_a_day_a_zone_skipped()
  local function between(...: string): string
    local words: {string} = { "between", "2011-12-29T23:00", "2011-12-31T01:00", "--zone", "Pacific/Apia" }
    for _, word in ipairs({ ... }) do words[#words + 1] = word end
    return said(words)
  end
  assert(between() == "2h\n")
  assert(between("--seconds") == "7200\n")
  assert(between("--days") == "2\n")
  assert(between("--months") == "0\n")
end

--- The months a default duration holds are the `--months` count, whatever
--- the years and days around them: 25 months is 2 years and 1.
local function test_between_months_are_the_years_and_months_of_the_duration()
  local start, stop = "2024-01-31T09:00:00Z", "2026-03-15T10:30:00Z"
  assert(said({ "between", start, stop, "--zone", "UTC" }) == "2y1mo15d1h30m\n")
  assert(said({ "between", start, stop, "--zone", "UTC", "--months" }) == "25\n")
  assert(said({ "between", stop, start, "--zone", "UTC", "--months" }) == "-25\n")
  assert(said({ "between", stop, start, "--zone", "UTC" }) == "-2y1mo15d1h30m\n")
end

local function test_add_moves_calendar_months_and_exact_time()
  assert(said({ "add", "2026-01-01T00:00:00Z", "1y2mo3d4h5m6s" }) == "2027-03-04T04:05:06+00:00\n")
  assert(said({ "add", "2026-01-01T00:00:00Z", "90m", "--zone", "UTC" }) == "2026-01-01T01:30:00+00:00\n")
  assert(said({ "add", "2026-01-01T00:00:00Z", "0.5s" }) == "2026-01-01T00:00:00.5+00:00\n")
  assert(said({ "add", "2026-03-07T12:00", "1d", "--zone", "America/New_York" }) == "2026-03-08T12:00:00-04:00\n")
  assert(said({ "add", "2026-03-07T12:00", "24h", "--zone", "America/New_York" }) == "2026-03-08T13:00:00-04:00\n")
  assert(said({ "add", "2026-03-08T12:00:00+05:30", "1d" }) == "2026-03-09T12:00:00+05:30\n")
  assert(said({ "add", "2026-03-08T12:00:00Z", "1d" }) == "2026-03-09T12:00:00+00:00\n")
  assert(said({ "add", "2026-03-08T12:00:00Z", "1d", "--zone", "Asia/Tokyo" }) == "2026-03-09T21:00:00+09:00\n")
end

local function test_a_negative_duration_moves_back()
  assert(said({ "add", "2026-03-08T00:00:00Z", "-1d" }) == "2026-03-07T00:00:00+00:00\n")
  assert(said({ "add", "2026-03-08T00:00:00Z", "-1y1mo1d1h1m1s" }) == "2025-02-06T22:58:59+00:00\n")
  assert(said({ "add", "2026-03-08T00:00:00Z", "--", "-1d" }) == "2026-03-07T00:00:00+00:00\n")
  assert(said({ "add", "2026-03-08T00:00:00Z", "+1d" }) == "2026-03-09T00:00:00+00:00\n")
end

local function test_a_day_a_month_lacks_is_an_error_unless_clamped()
  local refused = run({ "add", "2026-01-31", "1mo", "--zone", "UTC" })
  assert(refused.code == 1 and refused.out == "", refused.out)
  assert(refused.err:find("2026-02 has no day 31", 1, true), refused.err)
  assert(refused.err:find("--clamp", 1, true), refused.err)
  says_time_once(refused.err)
  assert(said({ "add", "2026-01-31", "1mo", "--clamp", "--zone", "UTC" }) == "2026-02-28T00:00:00+00:00\n")
  assert(said({ "add", "2028-01-31", "1mo", "--clamp", "--zone", "UTC" }) == "2028-02-29T00:00:00+00:00\n")
  assert(said({ "add", "2026-03-31", "-1mo", "--clamp", "--zone", "UTC" }) == "2026-02-28T00:00:00+00:00\n")
  assert(run({ "add", "2026-03-31", "-1mo", "--zone", "UTC" }).code == 1)
  assert(said({ "add", "2026-01-30", "1mo1d", "--zone", "UTC", "--clamp" }) == "2026-03-01T00:00:00+00:00\n")
end

local function test_an_add_with_no_answer_exits_1()
  local far = run({ "add", "2262-01-01", "1y", "--zone", "UTC" })
  assert(far.code == 1 and far.out == "", far.err)
  says_time_once(far.err)
  local exact = run({ "add", "2262-04-11T00:00:00Z", "999h" })
  assert(exact.code == 1 and exact.out == "", exact.out)
  -- A result in a gap under "reject".
  local gap = run({ "add", "2026-03-07T02:30", "1d", "--zone", "America/New_York", "--disambiguate", "reject" })
  assert(gap.code == 1 and gap.err:find("does not exist", 1, true), gap.err)
  says_time_once(gap.err)
  assert(said({ "add", "2026-03-07T02:30", "1d", "--zone", "America/New_York" }) == "2026-03-08T03:30:00-04:00\n")
end

local function test_add_and_between_json()
  local out = said({ "add", "2026-03-08T00:00:00Z", "-1d", "--json" })
  assert(out:find('"rfc3339": "2026-03-07T00:00:00+00:00"', 1, true), out)
  assert(out:find('"zone": "UTC"', 1, true), out)
  local between = said({ "between", "2026-01-01", "2026-01-11", "--days", "--json", "--zone", "UTC" })
  assert(between:find('"unit": "days"', 1, true) and between:find('"value": 10', 1, true), between)
  assert(between:find('"from": {', 1, true) and between:find('"to": {', 1, true), between)
  local offset = said({ "convert", "2026-03-08T12:00:00+05:30", "--to", "UTC", "--json" })
  assert(offset:find('"epoch": 1772951400', 1, true), offset)
end

--- An empty zone name is a refusal here, not the raise Time.zone makes of one.
local function test_an_empty_zone_is_refused_by_name()
  local ran = run({ "now", "--zone", "" })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("cosmic: time: --zone: the zone name is empty", 1, true), ran.err)
end

local function test_a_bad_zone_is_refused()
  for _, words in ipairs({
      { "now", "--zone", "Mars/Base" }, { "convert", "@0", "--to", "Nowhere" },
      { "convert", "2026-01-01T00:00", "--from", "../etc/passwd" }, { "add", "@0", "1d", "--zone", "" },
      { "between", "@0", "@1", "--zone", "Europe/Atlantis" },
  }) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. ": " .. ran.out)
    assert(ran.err:find("cosmic: time: --", 1, true), ran.err)
    says_time_once(ran.err)
  end
end

local function test_a_bad_duration_is_refused()
  for _, text in ipairs({ "1x", "abc", "1d1y", "", "--1d", "1.5d", "99999999999d" }) do
    local ran = run({ "add", "2026-01-01", "--", text })
    assert(ran.code == 2 and ran.out == "", ("%q: %d %s"):format(text, ran.code, ran.out))
    assert(ran.err:find("cosmic: time: \"" .. text .. "\"", 1, true), ran.err)
    says_time_once(ran.err)
  end
end

local function test_a_bad_time_is_refused()
  for _, words in ipairs({
      { "convert", "yesterday" }, { "convert", "2026-02-30" }, { "convert", "@" }, { "convert", "2026-03-08T12:00" .. "x" },
      { "add", "nonsense", "1d" }, { "between", "2026-01-01", "soon" },
  }) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. ": " .. ran.out)
    assert(ran.err:find("cosmic: time: ", 1, true), ran.err)
    says_time_once(ran.err)
  end
end

local function test_a_command_line_it_cannot_read_is_refused()
  for _, words in ipairs({
      {}, { "later" }, { "now", "extra" }, { "convert" }, { "convert", "@0", "@1" }, { "add", "@0" },
      { "between", "@0" }, { "now", "--days" }, { "convert", "@0", "--zone", "UTC" }, { "now", "--bogus" },
      { "between", "@0", "@1", "--days", "--months" }, { "now", "--json", "--format", "epoch" },
      { "convert", "@0", "--disambiguate", "sometimes" }, { "add", "@0", "1d", "--from", "UTC" },
  }) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. ": " .. ran.code .. ran.out)
    assert(ran.err:find("cosmic: time: ", 1, true) and ran.err:find("cosmic time now", 1, true), ran.err)
  end
end

local function test_a_failed_write_exits_2()
  local ran = run({ "now" }, false)
  assert(ran.code == 2, ran.code)
  assert(ran.err == "cosmic: time: standard output: No space left on device\n", ran.err)
  assert(run({ "between", "@0", "@1", "--days" }, false).code == 2)
end

local function test_rfc_3339_without_seconds_converts()
  assert(said({ "convert", "2026-03-08T12:00Z", "--to", "America/New_York" }) == "2026-03-08T08:00:00-04:00\n")
  assert(said({ "convert", "2026-03-08T12:00+05:30", "--to", "UTC" }) == "2026-03-08T06:30:00+00:00\n")
end

local function test_a_dash_digit_option_value_is_the_users_own_word()
  for _, words in ipairs({ { "now", "--zone", "-3" }, { "convert", "@0", "--to", "-1" },
      { "convert", "@0", "--from", "-2" }, { "now", "--format", "-1" } }) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " "))
    assert(ran.err:find(" -", 1, true) and not ran.err:find("\1", 1, true), ran.err)
    assert(ran.err:find(words[#words], 1, true), ran.err)
  end
end

local function test_the_two_overflow_messages_agree_and_json_names_utc_plainly()
  local a = run({ "add", "2262-01-01", "1y", "--zone", "UTC" })
  local b = run({ "add", "2262-04-11T00:00:00Z", "999h" })
  assert(a.code == 1 and b.code == 1)
  assert(a.err:find("2262-04-11T23:47:16.854775807Z", 1, true), a.err)
  assert(b.err:find("2262-04-11T23:47:16.854775807Z", 1, true), b.err)
  assert(said({ "now", "--json", "--zone", "Etc/UTC" }):find('"zone": "UTC"', 1, true))
end

local function test_the_usage_lists_every_option_of_each_subcommand()
  local ran = run({})
  assert(ran.code == 2)
  for _, name in ipairs({ "--zone", "--format", "--json", "--from", "--to", "--disambiguate", "--days",
      "--months", "--seconds", "--clamp" }) do
    assert(ran.err:find(name, 1, true), name)
  end
end

local function test_an_input_reads_every_form()
  local utc = assert(Time.zone("UTC"))
  local z = assert(time_verb.parse_input("2026-03-08T12:00:00Z", utc))
  assert(z.ns == 1772971200 * NS and z.zone == Time.UTC, z.ns)
  local offset = assert(time_verb.parse_input("2026-03-08T12:00:00+05:30", utc))
  assert(offset.ns == (1772971200 - 19800) * NS and offset.zone.name == "+05:30")
  local named = assert(time_verb.parse_input("2026-03-08T12:00:00-04:00[America/New_York]", utc))
  assert(named.zone.name == "America/New_York")
  local epoch = assert(time_verb.parse_input("@1772971200", utc))
  assert(epoch.ns == 1772971200 * NS and epoch.zone == nil)
  assert((assert(time_verb.parse_input("@-1.5", utc))).ns == -1500000000)
  assert((assert(time_verb.parse_input("@0.000000001", utc))).ns == 1)
  local date = assert(time_verb.parse_input("2026-03-08", (assert(Time.zone("Asia/Tokyo")))))
  assert(date.ns == (1772971200 - 12 * 3600 - 9 * 3600) * NS, date.ns)
  local wall = assert(time_verb.parse_input("2026-03-08T12:00", utc))
  assert(wall.ns == 1772971200 * NS)
  assert((assert(time_verb.parse_input("2026-03-08T12:00:30.25", utc))).ns == (1772971230 * NS + 250000000))
end

local function test_seconds_are_optional_in_rfc_3339_as_in_local_text()
  local utc = assert(Time.zone("UTC"))
  local full = assert(time_verb.parse_input("2026-03-08T12:00:00Z", utc))
  local short = assert(time_verb.parse_input("2026-03-08T12:00Z", utc))
  assert(short.ns == full.ns and short.zone == Time.UTC)
  local offset = assert(time_verb.parse_input("2026-03-08T12:00+05:30", utc))
  assert(offset.ns == (1772971200 - 19800) * NS and offset.zone.name == "+05:30")
  local named = assert(time_verb.parse_input("2026-03-08T08:00-04:00[America/New_York]", utc))
  assert(named.ns == full.ns and named.zone.name == "America/New_York")
  assert(assert(time_verb.parse_input("2026-03-08t12:00z", utc)).ns == full.ns)
  local none, why = time_verb.parse_input("2026-03-08T12:00+5", utc)
  assert(none == nil and why:find("RFC 3339", 1, true) and why:find("offset", 1, true), why)
end

local function test_an_error_after_the_minutes_counts_bytes_of_the_users_text()
  local _, with_seconds = time_verb.parse_input("2026-03-08T12:00:00Z x")
  local _, without = time_verb.parse_input("2026-03-08T12:00Z x")
  assert(with_seconds:find("unexpected text at byte 21", 1, true), with_seconds)
  -- "2026-03-08T12:00Z x": the stray text begins at byte 18, not 21.
  assert(without:find("unexpected text at byte 18", 1, true), without)
  local _, offset = time_verb.parse_input("2026-03-08T12:00+05:3x")
  assert(offset:find("byte 17", 1, true) or offset:find("offset", 1, true), offset)
end

local function test_every_failure_names_the_forms_then_the_fault()
  for _, text in ipairs({ "2026-02-30", "2026-03-08T25:00", "2026-03-08T12:00:00.1234567890",
      "2026-03-08T12:00:60", "@x", "@12345678901", "2026-03-08T12:00x", "2026-13-01T00:00" }) do
    local none, why = time_verb.parse_input(text)
    assert(none == nil and why:sub(1, 12) == "expected RFC", ("%q: %s"):format(text, why))
  end
end

local function test_a_gap_and_an_overlap_are_resolved_as_asked()
  local ny = assert(Time.zone("America/New_York"))
  local function read(text: string, how?: Time.Disambiguation): integer | nil, string
    local got, why = time_verb.parse_input(text, ny, how)
    if got == nil then return nil, why end
    return got.ns, ""
  end
  local function hour(ns: integer): string
    return Time.format_rfc3339(ns, ny)
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
    local got, why = time_verb.parse_input(text)
    assert(got == nil and why ~= "", ("%q read as a time"):format(text))
  end
  local _, why = time_verb.parse_input("yesterday")
  assert(why:find("RFC 3339", 1, true) and why:find("@<epoch", 1, true), why)
end
