#!/usr/bin/env cosmic
local time = require("cosmic.time")

-- HTTP, date, and ISO 8601 formatting and parsing tests

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
  local ts, err = time.parse_http("invalid")
  assert(ts == nil, "expected nil for invalid input, got " .. tostring(ts))
  assert(type(err) == "string", "expected error string, got " .. tostring(err))
end
test_parse_http_invalid()

local function test_parse_http_bad_month()
  -- structurally valid but with an unknown month name
  local ts, err = time.parse_http("Xxx, 99 Zzz 1970 99:99:99 GMT")
  assert(ts == nil, "expected nil for bad month, got " .. tostring(ts))
  assert(type(err) == "string", "expected error string, got " .. tostring(err))
end
test_parse_http_bad_month()

local function test_parse_http_out_of_range()
  -- valid month name but an impossible day: must not return a bogus timestamp
  local ts, err = time.parse_http("Mon, 99 Jan 1970 00:00:00 GMT")
  assert(ts == nil, "expected nil for out-of-range day, got " .. tostring(ts))
  assert(type(err) == "string", "expected error string, got " .. tostring(err))
end
test_parse_http_out_of_range()

local function test_format_parse_roundtrip()
  local original = 1705322245
  local formatted = time.format_http(original)
  local parsed = time.parse_http(formatted)
  assert(parsed == original, "roundtrip failed: " .. tostring(original) .. " -> " .. formatted .. " -> " .. tostring(parsed))
end
test_format_parse_roundtrip()

-- format_date tests

local function test_format_date_epoch()
  local s = time.format_date(0)
  assert(s == "1970-01-01", "expected 1970-01-01, got " .. s)
end
test_format_date_epoch()

local function test_format_date_y2k()
  local s = time.format_date(946684800)
  assert(s == "2000-01-01", "expected 2000-01-01, got " .. s)
end
test_format_date_y2k()

local function test_format_date_known()
  -- 2025-01-02T10:00:00Z = 1735812000 -> date should be 2025-01-02
  local s = time.format_date(1735812000)
  assert(s == "2025-01-02", "expected 2025-01-02, got " .. s)
end
test_format_date_known()

local function test_format_date_format()
  local secs, _ = time.now()
  local s = assert(time.format_date(secs))
  assert(string.match(s, "^%d%d%d%d%-%d%d%-%d%d$"),
    "expected YYYY-MM-DD format, got " .. s)
end
test_format_date_format()

-- parse_date tests

local function test_parse_date_basic()
  local ts = time.parse_date("2025-01-01")
  assert(ts == 1735689600, "expected 1735689600, got " .. tostring(ts))
end
test_parse_date_basic()

local function test_parse_date_epoch()
  local ts = time.parse_date("1970-01-01")
  assert(ts == 0, "expected 0, got " .. tostring(ts))
end
test_parse_date_epoch()

local function test_parse_date_y2k()
  local ts = time.parse_date("2000-01-01")
  assert(ts == 946684800, "expected 946684800, got " .. tostring(ts))
end
test_parse_date_y2k()

local function test_parse_date_invalid()
  local ts, err = time.parse_date("not-a-date")
  assert(ts == nil, "expected nil for invalid input, got " .. tostring(ts))
  assert(type(err) == "string", "expected error string, got " .. tostring(err))
end
test_parse_date_invalid()

local function test_parse_date_rejects_datetime()
  -- parse_date should reject full ISO 8601 timestamps
  local ts = time.parse_date("2025-01-01T00:00:00Z")
  assert(ts == nil, "expected nil for datetime input, got " .. tostring(ts))
end
test_parse_date_rejects_datetime()

local function test_parse_date_out_of_range()
  -- structurally well-formed but semantically invalid: no longer swallowed
  assert(time.parse_date("2025-14-01") == nil, "month 14 should be rejected")
  assert(time.parse_date("2025-01-99") == nil, "day 99 should be rejected")
end
test_parse_date_out_of_range()

local function test_date_roundtrip()
  local original = 1735689600 -- 2025-01-01 midnight UTC
  local formatted = time.format_date(original)
  local parsed = time.parse_date(formatted)
  assert(parsed == original,
    "roundtrip failed: " .. tostring(original) .. " -> " .. formatted .. " -> " .. tostring(parsed))
end
test_date_roundtrip()

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
  local s = assert(time.format_iso8601(secs))
  assert(string.match(s, "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"),
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
  assert(ts == 1735689600, "expected 1735689600 (treat), got " .. tostring(ts))
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

local function test_parse_iso8601_date_only()
  local ts = time.parse_iso8601("2025-01-01")
  assert(ts == 1735689600, "expected 1735689600, got " .. tostring(ts))
end
test_parse_iso8601_date_only()

local function test_parse_iso8601_invalid()
  local ts, err = time.parse_iso8601("not-a-date")
  assert(ts == nil, "expected nil for invalid input, got " .. tostring(ts))
  assert(type(err) == "string", "expected error string, got " .. tostring(err))
end
test_parse_iso8601_invalid()

local function test_parse_iso8601_invalid_offset()
  local ts, err = time.parse_iso8601("2025-01-01T00:00:00+garbage")
  assert(ts == nil, "expected nil for invalid offset, got " .. tostring(ts))
  assert(type(err) == "string", "expected error string, got " .. tostring(err))
end
test_parse_iso8601_invalid_offset()

local function test_parse_iso8601_out_of_range()
  -- was silently accepted as a bogus epoch before; must now be rejected
  assert(time.parse_iso8601("2025-01-99T00:00:00Z") == nil,
    "day 99 should be rejected")
  assert(time.parse_iso8601("2025-13-01T00:00:00Z") == nil,
    "month 13 should be rejected")
end
test_parse_iso8601_out_of_range()

local function test_parse_iso8601_fractional_seconds()
  -- fractional seconds are accepted (truncated to whole seconds)
  local ts = time.parse_iso8601("2025-01-01T00:00:00.500Z")
  assert(ts == 1735689600,
    "expected 1735689600 with fractional seconds, got " .. tostring(ts))
  local ts2 = time.parse_iso8601("2025-01-01T00:00:00.123456+00:00")
  assert(ts2 == 1735689600,
    "expected 1735689600 with fractional + offset, got " .. tostring(ts2))
end
test_parse_iso8601_fractional_seconds()

local function test_parse_iso8601_offset_no_colon()
  -- +HHMM / -HHMM (no colon) offset forms
  local ts = time.parse_iso8601("2025-01-01T05:30:00+0530")
  assert(ts == 1735689600, "expected 1735689600 for +0530, got " .. tostring(ts))
  local ts2 = time.parse_iso8601("2024-12-31T19:00:00-0500")
  assert(ts2 == 1735689600, "expected 1735689600 for -0500, got " .. tostring(ts2))
end
test_parse_iso8601_offset_no_colon()

local function test_parse_iso8601_offset_hours_only()
  -- +HH / -HH offset forms
  local ts = time.parse_iso8601("2025-01-01T05:00:00+05")
  assert(ts == 1735689600, "expected 1735689600 for +05, got " .. tostring(ts))
end
test_parse_iso8601_offset_hours_only()

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
