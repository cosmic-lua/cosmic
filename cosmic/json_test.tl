--- Proves cosmic.json reads exactly RFC 8259 JSON, says where text
--- stopped being JSON, keeps integers and floats apart and exact, and
--- refuses to encode what JSON cannot say rather than writing something
--- else.

local Hash = require("cosmic.hash")
local Json = require("cosmic.json")

--- The value and an empty message, or a failed assertion naming the
--- message.
local function decoded(text: string, opts?: Json.DecodeOptions): any
  local value, err = Json.decode(text, opts)
  assert(err == "", "decode failed on " .. text .. ": " .. err)
  return value
end

local function encoded(value: any, opts?: Json.EncodeOptions): string
  local text, err = Json.encode(value, opts)
  assert(text ~= nil, "encode failed: " .. err)
  assert(err == "", "a success carries \"\" in the error slot")
  return text
end

--- The message decode fails on `text` with; the test fails if it does not.
local function decode_failure(text: string, opts?: Json.DecodeOptions): string
  local value, err = Json.decode(text, opts)
  assert(value == nil and err ~= "", "expected " .. string.format("%q", text) .. " to fail")
  return err
end

local function encode_failure(value: any, opts?: Json.EncodeOptions): string
  local text, err = Json.encode(value, opts)
  assert(text == nil and err ~= "", "expected encode to fail, got " .. tostring(text))
  return err
end

--- Whether two decoded values are the same value: same types, same
--- numbers down to integer or float, same keys.
local function same(a: any, b: any): boolean
  if type(a) ~= type(b) then return false end
  if type(a) == "number" then
    return math.type(a as number) == math.type(b as number) and a == b
  end
  if type(a) ~= "table" then return a == b end
  local x = a as {any: any}
  local y = b as {any: any}
  if Json.is_array(x) ~= Json.is_array(y) then return false end
  for k, v in pairs(x) do
    if not same(v, y[k]) then return false end
  end
  for k in pairs(y) do
    if x[k] == nil then return false end
  end
  return true
end

