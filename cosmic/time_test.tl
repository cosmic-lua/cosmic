#!/usr/bin/env cosmic
local time = require("cosmic.time")
local check = require("cosmic.check")

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

-- Every clock reader asserts its clock_gettime read (D23's
-- unreachable-nil rule), so the values that reach a caller are the
-- plain integers the signatures declare. The assert's own failure path
-- is unreachable through the public API — cosmopolitan guarantees
-- neither clock raises EINVAL — so this pins what callers receive.
local function test_clock_readers_return_integers()
  local secs, nanos = time.now()
  assert(math.type(secs) == "integer", "now() seconds should be an integer")
  assert(math.type(nanos) == "integer", "now() nanoseconds should be an integer")
  local msecs, mnanos = time.monotonic()
  assert(math.type(msecs) == "integer", "monotonic() seconds should be an integer")
  assert(math.type(mnanos) == "integer", "monotonic() nanoseconds should be an integer")
  assert(math.type(time.now_ms()) == "integer", "now_ms() should be an integer")
  local before = time.monotonic_ms()
  assert(math.type(before) == "integer", "monotonic_ms() should be an integer")
  assert(time.monotonic_ms() >= before, "monotonic_ms should not go backwards")
  local ns_before = time.monotonic_ns()
  assert(math.type(ns_before) == "integer", "monotonic_ns() should be an integer")
  assert(time.monotonic_ns() >= ns_before, "monotonic_ns should not go backwards")
end
test_clock_readers_return_integers()

-- sleep tests

-- sleep_ms is THE sleep: integer milliseconds in, a single
-- milliseconds remainder out.
local function test_sleep_ms_passes_time()
  local before_secs, before_nanos = time.monotonic()
  assert(time.sleep_ms(1))
  local after_secs, after_nanos = time.monotonic()
  local before = before_secs + before_nanos / 1000000000
  local after = after_secs + after_nanos / 1000000000
  assert(after > before, "time should have passed after sleep_ms")
end
test_sleep_ms_passes_time()

local function test_sleep_ms_zero_returns_immediately()
  local rem, err = time.sleep_ms(0)
  assert(rem == 0, "expected 0 remaining ms, got " .. tostring(rem))
  assert(err == nil, "expected no error, got " .. tostring(err))
end
test_sleep_ms_zero_returns_immediately()

local function test_sleep_ms_invalid_names_errno()
  local rem, err = time.sleep_ms(-1000)
  assert(rem == nil, "invalid sleep_ms should return a nil remainder")
  assert(type(err) == "string" and err:match("EINVAL"),
    "sleep_ms error should name EINVAL, got: " .. tostring(err))
end
test_sleep_ms_invalid_names_errno()

-- sleep_ms's remainder is a single milliseconds number -- no more
-- (secs, nanos) two-integer arithmetic in retry loops.

local function test_sleep_ms_uninterrupted_returns_zero_ms()
  local rem, err = time.sleep_ms(1)
  assert(rem == 0, "uninterrupted sleep_ms returns 0 ms, got " .. tostring(rem))
  assert(err == nil, "no error on a clean sleep, got " .. tostring(err))
end
test_sleep_ms_uninterrupted_returns_zero_ms()

local function test_sleep_ms_interrupted_returns_ms_remainder()
  local signal = require("cosmic.signal")

  local prev = check.must(signal.sigaction(signal.SIGALRM, function(_: number) end))
  -- Single-shot timer: interrupt the sleep after ~50ms.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 50,
        interval_ms = 0,
      }))

  local rem, err = time.sleep_ms(2000)

  -- Disarm and restore before asserting so a failure can't leave a
  -- ticking timer behind.
  assert(signal.setitimer({
        which = signal.ITIMER_REAL,
        value_ms = 0,
        interval_ms = 0,
      }))
  assert(signal.sigaction(signal.SIGALRM, prev.handler, prev.flags, prev.mask))

  assert(rem ~= nil, "interrupted sleep_ms must return a remainder")
  assert(rem > 0 and rem <= 2000,
    "remainder must be milliseconds within the requested duration, got "
    .. tostring(rem))
  assert(err and tostring(err):match("EINTR"),
    "interrupted sleep_ms error should name EINTR, got: " .. tostring(err))
end
test_sleep_ms_interrupted_returns_ms_remainder()

-- sleep_ms tests

