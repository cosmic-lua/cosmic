#!/usr/bin/env cosmic
local time = require("cosmic.time")

-- clock_gettime tests

local function test_clock_gettime_default()
  local secs, nanos = time.clock_gettime()
  assert(secs ~= nil, "expected seconds to be non-nil")
  assert(nanos ~= nil, "expected nanoseconds to be non-nil")
  assert(secs > 0, "expected positive seconds")
  assert(nanos >= 0, "expected non-negative nanoseconds")
  assert(nanos < 1000000000, "expected nanoseconds < 1 billion")
end
test_clock_gettime_default()

local function test_clock_gettime_realtime()
  local secs, nanos = time.clock_gettime(time.CLOCK_REALTIME)
  assert(secs ~= nil, "expected seconds to be non-nil")
  assert(secs > 1700000000, "expected timestamp after 2023")
end
test_clock_gettime_realtime()

local function test_clock_gettime_monotonic()
  local secs1, _ = time.clock_gettime(time.CLOCK_MONOTONIC)
  local secs2, _ = time.clock_gettime(time.CLOCK_MONOTONIC)
  assert(secs2 >= secs1, "monotonic clock should not go backwards")
end
test_clock_gettime_monotonic()

-- now() tests

local function test_now()
  local secs, nanos = time.now()
  assert(secs ~= nil, "expected seconds to be non-nil")
  assert(nanos ~= nil, "expected nanoseconds to be non-nil")
  assert(secs > 1700000000, "expected timestamp after 2023")
end
test_now()

-- monotonic() tests

local function test_monotonic()
  local secs1, nanos1 = time.monotonic()
  local secs2, nanos2 = time.monotonic()
  local t1 = secs1 + nanos1 / 1000000000
  local t2 = secs2 + nanos2 / 1000000000
  assert(t2 >= t1, "monotonic clock should not go backwards")
end
test_monotonic()

-- sleep tests

local function test_sleep()
  local before_secs, before_nanos = time.monotonic()
  time.sleep(0, 1000000) -- sleep 1ms
  local after_secs, after_nanos = time.monotonic()
  local before = before_secs + before_nanos / 1000000000
  local after = after_secs + after_nanos / 1000000000
  assert(after > before, "time should have passed after sleep")
end
test_sleep()

local function test_sleep_zero()
  -- sleep(0) should return immediately
  local secs, nanos = time.sleep(0)
  assert(secs ~= nil, "expected seconds to be non-nil")
end
test_sleep_zero()

-- sleep_ms tests

local function test_sleep_ms()
  local before_secs, before_nanos = time.monotonic()
  time.sleep_ms(1) -- sleep 1ms
  local after_secs, after_nanos = time.monotonic()
  local before = before_secs + before_nanos / 1000000000
  local after = after_secs + after_nanos / 1000000000
  assert(after > before, "time should have passed after sleep_ms")
end
test_sleep_ms()

local function test_sleep_ms_conversion()
  -- Test that 1500ms = 1.5 seconds is handled correctly
  -- We don't actually sleep that long, just verify the function exists
  local before_secs, _ = time.monotonic()
  time.sleep_ms(0)
  local after_secs, _ = time.monotonic()
  assert(after_secs >= before_secs, "monotonic time should not go backwards")
end
test_sleep_ms_conversion()

-- gmtime tests

local function test_gmtime_epoch()
  local dt = time.gmtime(0)
  assert(dt.year == 1970, "expected year 1970, got " .. tostring(dt.year))
  assert(dt.month == 1, "expected month 1, got " .. tostring(dt.month))
  assert(dt.day == 1, "expected day 1, got " .. tostring(dt.day))
  assert(dt.hour == 0, "expected hour 0, got " .. tostring(dt.hour))
  assert(dt.min == 0, "expected min 0, got " .. tostring(dt.min))
  assert(dt.sec == 0, "expected sec 0, got " .. tostring(dt.sec))
end
test_gmtime_epoch()

local function test_gmtime_known_date()
  -- 2000-01-01 00:00:00 UTC = 946684800
  local dt = time.gmtime(946684800)
  assert(dt.year == 2000, "expected year 2000, got " .. tostring(dt.year))
  assert(dt.month == 1, "expected month 1, got " .. tostring(dt.month))
  assert(dt.day == 1, "expected day 1, got " .. tostring(dt.day))
  assert(dt.hour == 0, "expected hour 0, got " .. tostring(dt.hour))
  assert(dt.min == 0, "expected min 0, got " .. tostring(dt.min))
  assert(dt.sec == 0, "expected sec 0, got " .. tostring(dt.sec))
end
test_gmtime_known_date()

local function test_gmtime_fields()
  local dt = time.gmtime(1705322245)
  assert(dt.gmtoff == 0, "expected gmtoff 0 for UTC, got " .. tostring(dt.gmtoff))
  assert(dt.zone == "UTC" or dt.zone == "GMT", "expected UTC or GMT timezone, got " .. tostring(dt.zone))
  assert(dt.wday >= 1 and dt.wday <= 7, "expected wday 1-7, got " .. tostring(dt.wday))
  assert(dt.yday >= 1 and dt.yday <= 366, "expected yday 1-366, got " .. tostring(dt.yday))
