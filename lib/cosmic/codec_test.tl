#!/usr/bin/env cosmic
local codec = require("cosmic.codec")

-- Hex encoding tests

local function test_encode_hex_basic()
  local result = codec.encode_hex("hello")
  assert(result == "68656c6c6f", "expected '68656c6c6f', got '" .. result .. "'")
end
test_encode_hex_basic()

local function test_encode_hex_empty()
  local result = codec.encode_hex("")
  assert(result == "", "expected empty string")
end
test_encode_hex_empty()

local function test_encode_hex_binary()
  local result = codec.encode_hex("\x00\xff\x10")
  assert(result == "00ff10", "expected '00ff10', got '" .. result .. "'")
end
test_encode_hex_binary()

-- Hex decoding tests

local function test_decode_hex_basic()
  local result, err = codec.decode_hex("68656c6c6f")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "hello", "expected 'hello', got '" .. (result or "nil") .. "'")
end
test_decode_hex_basic()

local function test_decode_hex_uppercase()
  local result, err = codec.decode_hex("48454C4C4F")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "HELLO", "expected 'HELLO', got '" .. (result or "nil") .. "'")
end
test_decode_hex_uppercase()

local function test_decode_hex_empty()
  local result, err = codec.decode_hex("")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "", "expected empty string")
end
test_decode_hex_empty()

local function test_decode_hex_odd_length()
  local result, err = codec.decode_hex("abc")
  assert(result == nil, "expected nil for odd length")
  assert(err ~= nil, "expected error message")
  assert(err:match("uneven"), "error should mention uneven length, got: " .. err)
end
test_decode_hex_odd_length()

local function test_decode_hex_invalid_char()
  local result, err = codec.decode_hex("ghij")
  assert(result == nil, "expected nil for invalid hex")
  assert(err ~= nil, "expected error message")
  assert(err:match("non%-hex"), "error should mention non-hex character, got: " .. err)
end
test_decode_hex_invalid_char()

local function test_hex_roundtrip()
  local original = "Hello, World! \x00\xff"
  local encoded = codec.encode_hex(original)
  local decoded, err = codec.decode_hex(encoded)
  assert(err == nil, "roundtrip decode failed: " .. (err or ""))
  assert(decoded == original, "roundtrip mismatch")
end
test_hex_roundtrip()

-- Lua encoding tests

-- encode_lua keeps the binding's error channel (issue #529, item 39):
-- the contract is string | nil, string, and success carries no error.
local function test_encode_lua_error_channel()
  local result, err = codec.encode_lua({nested = {1, 2, 3}})
  assert(type(result) == "string", "encode_lua should succeed on a plain table")
  assert(err == nil, "no error expected on success, got: " .. tostring(err))
end
test_encode_lua_error_channel()

local function test_encode_lua_string()
  local result = codec.encode_lua("hello")
  assert(result == '"hello"', "expected '\"hello\"', got '" .. result .. "'")
end
test_encode_lua_string()

local function test_encode_lua_number()
  local result = codec.encode_lua(42)
  assert(result == "42", "expected '42', got '" .. result .. "'")
end
test_encode_lua_number()

local function test_encode_lua_boolean()
  assert(codec.encode_lua(true) == "true", "expected 'true'")
  assert(codec.encode_lua(false) == "false", "expected 'false'")
end
test_encode_lua_boolean()

local function test_encode_lua_table()
  local result = codec.encode_lua({a = 1}) as string
  assert(string.match(result, "a") and string.match(result, "1"), "expected table with a=1")
end
test_encode_lua_table()

local function test_encode_lua_nil()
  local result = codec.encode_lua(nil)
  assert(result == "nil", "expected 'nil', got '" .. result .. "'")
end
test_encode_lua_nil()

-- Lua decoding tests

local function test_decode_lua_string()
  local result, err = codec.decode_lua_unsafe('"hello"')
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "hello", "expected 'hello'")
end
test_decode_lua_string()

local function test_decode_lua_number()
  local result, err = codec.decode_lua_unsafe("42")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == 42, "expected 42")
end
test_decode_lua_number()

local function test_decode_lua_boolean()
  local t, err1 = codec.decode_lua_unsafe("true")
  assert(err1 == nil and t == true, "expected true")
  local f, err2 = codec.decode_lua_unsafe("false")
  assert(err2 == nil and f == false, "expected false")
end
test_decode_lua_boolean()

