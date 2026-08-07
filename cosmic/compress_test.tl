#!/usr/bin/env cosmic
local check = require("cosmic.check")
local compress = require("cosmic.compress")

-- Round-trip tests per format

local function test_roundtrip_default_zlib()
  local data = "Hello, World! This is a test of zlib compression.\x00\xff"
  local compressed = check.must(compress.compress(data))
  assert(#compressed > 0, "expected non-empty output")
  assert(compressed ~= data, "expected different output")
  local result, err = compress.decompress(compressed)
  assert(err == nil, "roundtrip failed: " .. (err or ""))
  assert(result == data, "roundtrip mismatch")
end
test_roundtrip_default_zlib()

local function test_roundtrip_explicit_formats()
  local data = "format round-trip \x00\xff\x10\x20 payload"
  local formats: {compress.Format} = {"zlib", "gzip", "raw"}
  for _, format in ipairs(formats) do
    local compressed = check.must(compress.compress(data, {format = format}))
    -- cast: enum widening
    local result, err = compress.decompress(compressed, {format = format})
    assert(err == nil, format .. " roundtrip failed: " .. (err or ""))
    assert(result == data, format .. " roundtrip mismatch")
  end
end
test_roundtrip_explicit_formats()

local function test_roundtrip_empty_per_format()
  local formats: {compress.Format} = {"zlib", "gzip", "raw"}
  for _, format in ipairs(formats) do
    local compressed = check.must(compress.compress("", {format = format}))
    -- cast: enum widening
    local result, err = compress.decompress(compressed, {format = format})
    assert(err == nil, format .. " empty roundtrip failed: " .. (err or ""))
    assert(result == "", format .. ": expected empty string")
  end
end
test_roundtrip_empty_per_format()

local function test_compress_large()
  local data = string.rep("hello world, ", 1000)
  local compressed = check.must(compress.compress(data))
  assert(#compressed < #data, "expected compression ratio for repetitive data")
end
test_compress_large()

-- Format framing tests: outputs carry the standard headers, so they
-- interoperate with other tooling.

local function test_zlib_magic_bytes()
  local compressed = check.must(compress.compress("hello", {format = "zlib"}))
  assert(string.byte(compressed, 1) == 0x78, "expected zlib CMF byte 0x78")
end
test_zlib_magic_bytes()

local function test_gzip_magic_bytes()
  local compressed = check.must(compress.compress("hello", {format = "gzip"}))
  local b1, b2, b3 = string.byte(compressed, 1, 3)
  assert(b1 == 0x1f and b2 == 0x8b, "expected gzip magic 1f 8b")
  assert(b3 == 0x08, "expected deflate compression method byte 0x08")
end
test_gzip_magic_bytes()

local function test_raw_has_no_header()
  -- Raw is headerless DEFLATE: no zlib or gzip magic, and strictly
  -- smaller than the framed encodings of the same input.
  local data = "hello, raw deflate"
  local raw = check.must(compress.compress(data, {format = "raw"}))
  local b1, b2 = string.byte(raw, 1, 2)
  assert(not (b1 == 0x1f and b2 == 0x8b), "raw output must not carry gzip magic")
  assert(b1 ~= 0x78, "raw output must not carry zlib header")
  assert(#raw < #check.must(compress.compress(data, {format = "zlib"})), "raw must be smaller than zlib")
end
test_raw_has_no_header()

local function test_gzip_fixture_from_system_gzip()
  -- Produced by `printf 'hello from system gzip\n' | gzip -n -9` on
  -- GNU gzip: proof the format is the real one, not module-specific.
  local fixture = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03"
  .. "\xcb\x48\xcd\xc9\xc9\x57\x48\x2b\xca\xcf\x55\x28\xae\x2c\x2e"
  .. "\x49\xcd\x55\x48\xaf\xca\x2c\xe0\x02\x00"
  .. "\x45\xf2\xe3\x07\x17\x00\x00\x00"
  local result, err = compress.decompress(fixture, {format = "gzip"})
  assert(err == nil, "system gzip fixture failed: " .. (err or ""))
  assert(result == "hello from system gzip\n", "fixture content mismatch")
end
test_gzip_fixture_from_system_gzip()

-- "auto" detection tests

local function test_auto_detects_zlib_and_gzip()
  local data = "auto-detected payload"
  local formats: {compress.Format} = {"zlib", "gzip"}
  for _, format in ipairs(formats) do
    local compressed = check.must(compress.compress(data, {format = format}))
    local result, err = compress.decompress(compressed, {format = "auto"})
    assert(err == nil, "auto failed on " .. format .. ": " .. (err or ""))
    assert(result == data, "auto mismatch on " .. format)
  end
end
test_auto_detects_zlib_and_gzip()

local function test_auto_rejects_raw()
  -- Raw streams carry no header, so auto detection cannot identify them.
  local raw = check.must(compress.compress("headerless", {format = "raw"}))
  local result, err = compress.decompress(raw, {format = "auto"})
  assert(result == nil, "auto must not accept a headerless raw stream")
  assert(err ~= nil, "expected error message")
end
test_auto_rejects_raw()

-- Error handling tests

local function test_decompress_invalid()
  local result, err = compress.decompress("invalid data")
  assert(result == nil, "expected nil for invalid data")
  assert(err ~= nil, "expected error message")
end
test_decompress_invalid()

local function test_decompress_wrong_format()
  local gz = check.must(compress.compress("cross-format", {format = "gzip"}))
  local result, err = compress.decompress(gz, {format = "zlib"})
  assert(result == nil, "gzip input must not decompress as zlib")
  assert(err ~= nil, "expected error message")
end
test_decompress_wrong_format()

local function test_decompress_truncated()
  local compressed = check.must(compress.compress(string.rep("truncate me, ", 100)))
  local result, err = compress.decompress(compressed:sub(1, #compressed // 2))
  assert(result == nil, "truncated input must fail")
  assert(err ~= nil, "expected error message")
end
test_decompress_truncated()

-- Zip-bomb bound tests: max_output is enforced per format, so
-- attacker-controlled input cannot balloon memory.

local function test_max_output_bound_per_format()
  local data = string.rep("x", 2000)
  local formats: {compress.Format} = {"zlib", "gzip", "raw", "auto"}
  for _, format in ipairs(formats) do
    local cformat: compress.Format = "gzip"
    if format ~= "auto" then
      cformat = format
    end
    local compressed = check.must(compress.compress(data, {format = cformat}))
    local result, err = compress.decompress(compressed, {format = format, max_output = 100})
    assert(result == nil, format .. ": output beyond max_output must be rejected")
    assert(err ~= nil, format .. ": expected error message")

    local full = check.must(
      compress.decompress(compressed, {format = format, max_output = 2000}),
      format .. ": max_output at the exact size should pass")
    assert(#full == 2000, format .. ": roundtrip under max_output should succeed")
  end
end
test_max_output_bound_per_format()

-- Contract test: the bespoke prefixed-deflate surface is gone.

local function test_prefixed_deflate_surface_removed()
  local m = compress as {string: any} -- cast: probe removed surface
  assert(m["deflate"] == nil, "deflate must be removed")
  assert(m["inflate"] == nil, "inflate must be removed")
  assert(m["uncompress"] == nil, "uncompress must be removed (renamed decompress)")
end
test_prefixed_deflate_surface_removed()
