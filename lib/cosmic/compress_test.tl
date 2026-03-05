#!/usr/bin/env cosmic
local compress = require("cosmic.compress")

-- Zlib compression tests

local function test_compress_basic()
  local data = "hello world"
  local compressed = compress.compress(data)
  assert(#compressed > 0, "expected non-empty output")
  assert(compressed ~= data, "expected different output")
end
test_compress_basic()

local function test_compress_empty()
  local compressed = compress.compress("")
  assert(compressed ~= nil, "expected non-nil output for empty input")
end
test_compress_empty()

local function test_compress_binary()
  local data = "\x00\xff\x10\x20"
  local compressed = compress.compress(data)
  assert(#compressed > 0, "expected non-empty output")
end
test_compress_binary()

local function test_compress_large()
  local data = string.rep("hello world, ", 1000)
  local compressed = compress.compress(data)
  assert(#compressed < #data, "expected compression ratio for repetitive data")
end
test_compress_large()

-- Zlib decompression tests

local function test_uncompress_basic()
  local data = "hello world"
  local compressed = compress.compress(data)
  local result, err = compress.uncompress(compressed)
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == data, "expected '" .. data .. "', got '" .. (result or "nil") .. "'")
end
test_uncompress_basic()

local function test_uncompress_empty()
  local compressed = compress.compress("")
  local result, err = compress.uncompress(compressed)
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "", "expected empty string")
end
test_uncompress_empty()

local function test_uncompress_binary()
  local data = "\x00\xff\x10\x20"
  local compressed = compress.compress(data)
  local result, err = compress.uncompress(compressed)
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == data, "roundtrip mismatch for binary data")
end
test_uncompress_binary()

local function test_uncompress_invalid()
  local result, err = compress.uncompress("invalid data")
  assert(result == nil, "expected nil for invalid data")
  assert(err ~= nil, "expected error message")
end
test_uncompress_invalid()

local function test_zlib_roundtrip()
  local original = "Hello, World! This is a test of zlib compression.\x00\xff"
  local compressed = compress.compress(original)
  local result, err = compress.uncompress(compressed)
  assert(err == nil, "roundtrip failed: " .. (err or ""))
  assert(result == original, "roundtrip mismatch")
end
test_zlib_roundtrip()

-- Raw deflate tests

local function test_deflate_basic()
  local data = "hello world"
  local deflated = compress.deflate(data)
  assert(#deflated > 4, "expected output with size prefix")
end
test_deflate_basic()

local function test_deflate_empty()
  local deflated = compress.deflate("")
  assert(#deflated >= 4, "expected at least size prefix")
  -- First 4 bytes should be 0 (size = 0)
  assert(deflated:byte(1) == 0, "expected size byte 1 to be 0")
  assert(deflated:byte(2) == 0, "expected size byte 2 to be 0")
  assert(deflated:byte(3) == 0, "expected size byte 3 to be 0")
  assert(deflated:byte(4) == 0, "expected size byte 4 to be 0")
end
test_deflate_empty()

local function test_deflate_large()
  local data = string.rep("hello world, ", 1000)
  local deflated = compress.deflate(data)
  -- 4 bytes prefix + compressed data should be smaller than original
  assert(#deflated < #data, "expected compression ratio for repetitive data")
end
test_deflate_large()

-- Raw inflate tests

local function test_inflate_basic()
  local data = "hello world"
  local deflated = compress.deflate(data)
  local result, err = compress.inflate(deflated)
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == data, "expected '" .. data .. "', got '" .. (result or "nil") .. "'")
end
test_inflate_basic()

local function test_inflate_empty()
  local deflated = compress.deflate("")
  local result, err = compress.inflate(deflated)
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "", "expected empty string")
end
test_inflate_empty()

local function test_inflate_binary()
  local data = "\x00\xff\x10\x20"
  local deflated = compress.deflate(data)
  local result, err = compress.inflate(deflated)
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == data, "roundtrip mismatch for binary data")
end
test_inflate_binary()

local function test_inflate_too_short()
  local result, err = compress.inflate("abc")
  assert(result == nil, "expected nil for too-short data")
  assert(err ~= nil, "expected error message")
  assert(err:match("too short"), "error should mention 'too short'")
end
test_inflate_too_short()

local function test_inflate_invalid()
  -- 4-byte prefix claiming size 100, followed by garbage
  local invalid = "\x64\x00\x00\x00invalid"
  local result, err = compress.inflate(invalid)
  assert(result == nil, "expected nil for invalid data")
  assert(err ~= nil, "expected error message")
end
test_inflate_invalid()

local function test_deflate_roundtrip()
  local original = "Hello, World! This is a test of raw deflate compression.\x00\xff"
  local deflated = compress.deflate(original)
  local result, err = compress.inflate(deflated)
  assert(err == nil, "roundtrip failed: " .. (err or ""))
  assert(result == original, "roundtrip mismatch")
end
test_deflate_roundtrip()

-- Size prefix encoding test

local function test_deflate_size_prefix()
  -- Test with various sizes to verify little-endian encoding
  local sizes = {0, 1, 255, 256, 65535, 65536, 100000}
  for _, size in ipairs(sizes) do
    local data = string.rep("x", size)
    local deflated = compress.deflate(data)
    -- Read back the size from prefix
    local b1, b2, b3, b4 = deflated:byte(1, 4)
    local read_size = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    assert(read_size == size, "size mismatch for " .. size .. ": got " .. read_size)
    -- Verify roundtrip
    local result, err = compress.inflate(deflated)
    assert(err == nil, "roundtrip failed for size " .. size .. ": " .. (err or ""))
    assert(#result == size, "result size mismatch for " .. size)
  end
end
test_deflate_size_prefix()

-- Size limit check test

local function test_deflate_size_check_normal()
  -- Verify that normal-sized input returns result, not error
  local result, err = compress.deflate(string.rep("x", 1000))
  assert(result ~= nil, "expected success for 1000-byte input: " .. tostring(err))
  assert(err == nil, "expected no error for 1000-byte input")
end
test_deflate_size_check_normal()