end
test_gmtime_fields()

-- localtime tests

local function test_localtime_returns_datetime()
  local secs, _ = time.now()
  local dt = time.localtime(secs)
  assert(dt.year ~= nil, "expected year to be non-nil")
  assert(dt.month >= 1 and dt.month <= 12, "expected month 1-12, got " .. tostring(dt.month))
  assert(dt.day >= 1 and dt.day <= 31, "expected day 1-31, got " .. tostring(dt.day))
  assert(dt.hour >= 0 and dt.hour <= 23, "expected hour 0-23, got " .. tostring(dt.hour))
  assert(dt.min >= 0 and dt.min <= 59, "expected min 0-59, got " .. tostring(dt.min))
  assert(dt.sec >= 0 and dt.sec <= 60, "expected sec 0-60, got " .. tostring(dt.sec))
end
test_localtime_returns_datetime()

local function test_localtime_zone()
  local secs, _ = time.now()
  local dt = time.localtime(secs)
  assert(dt.zone ~= nil, "expected zone to be non-nil")
  assert(type(dt.zone) == "string", "expected zone to be a string")
end
test_localtime_zone()

-- Clock constants tests

local function test_clock_constants_exist()
  assert(time.CLOCK_REALTIME ~= nil, "CLOCK_REALTIME should exist")
  assert(time.CLOCK_MONOTONIC ~= nil, "CLOCK_MONOTONIC should exist")
  assert(time.CLOCK_BOOTTIME ~= nil, "CLOCK_BOOTTIME should exist")
  assert(time.CLOCK_MONOTONIC_RAW ~= nil, "CLOCK_MONOTONIC_RAW should exist")
  assert(time.CLOCK_REALTIME_COARSE ~= nil, "CLOCK_REALTIME_COARSE should exist")
  assert(time.CLOCK_MONOTONIC_COARSE ~= nil, "CLOCK_MONOTONIC_COARSE should exist")
  assert(time.CLOCK_THREAD_CPUTIME_ID ~= nil, "CLOCK_THREAD_CPUTIME_ID should exist")
  assert(time.CLOCK_PROCESS_CPUTIME_ID ~= nil, "CLOCK_PROCESS_CPUTIME_ID should exist")
end
test_clock_constants_exist()

local function test_clock_realtime_is_zero()
  -- Per the docs, CLOCK_REALTIME is always 0
  assert(time.CLOCK_REALTIME == 0, "CLOCK_REALTIME should be 0, got " .. tostring(time.CLOCK_REALTIME))
end
test_clock_realtime_is_zero()

-- format_http tests

local function test_format_http_epoch()
  local http_date = time.format_http(0)
  assert(http_date == "Thu, 01 Jan 1970 00:00:00 GMT", "expected epoch format, got " .. http_date)
end
test_format_http_epoch()

local function test_format_http_known_date()
  -- 2000-01-01 00:00:00 UTC = 946684800
  local http_date = time.format_http(946684800)
  assert(http_date == "Sat, 01 Jan 2000 00:00:00 GMT", "expected Y2K format, got " .. http_date)
end
test_format_http_known_date()

local function test_format_http_format()
  local secs, _ = time.now()
  local http_date = time.format_http(secs)
  -- Should match RFC 7231 format: "Day, DD Mon YYYY HH:MM:SS GMT"
  assert(http_date:match("^%a%a%a, %d%d %a%a%a %d%d%d%d %d%d:%d%d:%d%d GMT$"),
    "expected RFC 7231 format, got " .. http_date)
end
test_format_http_format()

-- parse_http tests

local function test_parse_http_epoch()
  local ts = time.parse_http("Thu, 01 Jan 1970 00:00:00 GMT")
  assert(ts == 0, "expected 0, got " .. tostring(ts))
end
test_parse_http_epoch()

local function test_parse_http_known_date()
  local ts = time.parse_http("Sat, 01 Jan 2000 00:00:00 GMT")
  assert(ts == 946684800, "expected 946684800, got " .. tostring(ts))
end
test_parse_http_known_date()

local function test_parse_http_invalid()
  local ts = time.parse_http("invalid")
  assert(ts == 0, "expected 0 for invalid input, got " .. tostring(ts))
end
test_parse_http_invalid()

local function test_format_parse_roundtrip()
  local original = 1705322245
  local formatted = time.format_http(original)
  local parsed = time.parse_http(formatted)
  assert(parsed == original, "roundtrip failed: " .. tostring(original) .. " -> " .. formatted .. " -> " .. tostring(parsed))
end
test_format_parse_roundtrip()

-- timegm tests