local function test_decode_object()
  local v = decoded('{"a": 1, "b": "hello", "c": [true, false]}') as {string: any}
  assert(v.a == 1 and v.b == "hello", "members decode by key")
  local c = v.c as {boolean}
  assert(c[1] == true and c[2] == false and #c == 2, "a nested array decodes")
  assert(not Json.is_array(v), "an object carries no array mark")
  assert(Json.is_array(c), "an array carries the array mark")
end

local function test_decode_scalars()
  assert(decoded("42") == 42, "a number")
  assert(decoded('"s"') == "s", "a string")
  assert(decoded("true") == true and decoded("false") == false, "the booleans")
  local value, err = Json.decode("null")
  assert(value == nil and err == "", "null is nil with an empty message")
  assert(decoded(" \t\r\n[] \n") ~= nil, "whitespace around a value is allowed")
end

local function test_decode_object_and_array_check_the_shape()
  local obj, err = Json.decode_object('{"a": 1}')
  assert(obj ~= nil and obj.a == 1 and err == "", "an object is an object")
  local empty = Json.decode_object("{}")
  assert(empty ~= nil and next(empty) == nil, "{} is an empty object")
  local list = Json.decode_array('[1, "two"]')
  assert(list ~= nil and list[2] == "two", "an array is an array")
  for text, kind in pairs({ ["[1]"] = "array", ["[]"] = "array", ["42"] = "number",
      ['"s"'] = "string", ["true"] = "boolean", ["null"] = "null" }) do
    local none, why = Json.decode_object(text)
    assert(none == nil and why == "json: expected a JSON object, got " .. kind, why)
  end
  for text, kind in pairs({ ['{"a": 1}'] = "object", ["{}"] = "object", ["1.5"] = "number",
      ["null"] = "null" }) do
    local none, why = Json.decode_array(text)
    assert(none == nil and why == "json: expected a JSON array, got " .. kind, why)
  end
  local _, sentinel_why = Json.decode_object("null", { null_value = Json.null })
  assert(sentinel_why == "json: expected a JSON object, got null", sentinel_why)
  local _, invalid = Json.decode_array("[1,")
  assert(invalid:match("^json: invalid JSON"), "a syntax error passes through: " .. invalid)
end

local function test_a_failure_names_line_and_column()
  local err = decode_failure('{\n  "a": tru\n}')
  assert(err:match("^json: invalid JSON at line 2, column 8: "), err)
  assert(decode_failure("[1] x"):match("line 1, column 5: unexpected content"), "trailing text")
  assert(decode_failure("") == "json: invalid JSON: the text is empty", "empty text")
  assert(decode_failure(" \n ") == "json: invalid JSON: the text is empty", "blank text")
end

local function test_only_rfc_8259_is_read()
  for _, text in ipairs({
      "[1,]", '{"a":1,}', "// c\n1", "/* c */ 1", "NaN", "Infinity", "-Infinity",
      "'s'", "{a:1}", "0x10", "+1", ".5", "1.", "01", '"\\x41"', '"\\a"',
      '"tab\tinside"', "\239\187\191{}", "[1] [2]", "tru", "nul",
  }) do
    decode_failure(text)
  end
end

local function test_json5_is_read_when_asked()
  local five = { json5 = true }
  local text = [[
// a comment
{
  unquoted: 'single',
  "trailing": [1, 2,],
  hex: 0x1F, plus: +1, lead: .5, trail: 5.,
  /* block */ nl: "a\
b",
}
]]
  local v = decoded(text, five) as {string: any}
  assert(v.unquoted == "single", "an unquoted key and a single-quoted string")
  local list = v.trailing as {integer}
  assert(#list == 2 and Json.is_array(list), "a trailing comma")
  assert(v.hex == 31 and math.type(v.hex as number) == "integer", "a hexadecimal integer")
  assert(v.plus == 1 and v.lead == 0.5 and v.trail == 5.0, "the other number forms")
  assert(v.nl == "ab", "a line continuation")
  local nan = decoded("NaN", five) as number
  assert(nan ~= nan, "NaN is the float")
  assert(decoded("-Infinity", five) == -math.huge, "and so is -Infinity")
  assert(decoded("[inf]", five) ~= nil, "yyjson takes inf in any case")
  assert(decoded("'\\a'", five) == "\a", "and escapes JSON5 does not have")
  assert(Json.decode_object("{a: 1,}", five) ~= nil, "decode_object takes json5")
  assert(Json.decode_array("[1,]", five) ~= nil, "and decode_array")
  assert(decode_failure("{a: 1,}"):match("^json: invalid JSON"), "the default stays strict")
  assert(decode_failure("{a: 1", five):match("^json: invalid JSON at line 1"), "JSON5 fails with a place too")
  assert(encoded(decoded("{a: [1,],}", five)) == '{"a":[1]}', "output is RFC 8259")
end

local function test_strings_are_utf8()
  assert(decoded('"\\u0041\\u00e9"') == "A\xc3\xa9", "escapes decode to UTF-8")
  assert(decoded('"\\ud83d\\ude00"') == "\xf0\x9f\x98\x80", "a surrogate pair is one character")
  assert(decode_failure('"\\ud800"'):match("surrogate"), "a lone high surrogate")
  decode_failure('"\\udc00"')
  assert(decode_failure('"\xff"'):match("UTF%-8"), "a byte that is not UTF-8")
  decode_failure('"\xed\xa0\x80"')
  decode_failure('"\xc0\xaf"')
  local nul = decoded('"a\\u0000b"') as string
  assert(#nul == 3 and nul == "a\0b", "an escaped NUL is one byte")
  assert(encoded("a\0b") == '"a\\u0000b"', "a NUL encodes escaped")
end

local function test_encode_refuses_what_is_not_utf8()
  assert(encode_failure("\xff") == "json: cannot encode a string that is not UTF-8", "a stray byte")
  encode_failure("\xc0\xaf")
  encode_failure("\xed\xa0\x80")
  encode_failure("\xf4\x90\x80\x80")
  encode_failure("\xe2\x82")
  encode_failure({ ["\xff"] = 1 })
  assert(encoded("\xf0\x9f\x98\x80\xe2\x82\xac\xc3\xa9") == '"\xf0\x9f\x98\x80\xe2\x82\xac\xc3\xa9"',
    "UTF-8 passes through unescaped")
end

local function test_encode_escapes()
  assert(encoded('q" b\\ \b\f\n\r\t \1\31 /') == '"q\\" b\\\\ \\b\\f\\n\\r\\t \\u0001\\u001f /"',
    "quotes, backslashes and control characters are escaped")
end

local function test_integers_stay_exact()
  local n = 9007199254740993
  assert(encoded(n) == "9007199254740993", "2^53 + 1 encodes exactly")
  local back = decoded("9007199254740993")
  assert(back == n and math.type(back as number) == "integer", "and decodes as that integer")
  assert(encoded(math.maxinteger) == "9223372036854775807", "the largest integer")
  assert(encoded(math.mininteger) == "-9223372036854775808", "the smallest integer")
  assert(decoded("-9223372036854775808") == math.mininteger, "the smallest integer decodes")
  local past = decoded("9223372036854775808")
  assert(math.type(past as number) == "float" and past == 2.0 ^ 63,
    "an integer past 64 bits decodes as the nearest float")
  assert(math.type(decoded("-9223372036854775809") as number) == "float", "and below")
  assert(math.type(decoded("123456789012345678901234567890") as number) == "float", "far past")
end

local function test_floats_stay_floats()
  assert(math.type(decoded("1.0") as number) == "float", "1.0 is a float")
  assert(math.type(decoded("1e2") as number) == "float", "1e2 is a float")
  assert(encoded(1.0) == "1.0", "an integral float keeps its point")
  assert(encoded(-0.0) == "-0.0", "negative zero")
  for _, f in ipairs({ 0.1, 3.141592653589793, 1e300, -2.5e-10, 5e-324, 2.0 ^ 63 }) do
    local back = decoded(encoded(f))
    assert(back == f and math.type(back as number) == "float",
      "a float round-trips exactly: " .. tostring(f))
  end
  assert(encoded(0.1) == "0.1", "the shortest text that reads back")
  assert(decode_failure("1e400"):match("infinity"), "a number past a double's range")
end

local function test_nan_and_infinity()
  assert(encode_failure(0 / 0) == "json: cannot encode NaN", "NaN")
  assert(encode_failure(math.huge) == "json: cannot encode an infinite number", "infinity")
  encode_failure({ x = -math.huge })
end

local function test_null_policy()
  local obj = decoded('{"a": null, "b": 1}') as {string: any}
  assert(obj.a == nil and obj.b == 1, "a null member is absent")
  assert(encoded(obj) == '{"b":1}', "and stays absent")
  local list = decoded("[1, null, 3]") as {any}
  assert(list[1] == 1 and list[2] == nil and list[3] == 3, "a null element is a hole")
  assert(encode_failure(list) == "json: cannot encode an array with a hole (index 2 is nil)",
    "a hole is an error, not a truncation")
  local kept = decoded('{"a": null, "b": [null]}', { null_value = Json.null }) as {string: any}
  assert(kept.a == Json.null and (kept.b as {any})[1] == Json.null, "the stand-in keeps them")
  assert(encoded(kept) == '{"a":null,"b":[null]}', "and the round trip is whole")
  assert(decoded("null", { null_value = Json.null }) == Json.null, "a null document")
  assert(encoded(nil) == "null" and encoded(Json.null) == "null", "nil and the stand-in")
  assert(tostring(Json.null) == "null", "the stand-in prints as null")
  assert(not pcall(function(): any return (Json.null as {string: any}).x end),
    "indexing the stand-in raises")
end

--- A key twice in one object is refused, at the second, by line,
--- column and path; `duplicate_keys` reads it, the last member standing.
local function test_duplicate_keys_are_refused()
  assert(decode_failure('{"a": 1, "a": 2}') == "json: duplicate key at line 1, column 10 (pointer \"/a\")",
    "the second is named")
  assert(decode_failure('{"a": 1, "a": null}') == "json: duplicate key at line 1, column 10 (pointer \"/a\")",
    "a null member is a member")
  assert(decode_failure('{"a": null, "a": 1}') == "json: duplicate key at line 1, column 13 (pointer \"/a\")",
    "and so is a null one before")
  assert(decode_failure('{"a": 1, "\\u0061": 2}') == "json: duplicate key at line 1, column 10 (pointer \"/a\")",
    "a key compares as it reads, not as it is escaped")
  local nested = '{"users": [\n  {"id": 1},\n  {"id": 2, "role": "a",\n   "role": "b"}]}'
  assert(decode_failure(nested) == "json: duplicate key at line 4, column 4 (pointer \"/users/1/role\")",
    "the path names where it is")
  assert(decode_failure('{"a": {"x": 1, "x": 2}, "a": 3}') == "json: duplicate key at line 1, column 16 (pointer \"/a/x\")",
    "the first in the text is named, inner before outer")
  assert(decode_failure('{"a b": 1, "a b": 2}') == 'json: duplicate key at line 1, column 12 (pointer "/a b")',
    "a key that is no word is quoted")
  assert(decode_failure("{a: 1, 'b': 2, a: 3}", { json5 = true }) ==
      "json: duplicate key at line 1, column 16 (pointer \"/a\")", "an unquoted key")
  assert(decode_failure("{a: 1, 'a': 3}", { json5 = true }) ==
      "json: duplicate key at line 1, column 8 (pointer \"/a\")", "a single-quoted key")
  local many: {string} = {}
  for i = 1, 40 do many[#many + 1] = ('"k%d": %d'):format(i, i) end
  many[#many + 1] = '"k7": 0'
  many[#many + 1] = '"k3": 0'
  local wide = "{" .. table.concat(many, ", ") .. "}"
  local _, at = wide:find('"k7": 0', 1, true)
  assert(decode_failure(wide) == ("json: duplicate key at line 1, column %d (pointer \"/k7\")"):format(at - 6),
    "an object too large to compare pair by pair names the first repeat in the text")
  for _, size in ipairs({ 8, 9, 64, 65 }) do
    local members: {string} = {}
    for i = 1, size - 1 do members[#members + 1] = ('"k%d": {"x": %d}'):format(i, i) end
    members[2] = '"k2": {"x": 1, "x": 2}'
    members[#members + 1] = '"k1": 0'
    assert(decode_failure("{" .. table.concat(members, ", ") .. "}") ==
        "json: duplicate key at line 1, column 33 (pointer \"/k2/x\")",
      size .. " members, compared in pairs, in a set or in the table: a repeat inside an earlier member comes first")
    -- Scalars but for one value nested too deep, after a null and
    -- before the repeated key: the nesting is named, and nothing held
    -- for the null is left behind.
    local flat: {string} = {}
    for i = 1, size - 2 do
      flat[#flat + 1] = ('"k%d": %s'):format(i, i == 3 and "null" or tostring(i))
    end
    flat[#flat + 1] = '"deep": [[1]]'
    flat[#flat + 1] = '"k1": 0'
    assert(decode_failure("{" .. table.concat(flat, ", ") .. "}", { max_depth = 2 }) ==
        ("json: JSON nests deeper than 2 levels at line 1, column %d (pointer \"/deep/0\")"):format(
          #("{" .. table.concat(flat, ", ", 1, size - 2) .. ', "deep": [') + 1),
      size .. " members: nesting too deep before the repeat is named first")
  end
  -- An object looked up as it is built holds a null member's key until
  -- it is whole, so a key twice after a null is found, and the null's
  -- key is absent after.
  local large: {string} = {}
  for i = 1, 70 do large[#large + 1] = ('"k%d": %d'):format(i, i) end
  large[5] = '"k5": null'
  local whole = decoded("{" .. table.concat(large, ", ") .. "}") as {string: any}
  assert(whole.k5 == nil and whole.k6 == 6, "a null member is absent")
  large[#large + 1] = '"k5": 0'
  assert(decode_failure("{" .. table.concat(large, ", ") .. "}"):match('^json: duplicate key .* %(pointer "/k5"%)$'),
    "a key twice after a null member")
  -- Large objects holding nulls inside large objects, decoded whole.
  local inner = "{" .. table.concat(large, ", ", 1, 70) .. "}"
  local outer: {string} = {}
  for i = 1, 70 do outer[#outer + 1] = ('"o%d": %s'):format(i, i % 2 == 0 and "null" or inner) end
  local within = decoded("{" .. table.concat(outer, ", ") .. "}") as {string: {string: any}}
  assert(within.o2 == nil and within.o1.k5 == nil and within.o1.k6 == 6, "every held null let go")
  for _, v in pairs(within.o1) do assert(type(v) == "number", "only the values the text holds") end
  local _, lines = Json.decode_lines('1\n{"a": 1, "a": 2}')
  assert(lines == "json: duplicate key at line 2, column 10 (pointer \"/a\")", lines)
  assert(decode_failure('{"a": [[{"x": 1, "x": 1}]]}', { max_depth = 2 }):match("^json: JSON nests deeper"),
    "nothing past max_depth is searched")
  assert(decode_failure('{"a": [[[1]]], "b": 1, "b": 2}', { max_depth = 2 }) ==
      "json: JSON nests deeper than 2 levels at line 1, column 8 (pointer \"/a/0\")",
    "a depth failure earlier in the text comes first")
  assert(decode_failure('{"b": 1, "b": 2, "a": [[[1]]]}', { max_depth = 2 }) ==
      "json: duplicate key at line 1, column 10 (pointer \"/b\")", "and a key twice before it does")
  local allowed = { duplicate_keys = true }
  assert((decoded('{"a": 1, "a": 2}', allowed) as {string: any}).a == 2, "the last value of a key stands")
  assert((decoded('{"a": 1, "a": null}', allowed) as {string: any}).a == nil, "even when it is null")
  assert(Json.decode_object('{"a": 1, "a": 2}', allowed) ~= nil, "decode_object takes it")
end

--- Keys that differ only in their lone surrogates read as the same key,
--- which is a key twice.
local function test_repaired_surrogates_can_repeat_a_key()
  local text = '{"\\ud800": 1, "\\udc00": 2}'
  assert(decode_failure(text, { lone_surrogates = true }) ==
      "json: duplicate key at line 1, column 15 (pointer \"/\u{fffd}\")", decode_failure(text, { lone_surrogates = true }))
  local v = decoded(text, { lone_surrogates = true, duplicate_keys = true }) as {string: any}
  assert(v["\u{fffd}"] == 2, "the last stands")
end

local function test_empty_containers_round_trip()
  assert(encoded(decoded("[]")) == "[]", "[] stays an array")
  assert(encoded(decoded("{}")) == "{}", "{} stays an object")
  assert(encoded({}) == "{}", "an unmarked empty table is an object")
  assert(encoded(Json.array()) == "[]", "a marked one is an array")
  local t: {any} = {}
  assert(Json.array(t) == t and Json.is_array(t), "array marks the table it is given")
  assert(Json.array(t) == t, "marking twice is harmless")
  assert(encoded({ Json.array(), {} }) == "[[],{}]", "nested")
  assert(not Json.is_array({}) and not Json.is_array("x") and not Json.is_array(nil),
    "is_array is false for everything unmarked")
  local owned = setmetatable({} as {any}, {})
  assert(not pcall(Json.array, owned), "a table with a metatable of its own is refused")
end

local function test_tables_are_classified_by_their_keys()
  assert(encoded({ 1, 2, 3 }) == "[1,2,3]", "keys 1..n are an array")
  assert(encoded({ b = 1, a = 2 }) == '{"a":2,"b":1}', "string keys are an object")
  assert(encode_failure({ 1, a = 2 }) == "json: cannot encode a table with both string and integer keys",
    "mixed")
  assert(encode_failure({ [true] = 1 } as {any: any}) == "json: cannot encode a table with a boolean key",
    "boolean key")
  assert(encode_failure({ [1.5] = 1 } as {any: any}) == "json: cannot encode a table with a fractional number key",
    "float key")
  assert(encode_failure({ [0] = 1 } as {any: any}) == "json: cannot encode a table with an integer key below 1",
    "zero key")
  assert(encode_failure({ [{}] = 1 } as {any: any}) == "json: cannot encode a table with a table key",
    "table key")
  local marked = Json.array({ 1 }) as {any: any}
  marked.x = 1
  assert(encode_failure(marked) == "json: cannot encode an array with a string key", "marked with a string key")
  local plain = setmetatable({ x = 1 } as {string: any}, { __index = function(): any return 2 end })
  assert(encoded(plain) == '{"x":1}', "another metatable encodes the raw contents")
end

local function test_values_json_cannot_say()
  assert(encode_failure(print) == "json: cannot encode a function", "function")
  assert(encode_failure(coroutine.create(print)) == "json: cannot encode a thread", "thread")
  local hasher = assert(Hash.hasher("sha256"))
  assert(encode_failure(hasher) == "json: cannot encode a userdata", "userdata")
  assert(encode_failure({ f = print }) == "json: cannot encode a function at pointer \"/f\"", "nested")
end

local function test_depth_limits()
  local ok = decoded(string.rep("[", 64) .. "1" .. string.rep("]", 64))
  assert(ok ~= nil, "64 levels decode by default")
  local deep = string.rep("[", 65) .. "1" .. string.rep("]", 65)
  assert(decode_failure(deep) == "json: JSON nests deeper than 64 levels at line 1, column 65 (pointer \"" .. string.rep("/0", 64) .. "\")", "65 do not")
  assert(decode_failure(string.rep("[", 150) .. string.rep("]", 150), { max_depth = 149 }) ==
      "json: JSON nests deeper than 149 levels at line 1, column 150 (pointer ending \"" .. string.rep("/0", 99) .. "\")",
    "a pointer too long to tell keeps its innermost segments")
  assert(decode_failure('{"a":{"b":1}}', { max_depth = 1 }) == "json: JSON nests deeper than 1 level at line 1, column 6 (pointer \"/a\")",
    "an object counts")
  assert(decoded(deep, { max_depth = 65 }) ~= nil, "the limit is the caller's")
  local root: {any} = {}
  local t = root
  for _ = 2, 64 do
    local inner: {any} = {}
    t[1] = inner
    t = inner
  end
  assert(encoded(root) ~= "", "64 levels encode by default")
  t[1] = {}
  assert(encode_failure(root):match("^json: cannot encode a value nested deeper than 64 levels"), "65 do not")
  local cycle: {any} = {}
  cycle[1] = cycle
  assert(encode_failure(cycle, { max_depth = 5 }):match("contain itself"), "a cycle fails")
  assert(not pcall(Json.decode, "1", { max_depth = 0 }), "a limit below 1 raises")
  assert(Json.default_depth == 64 and Json.depth_limit == 1000, "the core's limits")
  assert(Json.encode(1, { max_depth = Json.depth_limit }) == "1", "the limit itself is allowed")
  assert(not pcall(Json.encode, 1, { max_depth = Json.depth_limit + 1 }),
    "a limit past the most raises")
  local fractional: any = { max_depth = 1.5 }
  assert(not pcall(Json.encode, 1, fractional as Json.EncodeOptions), "a fractional limit raises")
end

local function test_pretty()
  assert(encoded({ b = { 1, 2 }, a = {}, c = Json.array() }, { pretty = true }) ==
      '{\n  "a": {},\n  "b": [\n    1,\n    2\n  ],\n  "c": []\n}', "two spaces by default")
  assert(encoded({ a = { 1 } }) == '{"a":[1]}', "compact without pretty")
end

local function test_ascii_escapes_every_character_past_ascii()
  local ascii = { ascii = true }
  assert(encoded("caf\xc3\xa9", ascii) == '"caf\\u00e9"', "two bytes")
  assert(encoded("\xe2\x82\xac", ascii) == '"\\u20ac"', "three bytes")
  assert(encoded("\xf0\x9f\x98\x80", ascii) == '"\\ud83d\\ude00"', "a surrogate pair above U+FFFF")
  assert(encoded("\xf4\x8f\xbf\xbf", ascii) == '"\\udbff\\udfff"', "the last code point")
  assert(encoded("\xef\xbf\xbf", ascii) == '"\\uffff"', "the last of the plane")
  assert(encoded("\xc2\x80", ascii) == '"\\u0080"', "the first past ASCII")
  assert(encoded("a\"\\\n\127\xc3\xa9z", ascii) == '"a\\"\\\\\\n\127\\u00e9z"',
    "ASCII escapes and DEL are as without the option")
  assert(encoded({ ["\xc3\xa9"] = { "\xe2\x82\xac" } }, ascii) == '{"\\u00e9":["\\u20ac"]}', "keys too")
  assert(encoded({ a = "\xc3\xa9" }, { ascii = true, pretty = true }) == '{\n  "a": "\\u00e9"\n}',
    "with pretty")
  assert(encoded("\xc3\xa9", { ascii = false }) == '"\xc3\xa9"', "false leaves the text alone")
  assert(encoded("\xc3\xa9") == '"\xc3\xa9"', "off by default")
  assert(encoded("plain", ascii) == '"plain"')
end

local function test_ascii_round_trips_through_decode()
  local value = { name = "Zo\xc3\xab \xe2\x82\xac \xf0\x9f\x98\x80", ["k\xc3\xa9y"] = { "\xc2\x80", "\xef\xbf\xbf" } }
  local text = encoded(value, { ascii = true })
  assert(not text:find("[\128-\255]"), "no byte past 0x7f: " .. text)
  local back = decoded(text) as {string: any}
  assert(back.name == value.name and back["k\xc3\xa9y"] ~= nil, "decodes to the value written")
  assert(encoded(decoded(text)) == encoded(value), "and to the same plain text")
end

local function test_ascii_still_refuses_what_is_not_utf8()
  local ascii = { ascii = true }
  assert(encode_failure("\xff", ascii) == "json: cannot encode a string that is not UTF-8", "a stray byte")
  encode_failure("\xc3", ascii)
  encode_failure("\xed\xa0\x80", ascii)
  encode_failure({ x = { ["\xff"] = 1 } }, ascii)
  assert(encode_failure("a\xc3\xa9\xff", ascii) == encode_failure("a\xc3\xa9\xff"), "the same message")
end

local function test_sorted_is_byte_order()
  assert(encoded({ ["b"] = 1, ["a"] = 2, ["ab"] = 3, ["B"] = 4, ["\xc3\xa9"] = 5 }) ==
      '{"B":4,"a":2,"ab":3,"b":1,"\xc3\xa9":5}', "keys in byte order")
end

local function test_a_large_document_round_trips()
  local list: {any} = {}
  for i = 1, 5000 do list[i] = 0 end
  local text = encoded(list)
  local back = decoded(text) as {integer}
  assert(#back == 5000 and back[5000] == 0, "every element")
  local big: {string: any} = {}
  for i = 1, 2000 do big["key" .. i] = Json.array({ i, tostring(i), i + 0.5 }) end
  assert(same(decoded(encoded(big)), big), "a wide object round-trips whole")
end

--- A small seeded generator, so the random cases below are the same on
--- every run and a verdict can stand.
local function generator(seed: integer): function(integer, integer): integer
  local state = seed
  return function(lo: integer, hi: integer): integer
    state = (state * 6364136223846793005 + 1442695040888963407)
    return lo + ((state >> 33) % (hi - lo + 1))
  end
end

local alphabet = { "a", "Z", "0", " ", '"', "\\", "/", "\n", "\t", "\0", "\31", "\127",
  "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "{", "]", ":", "," }

local function random_string(pick: function(integer, integer): integer): string
  local parts: {string} = {}
  for i = 1, pick(0, 8) do parts[i] = alphabet[pick(1, #alphabet)] end
  return table.concat(parts)
end

local function random_value(pick: function(integer, integer): integer, depth: integer): any
  local kind = pick(1, depth > 3 and 5 or 7)
  if kind == 1 then return pick(0, 1) == 1 end
  if kind == 2 then return pick(-1000000, 1000000) * pick(1, 1 << 40) end
  if kind == 3 then return pick(-1000000, 1000000) / pick(1, 1000) + 0.5 end
  if kind == 4 then return random_string(pick) end
  if kind == 5 then return Json.null end
  if kind == 6 then
    local list = Json.array()
    for i = 1, pick(0, 4) do list[i] = random_value(pick, depth + 1) end
    return list
  end
  local obj: {string: any} = {}
  for _ = 1, pick(0, 4) do
    obj[random_string(pick)] = random_value(pick, depth + 1)
  end
  return obj
end

local function test_random_values_round_trip()
  local pick = generator(20260923)
  local keep = { null_value = Json.null }
  for _ = 1, 500 do
    local value = random_value(pick, 0)
    local text = encoded(value)
    assert(same(decoded(text, keep), value), "round trip of " .. text)
    local pretty = encoded(value, { pretty = true })
    assert(same(decoded(pretty, keep), value), "pretty round trip of " .. pretty)
    local ascii = encoded(value, { ascii = true })
    assert(not ascii:find("[\128-\255]"), "ascii text is ASCII: " .. ascii)
    assert(same(decoded(ascii, keep), value), "ascii round trip of " .. ascii)
  end
end

local function test_any_bytes_are_answered()
  local pick = generator(7)
  local seeds = { '{"a":[1,2.5,"x",true,null]}', '"\\u00e9\\ud83d\\ude00"', "[[[]]]", "-0.5e-3" }
  for i = 1, 2000 do
    local text: string
    if i % 2 == 0 then
      local base = seeds[pick(1, #seeds)]
      local at = pick(1, #base)
      text = base:sub(1, at - 1) .. string.char(pick(0, 255)) .. base:sub(at + 1)
    else
      local bytes: {string} = {}
      for j = 1, pick(0, 12) do bytes[j] = string.char(pick(0, 255)) end
      text = table.concat(bytes)
    end
    local value, err = Json.decode(text)
    assert(err ~= nil, "decode answers every input")
    if err == "" and value ~= nil then
      -- Re-decoded with Json.null so no hole is left: encode refuses holes, which the fuzz property writes as nulls through the raw table.
      local whole = Json.decode(text, { null_value = Json.null })
      assert(Json.encode(whole) ~= nil, "what decodes encodes: " .. string.format("%q", text))
    else
      assert(value == nil, "a failure carries no value")
    end
  end
end

local function test_an_encode_failure_says_where()
  local users = { { name = "ada" }, { name = "bob" }, { name = print } }
  assert(encode_failure({ users = users }) == "json: cannot encode a function at pointer \"/users/2/name\"",
    "a path through objects and arrays")
  assert(encode_failure({ ["a key"] = { 1, 0 / 0 } }) == 'json: cannot encode NaN at pointer "/a key/1"',
    "a key that is not a word is quoted")
  assert(encode_failure({ ['q"\1'] = print }) == 'json: cannot encode a function at pointer "/q\\"\\u0001"',
    "its quotes escaped and its unprintable bytes shown as ?")
  assert(encode_failure({ x = { 1, nil, 3 } as {any} }) ==
      "json: cannot encode an array with a hole (index 2 is nil) at pointer \"/x\"", "a table's own failure names the table")
  assert(encode_failure({ x = { ["\xff"] = 1 } }) == "json: cannot encode a key that is not UTF-8 at pointer \"/x\"",
    "a bad key is the object's")
  assert(encode_failure(print) == "json: cannot encode a function", "nothing to say at the top")
  local long = string.rep("k", 60)
  local deep: {string: any} = { [long] = print }
  for _ = 1, 8 do deep = { [long] = deep } end
  local where = encode_failure(deep)
  assert(where == 'json: cannot encode a function at pointer ending "' .. string.rep("/" .. long, 3) .. '"',
    "a pointer too long keeps its innermost segments, whole: " .. where)
end

local function test_big_numbers_as_strings()
  local keep = { big_numbers_as_strings = true }
  local v = decoded('{"id": 18446744073709551615, "big": 123456789012345678901234567890,' ..
      ' "fits": 9223372036854775807, "neg": -9223372036854775809, "huge": 1e400, "f": 0.5}', keep)
    as {string: any}
  assert(v.id == "18446744073709551615", "past a Lua integer, below 2^64")
  assert(v.big == "123456789012345678901234567890", "past 64 bits")
  assert(v.neg == "-9223372036854775809", "below the smallest integer")
  assert(v.huge == "1e400", "past a double")
  assert(v.fits == math.maxinteger and math.type(v.fits as number) == "integer", "what fits is a number")
  assert(v.f == 0.5, "and so is an ordinary float")
  assert(math.type(decoded("18446744073709551615") as number) == "float", "the default is unchanged")
  assert(encoded(v.id) == '"18446744073709551615"', "it encodes back as a string")
end

local function test_json_lines()
  local values, err = Json.decode_lines('{"a": 1}\n[2]\r\n\n  \n"three"\nnull\n4')
  assert(values ~= nil, err)
  assert((values[1] as {string: any}).a == 1 and (values[2] as {integer})[1] == 2, "values in order")
  assert(values[3] == "three" and values[4] == nil and values[5] == 4, "blank lines skipped, null a hole")
  assert(Json.is_array(values), "a marked array")
  local empty = Json.decode_lines("")
  assert(empty ~= nil and #empty == 0, "no lines")
  local _, bad = Json.decode_lines('1\n\n{"a": tru}\n')
  assert(bad == "json: invalid JSON at line 3, column 7: invalid literal, expected 'true'", bad)
  local _, deep = Json.decode_lines('1\n[[1]]', { max_depth = 1 })
  assert(deep == "json: JSON nests deeper than 1 level at line 2, column 2 (pointer \"/0\")", deep)
  -- Records split on \n alone: a lone \r, or in JSON5 a U+2028, is
  -- no record boundary, before a failing record or inside it, and a
  -- failure's column counts from its record's start.
  local _, past_cr = Json.decode_lines('[1,\r2]\n{"a": tru}')
  assert(past_cr == "json: invalid JSON at line 2, column 7: invalid literal, expected 'true'", past_cr)
  local _, past_ls = Json.decode_lines('[1,\u{2028}2]\n[[1]]', { json5 = true, max_depth = 1 })
  assert(past_ls == "json: JSON nests deeper than 1 level at line 2, column 2 (pointer \"/0\")", past_ls)
  local _, inside_cr = Json.decode_lines('1\n[1,\r x]')
  assert(inside_cr:match("^json: invalid JSON at line 2, column 6: "), inside_cr)
  local _, inside_ls = Json.decode_lines('1\n[1,\u{2028} x]', { json5 = true })
  assert(inside_ls:match("^json: invalid JSON at line 2, column 8: "), inside_ls)
  -- A JSON5 record holding only a comment holds no value.
  local _, comment = Json.decode_lines('1\n// c', { json5 = true })
  assert(comment == "json: invalid JSON at line 2: the line holds no value", comment)
  local kept = Json.decode_lines("null\n1", { null_value = Json.null })
  assert(kept ~= nil and kept[1] == Json.null, "options apply to each line")
end

--- `hash_comments` reads a `#` line comment, in RFC 8259 JSON and in
--- JSON5 alike, and only where it is asked for; a `#` inside a string
--- stays a character.
local function test_hash_comments_are_read_when_asked()
  local hash = { hash_comments = true }
  local list = decoded('# lead\n[1, # one\n2] # end', hash) as {integer}
  assert(#list == 2 and list[1] == 1 and list[2] == 2, "comments before, inside and after")
  local strings = decoded('["#x", "# y"]', hash) as {string}
  assert(strings[1] == "#x" and strings[2] == "# y", "a # in a string")
  assert(decoded("1 # no newline", hash) == 1, "a comment the text ends in")
  local five = { json5 = true, hash_comments = true }
  local text = [[
# the name GitHub shows
{
  name: "ci", # after a member
  // JSON5's own comments still read
  "runs-on": ["ubuntu-24.04",],
}
]]
  local v = decoded(text, five) as {string: any}
  assert(v.name == "ci" and (v["runs-on"] as {string})[1] == "ubuntu-24.04", "JSON5 with # comments")
  assert(Json.decode_object(text, five) ~= nil, "decode_object takes hash_comments")
  assert(decode_failure("# c\n1"):match("^json: invalid JSON at line 1, column 1"), "RFC 8259 has no # comment")
  assert(decode_failure("# c\n1", { json5 = true }):match("^json: invalid JSON at line 1, column 1"),
    "nor does JSON5")
  assert(decode_failure("# only", hash) == "json: invalid JSON: the text is empty", "a comment is no value")
  -- A # comment ends where a // one does: at U+2028 in JSON5, and
  -- only at \n or \r outside it.
  assert(decoded("# c\u{2028}1", five) == 1, "JSON5 ends it at U+2028")
  assert(decode_failure("# c\u{2028}1", hash) == "json: invalid JSON: the text is empty",
    "outside JSON5, U+2028 is inside it")
  local values = assert(Json.decode_lines("1 # one\n3", hash))
  assert(#values == 2 and values[2] == 3, "decode_lines takes hash_comments")
  local _, only = Json.decode_lines("1\n# two", hash)
  assert(only == "json: invalid JSON at line 2: the line holds no value", only)
end

--- A depth failure says where the refused array or object opens,
--- counting past strings that hold brackets, and, in JSON5, past
--- comments and single-quoted strings.
local function test_a_depth_failure_says_where()
  local text = '{"s": "[[{", "a": [\n  [1, {"x": [2]}]]}'
  assert(decode_failure(text, { max_depth = 3 }) ==
      "json: JSON nests deeper than 3 levels at line 2, column 7 (pointer \"/a/0/1\")", decode_failure(text, { max_depth = 3 }))
  local five = "// [[[\n{'s': '[{', /* { */ a: [[0]]}"
  assert(decode_failure(five, { json5 = true, max_depth = 2 }) ==
      "json: JSON nests deeper than 2 levels at line 2, column 25 (pointer \"/a/0\")", decode_failure(five, { json5 = true, max_depth = 2 }))
  -- JSON5 ends a line comment at \r, U+2028 and U+2029 as well as \n,
  -- and the line it names counts each as a line end.
  for _, eol in ipairs({ "\r", "\r\n", "\u{2028}", "\u{2029}" }) do
    local failure = decode_failure("// c" .. eol .. "[[1]]", { json5 = true, max_depth = 1 })
    assert(failure == "json: JSON nests deeper than 1 level at line 2, column 2 (pointer \"/0\")", failure)
    local hashed = decode_failure("# c" .. eol .. "[[1]]", { json5 = true, hash_comments = true, max_depth = 1 })
    assert(hashed == "json: JSON nests deeper than 1 level at line 2, column 2 (pointer \"/0\")", hashed)
  end
  -- Outside JSON5, a # comment runs past U+2028 to the \n, and the
  -- brackets it holds are no part of the count.
  local past = decode_failure("# [ \u{2028} [\n[[1]]", { hash_comments = true, max_depth = 1 })
  assert(past == "json: JSON nests deeper than 1 level at line 2, column 2 (pointer \"/0\")", past)
end

--- A syntax error's line counts every line end the text's grammar
--- has: \n, a lone \r, and \r\n as one; in JSON5, U+2028 and U+2029
--- too. RFC 8259 has those two only inside a string, where they are
--- characters, and the column counts their bytes.
local function test_a_failure_counts_each_line_end()
  for _, eol in ipairs({ "\n", "\r", "\r\n" }) do
    for _, five in ipairs({ false, true }) do
      local err = decode_failure("[1," .. eol .. eol .. "  x]", { json5 = five })
      assert(err:match("^json: invalid JSON at line 3, column 3: "), err)
    end
  end
  for _, eol in ipairs({ "\u{2028}", "\u{2029}" }) do
    local err = decode_failure("[1," .. eol .. "  x]", { json5 = true })
    assert(err:match("^json: invalid JSON at line 2, column 3: "), err)
    local strict = decode_failure('["' .. eol .. '", x]')
    assert(strict:match("^json: invalid JSON at line 1, column 9: "), strict)
    -- JSON5 takes one raw inside a quoted string, and it ends the
    -- line there too, as an editor shows it.
    local quoted = decode_failure("['a" .. eol .. "b', x]", { json5 = true })
    assert(quoted:match("^json: invalid JSON at line 2, column 5: "), quoted)
  end
end

--- `lone_surrogates` reads a lone surrogate escape as U+FFFD -- a high
--- half with no low half after it, a high half before another escape,
--- or a low half alone, in keys as in values -- and leaves a pair, and
--- an escaped backslash before `u`, as they are. Without it, one is
--- refused.
local function test_lone_surrogates_read_as_the_replacement_character()
  local opts: Json.DecodeOptions = { lone_surrogates = true }
  local text = '{"\\ud83d": ["a\\ud83d", "\\ude00", "\\ud83d\\u0041", "\\ud83d\\ude00", "\\\\ud83d"]}'
  local value = assert(Json.decode(text, opts)) as {string: {string}}
  local list = value["\u{FFFD}"]
  assert(list ~= nil, "the key's lone surrogate")
  assert(list[1] == "a\u{FFFD}" and list[2] == "\u{FFFD}" and list[3] == "\u{FFFD}A",
    table.concat(list, "|"))
  assert(list[4] == "\u{1F600}" and list[5] == "\\ud83d", table.concat(list, "|"))
  local refused = decode_failure('["a\\ud83d"]')
  assert(refused:find("surrogate", 1, true), refused)
  local still = decode_failure('["a\\ud83d", tru]', opts)
  assert(still:find("invalid literal", 1, true), still)
end

local function test_quote_spells_a_key_for_a_message()
  assert(Json.quote('a"b\\c\n') == '"a\\"b\\\\c\\u000a"')
  assert(Json.quote("\xff") == '"\xff"', "bytes that are not UTF-8 pass through")
end

--- `layout` is the one classification of a table: what `encode` and the
--- walks over a decoded value each decide by.
local function test_layout_classifies_a_table_as_encode_does()
  assert(Json.layout({}) == "object", "an unmarked empty table is an object")
  assert(Json.layout(Json.array()) == "array", "a marked one is an array")
  assert(Json.layout({ 1, 2, 3 }) == "array")
  assert(Json.layout({ b = 1, a = 2 }) == "object")
  assert(Json.layout({ [1] = 1, [3] = 3 }) == "hole")
  assert(Json.layout({ 1, a = 2 }) == "mixed")
  assert(Json.layout({ [0] = 1 } as {any: any}) == "mixed", "an integer key below 1")
  assert(Json.layout({ [1.5] = 1 } as {any: any}) == "mixed", "a fractional key")
  assert(Json.layout({ [true] = 1 } as {any: any}) == "mixed", "a boolean key")
end

--- `members` lists the keys a walk visits, sorted, and an array's extent
--- is its highest index even where a `null` left holes.
local function test_members_lists_what_a_walk_visits()
  local object = Json.members({ b = 1, a = 2, c = 3 })
  assert(object.layout == "object" and table.concat(object.keys as {string}, ",") == "a,b,c")
  assert(object.extent == 0)
  local hole = Json.members({ [7] = "g", [1] = "a", [3] = "c" } as {any: any})
  assert(hole.layout == "hole" and #hole.keys == 3 and hole.keys[1] == 1 and hole.keys[2] == 3 and
      hole.keys[3] == 7 and hole.extent == 0)
  local array = Json.members({ "x", "y" })
  assert(array.layout == "array" and #array.keys == 0 and array.extent == 2, "no key list for an array")
  local holed = Json.members(decoded("[1, null, null, 4, null]") as {any: any})
  assert(holed.layout == "array" and holed.extent == 4, "a decoded array's extent")
  assert(#holed.keys == 0, "a marked array's keys are listed only when asked")
  local holed_keys = Json.members(decoded("[1, null, null, 4, null]") as {any: any}, true).keys
  assert(#holed_keys == 2 and holed_keys[1] == 1 and holed_keys[2] == 4, "a marked array's keys, past a gap")
  local dense = Json.members(decoded("[1, 2]") as {any: any})
  assert(#dense.keys == 0 and dense.extent == 2, "a marked array with no gap lists no keys")
  local mixed = Json.members({ 1, a = 2 })
  assert(mixed.layout == "mixed" and #mixed.keys == 0 and mixed.extent == 0)
  assert(Json.members(Json.array()).extent == 0)
  -- A marked array that holds a key no array has is mixed, as `encode`
  -- refuses it, and only a request for gaps lists a gap's keys.
  for _, stray in ipairs({ "x", 0, -1, 1.5, true } as {any}) do
    local odd: {any: any} = Json.array({ 1 }) as {any: any}
    odd[stray] = 2
    local m = Json.members(odd)
    assert(m.layout == "mixed" and #m.keys == 0 and m.extent == 0, tostring(stray))
  end
  assert(#Json.members(decoded("[1, null, 3]") as {any: any}).keys == 0, "no gap keys unless asked")
  assert(#Json.members(decoded("[1, null, 3]") as {any: any}, true).keys == 2)
  -- `rawlen` of this table is 3, and its keys are as many, but 5 lies past it.
  local bordered: {any: any} = { 1, 2, 3 }
  bordered[2] = nil
  bordered[5] = 5
  assert(Json.layout(bordered) == "hole", "a border is not the extent")
  local far = Json.members(Json.array({ [1 << 40] = 7 } as {any}) as {any: any}, true)
  assert(far.layout == "array" and far.extent == 1 << 40 and #far.keys == 1)
end

--- `check` answers what `decode` would, building nothing.
local function test_check_answers_as_decode_would()
  assert(Json.check('{"a": [1, 2]}') == true)
  local ok, err = Json.check('{"a": 1, "a": 2}')
  assert(not ok and err == "json: duplicate key at line 1, column 10 (pointer \"/a\")", err)
  assert(Json.check('{"a": 1, "a": 2}', { duplicate_keys = true }))
  local _, deep = Json.check("[[1]]", { max_depth = 1 })
  assert(deep == "json: JSON nests deeper than 1 level at line 1, column 2 (pointer \"/0\")", deep)
  local _, big = Json.check("1e400")
  assert(big:match("infinity"), big)
  assert(Json.check("1e400", { big_numbers_as_strings = true }), "the options are decode's")
  assert(Json.check("{a: 1}", { json5 = true }) and not Json.check("{a: 1}"))
  local _, bad = Json.check("[1,]")
  assert(bad == select(2, Json.decode("[1,]")), "the message is decode's")
end

--- `format` writes the text again, keeping its order and its numbers'
--- text, and refuses what `decode` refuses.
local function test_format_keeps_order_and_numbers()
  local text = '{ "b" : 1.50, "a": [ ], "c": {"x": [123456789012345678901234567890, -0, "\\u00e9\\/"], "e": {}} }'
  assert(Json.format(text) == '{"b":1.50,"a":[],"c":{"x":[123456789012345678901234567890,-0,"\u{e9}/"],"e":{}}}',
    Json.format(text))
  assert(Json.format(text, { pretty = true }) == [[
{
  "b": 1.50,
  "a": [],
  "c": {
    "x": [
      123456789012345678901234567890,
      -0,
      "]] .. "\u{e9}" .. [[/"
    ],
    "e": {}
  }
}]], "laid out as encode lays out a value")
  assert(Json.format('"x"') == '"x"' and Json.format(" null ") == "null", "a scalar")
  assert(Json.format('{"a": 1, "a": 2}', { duplicate_keys = true }) == '{"a":1,"a":2}',
    "each member of a key twice, in its place")
  assert(select(2, Json.format('{"a": 1, "a": 2}')) == "json: duplicate key at line 1, column 10 (pointer \"/a\")")
  local _, deep = Json.format("[[1]]", { max_depth = 1 })
  assert(deep:match("^json: JSON nests deeper"), deep)
  local five = "// c\n{a: 0x1F, 'b': +1, c: .5, d: 5., e: -0x10, f: 1.50, g: -.5e3, h: +1e400, i: 5.E2, # h\n}"
  assert(Json.format(five, { json5 = true, hash_comments = true }) ==
      '{"a":31,"b":1,"c":0.5,"d":5.0,"e":-16,"f":1.50,"g":-0.5e3,"h":1e400,"i":5.0E2}', Json.format(five, { json5 = true,
        hash_comments = true }))
  for _, number in ipairs({ "1e400", "0x", "[0x]", "1E+-1", "1ee1", "[1.e]", "0x10000000000000000" }) do
    local five_too = number:match("x") ~= nil
    local _, refused = Json.format(number, { json5 = five_too })
    local _, decoded_err = Json.decode(number, { json5 = five_too })
    assert(refused ~= "" and refused == decoded_err, number .. ": " .. refused .. " vs " .. decoded_err)
  end
  assert(select(2, Json.format("{a: [1, NaN]}", { json5 = true })) == "json: cannot format NaN at pointer \"/a/1\"")
  assert(select(2, Json.format("[-Infinity]", { json5 = true })) == "json: cannot format an infinite number at pointer \"/0\"")
  assert(Json.format('["\\ud83d"]', { lone_surrogates = true }) == '["\u{fffd}"]')
end

--- RFC 8785's own example, its number samples (appendix B) and its key
--- order (section 3.2.3).
local function test_canonical_is_rfc_8785()
  local example = '{"numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001], ' ..
    '"string": "\\u20ac$\\u000F\\u000aA\'\\u0042\\u0022\\u005c\\\\\\"\\/", "literals": [null, true, false]}'
  assert(Json.canonical(example) == '{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],' ..
      '"string":"\u{20ac}$\\u000f\\nA\'B\\"\\\\\\\\\\"/"}', Json.canonical(example))
  local samples: {{string}} = {
    { "0000000000000000", "0" }, { "8000000000000000", "0" }, { "0000000000000001", "5e-324" },
    { "8000000000000001", "-5e-324" }, { "7fefffffffffffff", "1.7976931348623157e+308" },
    { "ffefffffffffffff", "-1.7976931348623157e+308" }, { "4340000000000000", "9007199254740992" },
    { "c340000000000000", "-9007199254740992" }, { "4430000000000000", "295147905179352830000" },
    { "44b52d02c7e14af5", "9.999999999999997e+22" }, { "44b52d02c7e14af6", "1e+23" },
    { "44b52d02c7e14af7", "1.0000000000000001e+23" }, { "444b1ae4d6e2ef4e", "999999999999999700000" },
    { "444b1ae4d6e2ef4f", "999999999999999900000" }, { "444b1ae4d6e2ef50", "1e+21" },
    { "3eb0c6f7a0b5ed8c", "9.999999999999997e-7" }, { "3eb0c6f7a0b5ed8d", "0.000001" },
    { "41b3de4355555553", "333333333.3333332" }, { "41b3de4355555554", "333333333.33333325" },
    { "41b3de4355555555", "333333333.3333333" }, { "41b3de4355555556", "333333333.3333334" },
    { "41b3de4355555557", "333333333.33333343" }, { "becbf647612f3696", "-0.0000033333333333333333" },
    { "43143ff3c1cb0959", "1424953923781206.2" },
  }
  for _, sample in ipairs(samples) do
    local bits = (math.tointeger(tonumber(sample[1]:sub(1, 8), 16)) as integer) << 32 |
      math.tointeger(tonumber(sample[1]:sub(9), 16)) as integer
    local f = string.unpack("<d", string.pack("<i8", bits)) as number
    local got = Json.canonical(("%.17g"):format(f))
    assert(got == sample[2], sample[1] .. ": " .. tostring(got))
  end
  local keys = '{"\\u20ac": 1, "\\r": 2, "\\ufb33": 3, "1": 4, "\\ud83d\\ude00": 5, "\\u0080": 6, "\\u00f6": 7}'
  assert(Json.canonical(keys) ==
      '{"\\r":2,"1":4,"\u{80}":6,"\u{f6}":7,"\u{20ac}":1,"\u{1f600}":5,"\u{fb33}":3}',
    "by UTF-16 code units: a pair sorts before U+FB33")
  assert(Json.canonical("[1, 1.0, 1e0, 10E-1, 9007199254740993]") == "[1,1,1,1,9007199254740992]",
    "every number is the double it reads as")
  assert(Json.canonical('{"b": {"d": 1, "c": 2}, "a": []}') == '{"a":[],"b":{"c":2,"d":1}}', "nested objects sort")
  assert(select(2, Json.canonical('{"a": 1, "a": 2}')) == "json: duplicate key at line 1, column 10 (pointer \"/a\")",
    "a key twice has no canonical form")
  local _, big = Json.canonical("1e400")
  assert(big:match("infinity"), "nor a number past a double's range")
  assert(Json.canonical("{a: 0x10, b: [.5]}", { json5 = true }) == '{"a":16,"b":[0.5]}')
  assert(select(2, Json.canonical("NaN", { json5 = true })) == "json: cannot format NaN")
end
