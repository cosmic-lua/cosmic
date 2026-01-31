#!/usr/bin/env cosmic
local json = require("cosmic.json")

local function test_decode_object()
  local result = json.decode('{"a":1,"b":"hello"}') as {string:any}
  assert(type(result) == "table", "expected table")
  assert(result.a == 1, "expected a=1")
  assert(result.b == "hello", "expected b='hello'")
end
test_decode_object()

local function test_decode_array()
  local result = json.decode('[1,2,3]') as {number}
  assert(type(result) == "table", "expected table")
  assert(result[1] == 1, "expected [1]=1")
  assert(result[2] == 2, "expected [2]=2")
  assert(result[3] == 3, "expected [3]=3")
end
test_decode_array()

local function test_decode_primitives()
  assert(json.decode("42") as number == 42, "expected 42")
  assert(json.decode('"hello"') as string == "hello", "expected 'hello'")
  assert(json.decode("true") as boolean == true, "expected true")
  assert(json.decode("false") as boolean == false, "expected false")
  assert(json.decode("null") == nil, "expected nil")
end
test_decode_primitives()

local function test_encode_object()
  local result = json.encode({a = 1})
  assert(result == '{"a":1}', "expected '{\"a\":1}', got '" .. result .. "'")
end
test_encode_object()

local function test_encode_array()
  local result = json.encode({1, 2, 3})
  assert(result == "[1,2,3]", "expected '[1,2,3]', got '" .. result .. "'")
end
test_encode_array()

local function test_encode_primitives()
  assert(json.encode(42) == "42", "expected '42'")
  assert(json.encode("hello") == '"hello"', "expected '\"hello\"'")
  assert(json.encode(true) == "true", "expected 'true'")
  assert(json.encode(false) == "false", "expected 'false'")
end
test_encode_primitives()

local function test_roundtrip()
  local original = {name = "test", values = {1, 2, 3}, nested = {flag = true}}
  local encoded = json.encode(original)
  local decoded = json.decode(encoded) as {string:any}
  assert(decoded.name == original.name, "name mismatch")
  local nested = decoded.nested as {string:boolean}
  assert(nested.flag == original.nested.flag, "nested flag mismatch")
end
test_roundtrip()