local function test_decode_lua_table()
  local result, err = codec.decode_lua_unsafe('{a = 1, b = "hello"}')
  assert(err == nil, "unexpected error: " .. (err or ""))
  local t = result as {string: any}
  assert(t.a == 1, "expected a=1")
  assert(t.b == "hello", "expected b='hello'")
end
test_decode_lua_table()

local function test_decode_lua_nil()
  local result, err = codec.decode_lua_unsafe("nil")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == nil, "expected nil")
end
test_decode_lua_nil()

local function test_decode_lua_invalid()
  local result, err = codec.decode_lua_unsafe("invalid syntax {{{{")
  assert(result == nil, "expected nil for invalid syntax")
  assert(err ~= nil, "expected error message")
end
test_decode_lua_invalid()

local function test_decode_lua_unsafe_no_globals()
  -- global access should fail because load() uses empty env {}
  local result, err = codec.decode_lua_unsafe("os.execute('true')")
  assert(result == nil, "expected nil when accessing global os")
  assert(err ~= nil, "expected error message when accessing global os")
end
test_decode_lua_unsafe_no_globals()

local function test_lua_roundtrip()
  local original = {name = "test", count = 42, flag = true, nested = {x = 1, y = 2}}
  local encoded = codec.encode_lua(original)
  local decoded, err = codec.decode_lua_unsafe(encoded)
  assert(err == nil, "roundtrip decode failed: " .. (err or ""))
  local t = decoded as {string: any}
  assert(t.name == original.name, "name mismatch")
  assert(t.count == original.count, "count mismatch")
  assert(t.flag == original.flag, "flag mismatch")
  local nested = t.nested as {string: number}
  assert(nested.x == original.nested.x, "nested.x mismatch")
  assert(nested.y == original.nested.y, "nested.y mismatch")
end
test_lua_roundtrip()

-- Base64 encoding tests

local function test_encode_base64_basic()
  local result = codec.encode_base64("hello")
  assert(result == "aGVsbG8=", "expected 'aGVsbG8=', got '" .. result .. "'")
end
test_encode_base64_basic()

local function test_encode_base64_empty()
  local result = codec.encode_base64("")
  assert(result == "", "expected empty string")
end
test_encode_base64_empty()

local function test_encode_base64_binary()
  local result = codec.encode_base64("\x00\xff")
  assert(result == "AP8=", "expected 'AP8=', got '" .. result .. "'")
end
test_encode_base64_binary()

local function test_decode_base64_basic()
  local result, err = codec.decode_base64("aGVsbG8=")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "hello", "expected 'hello', got '" .. (result or "nil") .. "'")
end
test_decode_base64_basic()

local function test_decode_base64_no_padding()
  local result, err = codec.decode_base64("aGVsbG8")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "hello", "expected 'hello', got '" .. (result or "nil") .. "'")
end
test_decode_base64_no_padding()

local function test_decode_base64_empty()
  local result, err = codec.decode_base64("")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "", "expected empty string")
end
test_decode_base64_empty()

local function test_decode_base64_invalid_char()
  local result, err = codec.decode_base64("invalid!base64")
  assert(result == nil, "expected nil for invalid base64")
  assert(err ~= nil, "expected error message")
  assert(err:match("invalid"), "error should mention invalid")
end
test_decode_base64_invalid_char()

local function test_decode_base64_invalid_padding()
  local result, err = codec.decode_base64("abc===")
  assert(result == nil, "expected nil for invalid padding")
  assert(err ~= nil, "expected error message")
  assert(err:match("padding"), "error should mention padding")
end
test_decode_base64_invalid_padding()

local function test_decode_base64_padding_in_middle()
  local result, err = codec.decode_base64("ab=cd")
  assert(result == nil, "expected nil for padding in middle")
  assert(err ~= nil, "expected error message")
end
test_decode_base64_padding_in_middle()

local function test_base64_roundtrip()
  local original = "Hello, World! \x00\xff\x10"
  local encoded = codec.encode_base64(original)
  local decoded, err = codec.decode_base64(encoded)
  assert(err == nil, "roundtrip decode failed: " .. (err or ""))
  assert(decoded == original, "roundtrip mismatch")
end
test_base64_roundtrip()

-- Base32 encoding tests (z-base-32)

local function test_encode_base32_basic()
  local result = codec.encode_base32("hello")
  assert(result == "d1jprv3f", "expected 'd1jprv3f', got '" .. result .. "'")
end
test_encode_base32_basic()

