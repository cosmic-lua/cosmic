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
    assert(none == nil and why == "expected a JSON object, got " .. kind, why)
  end
  for text, kind in pairs({ ['{"a": 1}'] = "object", ["{}"] = "object", ["1.5"] = "number",
      ["null"] = "null" }) do
    local none, why = Json.decode_array(text)
    assert(none == nil and why == "expected a JSON array, got " .. kind, why)
  end
  local _, sentinel_why = Json.decode_object("null", { null_value = Json.null })
  assert(sentinel_why == "expected a JSON object, got null", sentinel_why)
  local _, invalid = Json.decode_array("[1,")
  assert(invalid:match("^invalid JSON"), "a syntax error passes through: " .. invalid)
end

local function test_a_failure_names_line_and_column()
  local err = decode_failure('{\n  "a": tru\n}')
  assert(err:match("^invalid JSON at line 2, column 8: "), err)
  assert(decode_failure("[1] x"):match("line 1, column 5: unexpected content"), "trailing text")
  assert(decode_failure("") == "invalid JSON: the text is empty", "empty text")
  assert(decode_failure(" \n ") == "invalid JSON: the text is empty", "blank text")
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
  assert(encode_failure("\xff") == "cannot encode a string that is not UTF-8", "a stray byte")
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
  assert(encode_failure(0 / 0) == "cannot encode NaN", "NaN")
  assert(encode_failure(math.huge) == "cannot encode an infinite number", "infinity")
  encode_failure({ x = -math.huge })
  assert(encoded({ 0 / 0, math.huge }, { nan_as_null = true }) == "[null,null]",
    "nan_as_null writes null")
end

local function test_null_policy()
  local obj = decoded('{"a": null, "b": 1}') as {string: any}
  assert(obj.a == nil and obj.b == 1, "a null member is absent")
  assert(encoded(obj) == '{"b":1}', "and stays absent")
  local list = decoded("[1, null, 3]") as {any}
  assert(list[1] == 1 and list[2] == nil and list[3] == 3, "a null element is a hole")
  assert(encode_failure(list) == "cannot encode an array with a hole at index 2",
    "a hole is an error, not a truncation")
  assert(encoded(list, { sparse_as_null = true }) == "[1,null,3]", "sparse_as_null writes it")
  local kept = decoded('{"a": null, "b": [null]}', { null_value = Json.null }) as {string: any}
  assert(kept.a == Json.null and (kept.b as {any})[1] == Json.null, "the stand-in keeps them")
  assert(encoded(kept) == '{"a":null,"b":[null]}', "and the round trip is whole")
  assert(decoded("null", { null_value = Json.null }) == Json.null, "a null document")
  assert(encoded(nil) == "null" and encoded(Json.null) == "null", "nil and the stand-in")
  assert(tostring(Json.null) == "null", "the stand-in prints as null")
  assert(not pcall(function(): any return (Json.null as {string: any}).x end),
    "indexing the stand-in raises")
end

local function test_duplicate_keys_last_wins()
  local v = decoded('{"a": 1, "a": 2}') as {string: any}
  assert(v.a == 2, "the last value of a key stands")
  local gone = decoded('{"a": 1, "a": null}') as {string: any}
  assert(gone.a == nil, "even when it is null")
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
  assert(encode_failure({ 1, a = 2 }) == "cannot encode a table with both string and integer keys",
    "mixed")
  assert(encode_failure({ [true] = 1 } as {any: any}) == "cannot encode a table with a boolean key",
    "boolean key")
  assert(encode_failure({ [1.5] = 1 } as {any: any}) == "cannot encode a table with a fractional number key",
    "float key")
  assert(encode_failure({ [0] = 1 } as {any: any}) == "cannot encode a table with an integer key below 1",
    "zero key")
  assert(encode_failure({ [{}] = 1 } as {any: any}) == "cannot encode a table with a table key",
    "table key")
  local marked = Json.array({ 1 }) as {any: any}
  marked.x = 1
  assert(encode_failure(marked) == "cannot encode an array with a string key", "marked with a string key")
  local plain = setmetatable({ x = 1 } as {string: any}, { __index = function(): any return 2 end })
  assert(encoded(plain) == '{"x":1}', "another metatable encodes the raw contents")