local function test_sleep_ms()
  local before_secs, before_nanos = time.monotonic()
  assert(time.sleep_ms(1)) -- sleep 1ms
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
  assert(time.sleep_ms(0))
  local after_secs, _ = time.monotonic()
  assert(after_secs >= before_secs, "monotonic time should not go backwards")
end
test_sleep_ms_conversion()

-- gmtime tests

local function test_gmtime_epoch()
  local dt = check.must(time.gmtime(0))
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
  local dt = check.must(time.gmtime(946684800))
  assert(dt.year == 2000, "expected year 2000, got " .. tostring(dt.year))
  assert(dt.month == 1, "expected month 1, got " .. tostring(dt.month))
  assert(dt.day == 1, "expected day 1, got " .. tostring(dt.day))
  assert(dt.hour == 0, "expected hour 0, got " .. tostring(dt.hour))
  assert(dt.min == 0, "expected min 0, got " .. tostring(dt.min))
  assert(dt.sec == 0, "expected sec 0, got " .. tostring(dt.sec))
end
test_gmtime_known_date()

local function test_gmtime_fields()
  local dt = check.must(time.gmtime(1705322245))
  assert(dt.gmtoff == 0, "expected gmtoff 0 for UTC, got " .. tostring(dt.gmtoff))
  assert(dt.zone == "UTC" or dt.zone == "GMT", "expected UTC or GMT timezone, got " .. tostring(dt.zone))
  assert(dt.wday >= 0 and dt.wday <= 6, "expected wday 0-6, got " .. tostring(dt.wday))
  assert(dt.yday >= 0 and dt.yday <= 365, "expected yday 0-365, got " .. tostring(dt.yday))
end
test_gmtime_fields()

-- A timestamp the C library cannot break down is an honest error, not a
-- throw: the binding reports EOVERFLOW in the slot the month occupies on
-- success, and both wrappers return it as nil + message.

local function test_gmtime_unrepresentable_is_an_error()
  local dt, err = time.gmtime(1 << 62)
  assert(dt == nil, "an unrepresentable timestamp yields no DateTime")
  assert(err ~= nil and err:match("EOVERFLOW"),
    "gmtime should name EOVERFLOW, got: " .. tostring(err))
end
test_gmtime_unrepresentable_is_an_error()

local function test_localtime_unrepresentable_is_an_error()
  local dt, err = time.localtime(1 << 62)
  assert(dt == nil, "an unrepresentable timestamp yields no DateTime")
  assert(err ~= nil and err:match("EOVERFLOW"),
    "localtime should name EOVERFLOW, got: " .. tostring(err))
end
test_localtime_unrepresentable_is_an_error()

-- localtime tests

local function test_localtime_returns_datetime()
  local secs, _ = time.now()
  local dt = check.must(time.localtime(secs))
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
  local dt = check.must(time.localtime(secs))
  assert(dt.zone ~= nil, "expected zone to be non-nil")
  assert(type(dt.zone) == "string", "expected zone to be a string")
end
test_localtime_zone()

-- Clock constants tests

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
  local dt = check.must(time.gmtime(original))
  local back = time.timegm(dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec)
  assert(back == original, "roundtrip failed: " .. tostring(original) .. " -> " .. tostring(back))
end
test_timegm_roundtrip()

local function test_timegm_epoch_is_zero()
  -- unix epoch must be exactly 0
  local ts = time.timegm(1970, 1, 1, 0, 0, 0)
  assert(ts == 0, "expected 0, got " .. tostring(ts))
end
test_timegm_epoch_is_zero()

local function test_timegm_one_second_before_epoch()
  -- 1969-12-31 23:59:59 UTC = -1
  local ts = time.timegm(1969, 12, 31, 23, 59, 59)
  assert(ts == -1, "expected -1, got " .. tostring(ts))
end
test_timegm_one_second_before_epoch()

local function test_timegm_pre_epoch_1960()
  -- 1960-01-01 00:00:00 UTC = -315619200
  local ts = time.timegm(1960, 1, 1, 0, 0, 0)
  assert(ts == -315619200, "expected -315619200, got " .. tostring(ts))
end
test_timegm_pre_epoch_1960()

local function test_timegm_midnight_dec_31_1969()
  -- 1969-12-31 00:00:00 UTC = -86400
  local ts = time.timegm(1969, 12, 31, 0, 0, 0)
  assert(ts == -86400, "expected -86400, got " .. tostring(ts))
end
test_timegm_midnight_dec_31_1969()

