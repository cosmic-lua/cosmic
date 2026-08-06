#!/usr/bin/env cosmic
local check = require("cosmic.check")
local json = require("cosmic.json")

local function test_decode_object()
  local result = json.decode('{"a":1,"b":"hello"}') as {string: any} -- cast: from any
  assert(type(result) == "table", "expected table")
  assert(result.a == 1, "expected a=1")
  assert(result.b == "hello", "expected b='hello'")
end
test_decode_object()

local function test_decode_array()
  local result = json.decode('[1,2,3]') as {number} -- cast: from any
  assert(type(result) == "table", "expected table")
  assert(result[1] == 1, "expected [1]=1")
  assert(result[2] == 2, "expected [2]=2")
  assert(result[3] == 3, "expected [3]=3")
end
test_decode_array()

local function test_decode_object_typed()
  local obj = check.must(json.decode_object('{"a":1,"b":"hello"}'))
  assert(obj["a"] == 1, "expected a=1")
  assert(obj["b"] == "hello", "expected b='hello'")
  local empty = check.must(json.decode_object("{}"))
  assert(next(empty) == nil, "expected empty object")
end
test_decode_object_typed()

local function test_decode_object_wrong_shape()
  for input, kind in pairs({["[1,2]"] = "array", ["[]"] = "array",
      ["42"] = "number", ['"s"'] = "string", ["true"] = "boolean",
      ["null"] = "null"}) do
    local obj, err = json.decode_object(input)
    assert(obj == nil, "expected nil for " .. input)
    assert(err and err:find(kind, 1, true),
      "error should name the kind '" .. kind .. "', got: " .. tostring(err))
  end
  local invalid, invalid_err = json.decode_object("{nope")
  assert(invalid == nil, "expected nil for invalid JSON")
  assert(invalid_err ~= nil, "expected a decode error for invalid JSON")
end
test_decode_object_wrong_shape()