end

local function test_sparse_arrays()
  assert(encode_failure({ [100] = 1 } as {any: any}, { sparse_as_null = true }) ==
    "cannot encode an array this sparse: its highest index is 100, and only 1 of its slots hold a value",
    "too sparse to mean")
  assert(encoded({ [3] = 1 } as {any: any}, { sparse_as_null = true }) == "[null,null,1]",
    "a few holes are written")
end

local function test_values_json_cannot_say()
  assert(encode_failure(print) == "cannot encode a function", "function")
  assert(encode_failure(coroutine.create(print)) == "cannot encode a thread", "thread")
  local hasher = assert(Hash.hasher("sha256"))
  assert(encode_failure(hasher) == "cannot encode a userdata", "userdata")
  assert(encode_failure({ f = print }) == "cannot encode a function", "nested")
end

local function test_depth_limits()
  local ok = decoded(string.rep("[", 64) .. "1" .. string.rep("]", 64))
  assert(ok ~= nil, "64 levels decode by default")
  local deep = string.rep("[", 65) .. "1" .. string.rep("]", 65)
  assert(decode_failure(deep) == "JSON nests deeper than 64 levels", "65 do not")
  assert(decode_failure('{"a":{"b":1}}', { max_depth = 1 }) == "JSON nests deeper than 1 levels",
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
  assert(encode_failure(root):match("^cannot encode a value nested deeper than 64 levels"), "65 do not")
  local cycle: {any} = {}
  cycle[1] = cycle
  assert(encode_failure(cycle, { max_depth = 5 }):match("contain itself"), "a cycle fails")
  assert(not pcall(Json.decode, "1", { max_depth = 0 }), "a limit below 1 raises")
  assert(not pcall(Json.encode, 1, { max_depth = 1001 }), "a limit past 1000 raises")
  local fractional: any = { max_depth = 1.5 }
  assert(not pcall(Json.encode, 1, fractional as Json.EncodeOptions), "a fractional limit raises")
end

local function test_pretty()
  assert(encoded({ b = { 1, 2 }, a = {}, c = Json.array() }, { pretty = true }) ==
    '{\n  "a": {},\n  "b": [\n    1,\n    2\n  ],\n  "c": []\n}', "two spaces by default")
  assert(encoded({ 1 }, { pretty = true, indent = "\t" }) == "[\n\t1\n]", "a tab")
  assert(encoded({ a = { 1 } }) == '{"a":[1]}', "compact without pretty")
  local ok, why = pcall(Json.encode, 1, { pretty = true, indent = "x" })
  assert(not ok and tostring(why):match("indent must be spaces and tabs"), tostring(why))
end

local function test_unsorted_keeps_every_member()
  local t: {string: integer} = {}
  for i = 1, 50 do t["k" .. i] = i end
  local back = decoded(encoded(t, { sorted = false })) as {string: integer}
  for i = 1, 50 do
    assert(back["k" .. i] == i, "member k" .. i)
  end
  assert(encoded({}, { sorted = false }) == "{}", "empty")
  assert(encode_failure({ a = print }, { sorted = false }) == "cannot encode a function", "a failure")
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
    local pretty = encoded(value, { pretty = true, sorted = false })
    assert(same(decoded(pretty, keep), value), "pretty round trip of " .. pretty)
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
      assert(Json.encode(value, { sparse_as_null = true }) ~= nil,
        "what decodes encodes: " .. string.format("%q", text))
    else
      assert(value == nil, "a failure carries no value")
    end
  end
end
