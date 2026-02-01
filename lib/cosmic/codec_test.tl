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
  assert(err:match("even length"), "error should mention even length")
end
test_decode_hex_odd_length()

local function test_decode_hex_invalid_char()
  local result, err = codec.decode_hex("ghij")
  assert(result == nil, "expected nil for invalid hex")
  assert(err ~= nil, "expected error message")
  assert(err:match("invalid"), "error should mention invalid")
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
  local result = codec.encode_lua({a = 1})
  assert(result:match("a") and result:match("1"), "expected table with a=1")
end
test_encode_lua_table()

local function test_encode_lua_nil()
  local result = codec.encode_lua(nil)
  assert(result == "nil", "expected 'nil', got '" .. result .. "'")
end
test_encode_lua_nil()

-- Lua decoding tests

local function test_decode_lua_string()
  local result, err = codec.decode_lua('"hello"')
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == "hello", "expected 'hello'")
end
test_decode_lua_string()

local function test_decode_lua_number()
  local result, err = codec.decode_lua("42")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == 42, "expected 42")
end
test_decode_lua_number()

local function test_decode_lua_boolean()
  local t, err1 = codec.decode_lua("true")
  assert(err1 == nil and t == true, "expected true")
  local f, err2 = codec.decode_lua("false")
  assert(err2 == nil and f == false, "expected false")
end
test_decode_lua_boolean()

local function test_decode_lua_table()
  local result, err = codec.decode_lua('{a = 1, b = "hello"}')
  assert(err == nil, "unexpected error: " .. (err or ""))
  local t = result as {string:any}
  assert(t.a == 1, "expected a=1")
  assert(t.b == "hello", "expected b='hello'")
end
test_decode_lua_table()

local function test_decode_lua_nil()
  local result, err = codec.decode_lua("nil")
  assert(err == nil, "unexpected error: " .. (err or ""))
  assert(result == nil, "expected nil")
end
test_decode_lua_nil()

local function test_decode_lua_invalid()
  local result, err = codec.decode_lua("invalid syntax {{{{")
  assert(result == nil, "expected nil for invalid syntax")
  assert(err ~= nil, "expected error message")
end
test_decode_lua_invalid()

local function test_lua_roundtrip()
  local original = {name = "test", count = 42, flag = true, nested = {x = 1, y = 2}}
  local encoded = codec.encode_lua(original)
  local decoded, err = codec.decode_lua(encoded)
  assert(err == nil, "roundtrip decode failed: " .. (err or ""))
  local t = decoded as {string:any}
  assert(t.name == original.name, "name mismatch")
  assert(t.count == original.count, "count mismatch")
  assert(t.flag == original.flag, "flag mismatch")
  local nested = t.nested as {string:number}
  assert(nested.x == original.nested.x, "nested.x mismatch")
  assert(nested.y == original.nested.y, "nested.y mismatch")
end
test_lua_roundtrip()