local function test_encode_base32_empty()
  local result = codec.encode_base32("")
  assert(result == "", "expected empty string")
end
test_encode_base32_empty()

local function test_decode_base32_basic()
  local result, err = codec.decode_base32("d1jprv3f")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "hello", "expected 'hello', got '" .. (result or "nil") .. "'")
end
test_decode_base32_basic()

local function test_decode_base32_empty()
  local result, err = codec.decode_base32("")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "", "expected empty string")
end
test_decode_base32_empty()

local function test_decode_base32_invalid_char()
  -- base32 alphabet excludes i, l, o, u
  local result, err = codec.decode_base32("hello") -- 'l' and 'o' are invalid
  assert(result == nil, "expected nil for invalid base32")
  assert(err ~= nil, "expected error message")
  assert(err:match("invalid"), "error should mention invalid")
end
test_decode_base32_invalid_char()

local function test_decode_base32_uppercase_invalid()
  -- base32 is lowercase only
  local result, err = codec.decode_base32("ABCDEFGH")
  assert(result == nil, "expected nil for uppercase (base32 is lowercase)")
  assert(err ~= nil, "expected error message")
end
test_decode_base32_uppercase_invalid()

local function test_base32_roundtrip()
  local original = "Hello, World!"
  local encoded = codec.encode_base32(original)
  local decoded, err = codec.decode_base32(encoded)
  assert(err == nil, "roundtrip decode failed: " .. (err or ""))
  assert(decoded == original, "roundtrip mismatch")
end
test_base32_roundtrip()

-- Latin-1 encoding tests

local function test_encode_latin1_ascii()
  local result, err = codec.encode_latin1("hello")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "hello", "expected 'hello', got '" .. (result or "nil") .. "'")
end
test_encode_latin1_ascii()

local function test_encode_latin1_accented()
  local result, err = codec.encode_latin1("café")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(#result == 4, "expected 4 bytes, got " .. #result)
end
test_encode_latin1_accented()

local function test_encode_latin1_out_of_range()
  local result, err = codec.encode_latin1("日本語")
  assert(result == nil, "expected nil for out-of-range characters")
  assert(err ~= nil, "expected error message")
end
test_encode_latin1_out_of_range()

local function test_decode_latin1_basic()
  local result = codec.decode_latin1("hello")
  assert(result == "hello", "expected 'hello', got '" .. result .. "'")
end
test_decode_latin1_basic()

local function test_latin1_roundtrip()
  local original = "café résumé naïve"
  local encoded, err = codec.encode_latin1(original)
  assert(err == nil, "encode failed: " .. (err or ""))
  local decoded = codec.decode_latin1(encoded)
  assert(decoded == original, "roundtrip mismatch: got '" .. decoded .. "'")
end
test_latin1_roundtrip()

-- CRC-32 checksum tests (issue #601)

local function test_crc32_check_vector()
  -- The standard CRC-32 check value: crc32("123456789") = 0xCBF43926
  local result = codec.crc32("123456789")
  assert(result == 0xCBF43926,
    "crc32 check vector mismatch: " .. string.format("%x", result))
end
test_crc32_check_vector()

local function test_crc32c_check_vector()
  -- The standard CRC-32C (Castagnoli) check value: 0xE3069283
  local result = codec.crc32c("123456789")
  assert(result == 0xE3069283,
    "crc32c check vector mismatch: " .. string.format("%x", result))
end
test_crc32c_check_vector()

local function test_crc32_empty()
  assert(codec.crc32("") == 0, "crc32 of empty string should be 0")
  assert(codec.crc32c("") == 0, "crc32c of empty string should be 0")
end
test_crc32_empty()

local function test_crc32_incremental()
  local whole = codec.crc32("hello world")
  local partial = codec.crc32(" world", codec.crc32("hello"))
  assert(whole == partial, "incremental crc32 should match whole-input crc32")
  local whole_c = codec.crc32c("hello world")
  local partial_c = codec.crc32c(" world", codec.crc32c("hello"))
  assert(whole_c == partial_c, "incremental crc32c should match whole-input crc32c")
end
test_crc32_incremental()

local function test_crc32_unsigned_range()
  -- Values are unsigned 32-bit integers, never negative.
  local result = codec.crc32("\xff\xff\xff\xff")
  assert(result >= 0 and result <= 0xFFFFFFFF,
    "crc32 should be an unsigned 32-bit value, got " .. tostring(result))
end
test_crc32_unsigned_range()