local function test_decode_array_typed()
  local items = check.must(json.decode_array('[1,"two",true]'))
  assert(#items == 3, "expected 3 items")
  assert(items[1] == 1 and items[2] == "two" and items[3] == true,
    "elements should decode in order")
  local empty = check.must(json.decode_array("[]"))
  assert(#empty == 0, "expected empty array")
  assert(json.encode(empty) == "[]", "typed empty array should re-encode as []")
end
test_decode_array_typed()

local function test_decode_array_wrong_shape()
  for input, kind in pairs({['{"a":1}'] = "object", ["{}"] = "object",
      ["42"] = "number", ["null"] = "null"}) do
    local items, err = json.decode_array(input)
    assert(items == nil, "expected nil for " .. input)
    assert(err and err:find(kind, 1, true),
      "error should name the kind '" .. kind .. "', got: " .. tostring(err))
  end
  local invalid, invalid_err = json.decode_array("[nope")
  assert(invalid == nil, "expected nil for invalid JSON")
  assert(invalid_err ~= nil, "expected a decode error for invalid JSON")
end
test_decode_array_wrong_shape()

local function test_decode_primitives()
  assert(json.decode("42") == 42, "expected 42")
  assert(json.decode('"hello"') == "hello", "expected 'hello'")
  assert(json.decode("true") == true, "expected true")
  assert(json.decode("false") == false, "expected false")
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
  local decoded = json.decode(encoded) as {string: any} -- cast: from any
  assert(decoded.name == original.name, "name mismatch")
  local nested = decoded.nested as {string: boolean} -- cast: from any
  assert(nested.flag == original.nested.flag, "nested flag mismatch")
end
test_roundtrip()

local function test_decode_invalid_json()
  local result, err = json.decode("{invalid json}")
  assert(result == nil, "expected nil for invalid json")
  assert(err ~= nil, "expected error message")
  assert(type(err) == "string", "error should be a string")
end
test_decode_invalid_json()

local function test_decode_truncated_json()
  local result, err = json.decode('{"key":')
  assert(result == nil, "expected nil for truncated json")
  assert(err ~= nil, "expected error message for truncated json")
end
test_decode_truncated_json()

local function test_decode_empty_string()
  local result, err = json.decode("")
  assert(result == nil, "expected nil for empty string")
  assert(err ~= nil, "expected error message for empty string")
end
test_decode_empty_string()

local function test_encode_invalid_value()
  local result, err = json.encode(function() end)
  assert(result == nil, "expected nil for function")
  assert(err ~= nil, "expected error message for function")
  assert(type(err) == "string", "error should be a string")
end
test_encode_invalid_value()

-- Encode options must reach the encoder, not be silently ignored

local function test_encode_pretty()
  local result = check.must(json.encode({a = 1, b = 2}, {pretty = true}),
    "pretty encode should succeed")
  assert(string.match(result, "\n"), "pretty output should contain a newline, got: " .. tostring(result))
end
test_encode_pretty()

local function test_encode_pretty_indent()
  local result = check.must(
    json.encode({a = {b = 1}, c = 2}, {pretty = true, indent = "    "}),
    "pretty encode with indent should succeed")
  assert(string.match(result, "\n    "), "output should use the custom indent, got: " .. tostring(result))
end
test_encode_pretty_indent()

local function test_encode_default_stays_compact()
  local result = json.encode({a = 1, b = 2})
  assert(result == '{"a":1,"b":2}', "default encode should stay compact, got: " .. tostring(result))
end
test_encode_default_stays_compact()

local function test_encode_maxdepth()
  local result, err = json.encode({a = {b = {c = 1}}}, {maxdepth = 2})
  assert(result == nil, "encode past maxdepth should fail")
  assert(err ~= nil, "maxdepth failure should carry an error message")
end
test_encode_maxdepth()

-- Null policy: these pin the documented (lossy) behavior so a change in the
-- C encoder/decoder shows up as a test failure, not a silent contract drift.

local function test_null_object_key_dropped()
  local decoded = json.decode('{"a":null,"b":1}') as {string: any} -- cast: from any
  assert(decoded.a == nil, "null object value should decode to nil")
  assert(decoded.b == 1, "sibling value should survive")
  local reencoded = json.encode(decoded)
  assert(reencoded == '{"b":1}', "null key is documented to vanish on re-encode, got: " .. tostring(reencoded))
end
test_null_object_key_dropped()

local function test_null_array_element_truncates()
  local decoded = json.decode("[1,null,2]") as {any} -- cast: from any
  assert(decoded[1] == 1, "first element should survive")
  assert(decoded[2] == nil, "null element should decode to nil (hole)")
  assert(decoded[3] == 2, "element after null should still be reachable")
  local reencoded = json.encode(decoded)
  assert(reencoded == "[1]", "array with hole is documented to truncate on re-encode, got: " .. tostring(reencoded))
end
test_null_array_element_truncates()

local function test_nan_inf_encoding()
  -- Non-finite numbers are rejected by default: encoding them silently
  -- would produce output that stricter JSON parsers refuse.
  local nan_json, nan_err = json.encode({0 / 0})
  assert(nan_json == nil, "NaN is documented to fail encode, got: " .. tostring(nan_json))
  assert(nan_err ~= nil, "NaN encode failure should carry an error message")
  local inf_json, inf_err = json.encode({math.huge})
  assert(inf_json == nil, "Inf is documented to fail encode, got: " .. tostring(inf_json))
  assert(inf_err ~= nil, "Inf encode failure should carry an error message")
  -- nan="null" opts into the v8 behavior for both NaN and Infinity.
  local nan_null = json.encode({0 / 0}, {nan = "null"})
  assert(nan_null == "[null]", "NaN with nan='null' should encode, got: " .. tostring(nan_null))
  local inf_null = json.encode({math.huge, -math.huge}, {nan = "null"})
  assert(inf_null == "[null,null]", "Inf with nan='null' should encode, got: " .. tostring(inf_null))
end
test_nan_inf_encoding()

-- Precision, nesting, \uXXXX escapes, and NUL bytes.

local function test_integer_precision_roundtrip()
  -- 2^53 + 1 is not representable as a double; it survives only if the
  -- encoder and decoder keep 64-bit integers as integers.
  local n = 9007199254740993
  local encoded = check.must(json.encode(n))
  assert(encoded == "9007199254740993",
    "integer must encode without float rounding, got: " .. tostring(encoded))
  local decoded = json.decode(encoded)
  assert(decoded == n, "integer must round-trip exactly")
  assert(math.type(decoded) == "integer",
    "decoded integer should stay an integer")
end
test_integer_precision_roundtrip()

local function test_float_precision_roundtrip()
  for _, f in ipairs({0.1, 3.141592653589793, 1e308, -2.5e-10}) do
    local decoded = json.decode((check.must(json.encode(f))))
    assert(decoded == f,
      "float should round-trip bit-exactly: " .. tostring(f)
      .. " -> " .. tostring(decoded))
  end
end
test_float_precision_roundtrip()

local function test_decode_unicode_escapes()
  assert(json.decode('"\\u0041"') == "A", "\\u0041 should decode to A")
  assert(json.decode('"\\u00e9"') == "\xc3\xa9",
    "\\u00e9 should decode to UTF-8 e-acute")
  -- Surrogate pair: U+1F600 (emoji) is 4 UTF-8 bytes.
  local emoji = json.decode('"\\uD83D\\uDE00"')
  assert(emoji == "\xf0\x9f\x98\x80",
    "surrogate pair should decode to 4-byte UTF-8, got " .. tostring(emoji))
end
test_decode_unicode_escapes()

local function test_nul_byte_roundtrip()
  local decoded = json.decode('"\\u0000"') as string -- cast: from any
  assert(#decoded == 1 and decoded == "\0",
    "\\u0000 should decode to a 1-byte NUL string")
  local encoded = json.encode("\0")
  assert(encoded == '"\\u0000"',
    "an embedded NUL should encode as \\u0000, got: " .. tostring(encoded))
  local rt = json.decode((check.must(json.encode("a\0b"))))
  assert(rt == "a\0b" and #rt == 3, "NUL inside a string must round-trip")
end
test_nul_byte_roundtrip()

local function test_decode_depth_limit()
  -- 63 nested arrays decode; 64 exceed the C decoder's depth limit and
  -- must fail with a clean error, never crash or recurse unbounded.
  local ok63 = string.rep("[", 63) .. "1" .. string.rep("]", 63)
  assert(json.decode(ok63) ~= nil, "63 nesting levels should decode")
  local deep = string.rep("[", 64) .. "1" .. string.rep("]", 64)
  local decoded, err = json.decode(deep)
  assert(decoded == nil, "64 nesting levels should be rejected")
  assert(err and err:match("depth"),
    "error should name the depth limit, got: " .. tostring(err))
end
test_decode_depth_limit()

local function test_encode_default_depth_limit()
  -- Without an explicit maxdepth, a very deep table still fails cleanly.
  local t: {any} = {1}
  local root = t
  for _ = 1, 200 do
    local inner: {any} = {1}
    t[1] = inner
    t = inner
  end
  local encoded, err = json.encode(root)
  assert(encoded == nil, "encoding a 200-deep table should fail")
  assert(err ~= nil, "deep-table failure should carry an error message")
end
test_encode_default_depth_limit()

local function test_empty_array_roundtrip()
  -- Decoded arrays carry the shared array marker, so [] survives a
  -- round-trip instead of collapsing into {}.
  local decoded = json.decode("[]")
  assert(json.encode(decoded) == "[]", "decoded [] should re-encode as []")
  -- Unmarked empty tables stay objects; array() opts a table in.
  assert(json.encode({}) == "{}", "a plain empty table should encode as {}")
  assert(json.encode(json.array({})) == "[]", "array({}) should encode as []")
  assert(json.encode(json.array()) == "[]", "array() should create an empty array")
  local marked = json.array({1, 2})
  assert(json.encode(marked) == "[1,2]", "array() must not disturb elements")
end
test_empty_array_roundtrip()