local function test_timegm_epoch()
  local ts = time.timegm(1970, 1, 1, 0, 0, 0)
  assert(ts == 0, "expected 0, got " .. tostring(ts))
end
test_timegm_epoch()

local function test_timegm_y2k()
  -- 2000-01-01 00:00:00 UTC = 946684800
  local ts = time.timegm(2000, 1, 1, 0, 0, 0)
  assert(ts == 946684800, "expected 946684800, got " .. tostring(ts))
end
test_timegm_y2k()

local function test_timegm_known_timestamp()
  -- 2025-01-01 00:00:00 UTC = 1735689600
  local ts = time.timegm(2025, 1, 1, 0, 0, 0)
  assert(ts == 1735689600, "expected 1735689600, got " .. tostring(ts))
end
test_timegm_known_timestamp()

local function test_timegm_roundtrip()
  local original = 1705322245
  local dt = time.gmtime(original)
  local back = time.timegm(dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec)
  assert(back == original, "roundtrip failed: " .. tostring(original) .. " -> " .. tostring(back))
end
test_timegm_roundtrip()

local function test_timegm_leap_year()
  -- 2024-03-01 00:00:00 UTC (2024 is a leap year)
  -- 2024-02-29 00:00:00 UTC should be valid
  local feb29 = time.timegm(2024, 2, 29, 0, 0, 0)
  local mar01 = time.timegm(2024, 3, 1, 0, 0, 0)
  assert(mar01 - feb29 == 86400, "expected 1 day between Feb 29 and Mar 1 in leap year")
end
test_timegm_leap_year()

-- format_iso8601 tests

local function test_format_iso8601_epoch()
  local s = time.format_iso8601(0)
  assert(s == "1970-01-01T00:00:00Z", "expected epoch, got " .. s)
end
test_format_iso8601_epoch()

local function test_format_iso8601_y2k()
  local s = time.format_iso8601(946684800)
  assert(s == "2000-01-01T00:00:00Z", "expected Y2K, got " .. s)
end
test_format_iso8601_y2k()

local function test_format_iso8601_known()
  -- 2025-01-02T10:00:00Z (same timestamp used in working PR tests)
  local s = time.format_iso8601(1735812000)
  assert(s == "2025-01-02T10:00:00Z", "expected 2025-01-02T10:00:00Z, got " .. s)
end
test_format_iso8601_known()

local function test_format_iso8601_format()
  local secs, _ = time.now()
  local s = time.format_iso8601(secs)
  assert(s:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"),
    "expected ISO 8601 format, got " .. s)
end
test_format_iso8601_format()

-- parse_iso8601 tests

local function test_parse_iso8601_z_suffix()
  local ts = time.parse_iso8601("2025-01-01T00:00:00Z")
  assert(ts == 1735689600, "expected 1735689600, got " .. tostring(ts))
end
test_parse_iso8601_z_suffix()

local function test_parse_iso8601_no_suffix()
  local ts = time.parse_iso8601("2025-01-01T00:00:00")
  assert(ts == 1735689600, "expected 1735689600 (treat as UTC), got " .. tostring(ts))
end
test_parse_iso8601_no_suffix()

local function test_parse_iso8601_positive_offset()
  -- 2025-01-01T05:30:00+05:30 = 2025-01-01T00:00:00Z
  local ts = time.parse_iso8601("2025-01-01T05:30:00+05:30")
  assert(ts == 1735689600, "expected 1735689600, got " .. tostring(ts))
end
test_parse_iso8601_positive_offset()

local function test_parse_iso8601_negative_offset()
  -- 2024-12-31T19:00:00-05:00 = 2025-01-01T00:00:00Z
  local ts = time.parse_iso8601("2024-12-31T19:00:00-05:00")
  assert(ts == 1735689600, "expected 1735689600, got " .. tostring(ts))
end
test_parse_iso8601_negative_offset()

local function test_parse_iso8601_invalid()
  local ts = time.parse_iso8601("not-a-date")
  assert(ts == 0, "expected 0 for invalid input, got " .. tostring(ts))
end
test_parse_iso8601_invalid()

local function test_parse_iso8601_invalid_offset()
  local ts = time.parse_iso8601("2025-01-01T00:00:00+garbage")
  assert(ts == 0, "expected 0 for invalid offset, got " .. tostring(ts))
end
test_parse_iso8601_invalid_offset()

local function test_iso8601_roundtrip()
  local original = 1705322245
  local formatted = time.format_iso8601(original)
  local parsed = time.parse_iso8601(formatted)
  assert(parsed == original,
    "roundtrip failed: " .. tostring(original) .. " -> " .. formatted .. " -> " .. tostring(parsed))
end
test_iso8601_roundtrip()

local function test_iso8601_epoch_roundtrip()
  local formatted = time.format_iso8601(0)
  local parsed = time.parse_iso8601(formatted)
  assert(parsed == 0, "epoch roundtrip failed: " .. formatted .. " -> " .. tostring(parsed))
end
test_iso8601_epoch_roundtrip()