local function test_timegm_pre_epoch_roundtrip()
  -- gmtime(-86400) -> timegm should return -86400
  local dt = check.must(time.gmtime(-86400))
  local rt = time.timegm(dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec)
  assert(rt == -86400, "roundtrip failed: got " .. tostring(rt))
end
test_timegm_pre_epoch_roundtrip()

local function test_timegm_bad_month_no_throw()
  -- month 14 must return nil, err rather than throwing an arithmetic error
  local ts, err = time.timegm(2025, 14, 1, 0, 0, 0)
  assert(ts == nil, "expected nil for month 14, got " .. tostring(ts))
  assert(type(err) == "string", "expected error string, got " .. tostring(err))
end
test_timegm_bad_month_no_throw()

local function test_timegm_month_thirteen()
  -- month 13 must not silently roll into next January
  local ts = time.timegm(2025, 13, 1, 0, 0, 0)
  assert(ts == nil, "expected nil for month 13, got " .. tostring(ts))
end
test_timegm_month_thirteen()

local function test_timegm_bad_day()
  -- Feb 30 does not exist
  local ts, err = time.timegm(2025, 2, 30, 0, 0, 0)
  assert(ts == nil, "expected nil for Feb 30, got " .. tostring(ts))
  assert(type(err) == "string", "expected error string, got " .. tostring(err))
end
test_timegm_bad_day()

local function test_timegm_feb29_non_leap()
  -- 2025 is not a leap year, so Feb 29 is invalid
  local ts = time.timegm(2025, 2, 29, 0, 0, 0)
  assert(ts == nil, "expected nil for Feb 29 in 2025, got " .. tostring(ts))
end
test_timegm_feb29_non_leap()

local function test_timegm_feb29_leap_ok()
  -- 2024 is a leap year, so Feb 29 is valid
  local ts = time.timegm(2024, 2, 29, 0, 0, 0)
  assert(ts ~= nil, "expected valid timestamp for Feb 29 in 2024")
end
test_timegm_feb29_leap_ok()

local function test_timegm_zero_day()
  local ts = time.timegm(2025, 1, 0, 0, 0, 0)
  assert(ts == nil, "expected nil for day 0, got " .. tostring(ts))
end
test_timegm_zero_day()

local function test_timegm_bad_time_fields()
  assert(time.timegm(2025, 1, 1, 24, 0, 0) == nil, "hour 24 should be invalid")
  assert(time.timegm(2025, 1, 1, 0, 60, 0) == nil, "minute 60 should be invalid")
  assert(time.timegm(2025, 1, 1, 0, 0, 61) == nil, "second 61 should be invalid")
end
test_timegm_bad_time_fields()

-- millisecond clocks

local function test_now_ms_matches_now()
  local secs = time.now()
  local ms = time.now_ms()
  local diff = ms - secs * 1000
  assert(diff >= 0 and diff < 2000,
    "now_ms should agree with now() within 2s, diff " .. tostring(diff))
  assert(ms == math.floor(ms), "now_ms must return whole milliseconds")
end
test_now_ms_matches_now()

local function test_monotonic_ms_advances()
  local t1 = time.monotonic_ms()
  assert(time.sleep_ms(15))
  local t2 = time.monotonic_ms()
  local delta = t2 - t1
  assert(delta >= 10, "expected >= 10ms elapsed across sleep_ms(15), got " .. tostring(delta))
  assert(delta < 60000, "elapsed time should be sane, got " .. tostring(delta))
  assert(t2 == math.floor(t2), "monotonic_ms must return whole milliseconds")
end
test_monotonic_ms_advances()

-- timegm civil-days algorithm: spot checks across eras, leap days, and
-- century rules (values from Python's calendar.timegm)

local function test_timegm_pre_epoch()
  assert(time.timegm(1969, 12, 31, 23, 59, 59) == -1, "one second before epoch")
  assert(time.timegm(1900, 1, 1, 0, 0, 0) == -2208988800, "1900 (not a leap year)")
  assert(time.timegm(1600, 1, 1, 0, 0, 0) == -11676096000, "1600 (leap century)")
end
test_timegm_pre_epoch()

-- isdst is a boolean

local function test_gmtime_isdst_boolean()
  local dt = check.must(time.gmtime(0))
  assert(dt.isdst == false, "UTC never observes DST, got " .. tostring(dt.isdst))
  local lt = check.must(time.localtime(0))
  assert(type(lt.isdst) == "boolean", "localtime isdst must be a boolean")
end
test_gmtime_isdst_boolean()
