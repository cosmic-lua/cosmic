--- Proves cosmic.json reads exactly RFC 8259 JSON, says where text
--- stopped being JSON, keeps integers and floats apart and exact, and
--- refuses to encode what JSON cannot say rather than writing something
--- else.

local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")

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
  assert(decode_failure("{a: 1,}"):match("^invalid JSON"), "the default stays strict")
  assert(decode_failure("{a: 1", five):match("^invalid JSON at line 1"), "JSON5 fails with a place too")
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
  assert(encode_failure(list) == "cannot encode an array with a hole (index 2 is nil)",
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
  assert(encode_failure({ f = print }) == "cannot encode a function at $.f", "nested")
end

local function test_depth_limits()
  local ok = decoded(string.rep("[", 64) .. "1" .. string.rep("]", 64))
  assert(ok ~= nil, "64 levels decode by default")
  local deep = string.rep("[", 65) .. "1" .. string.rep("]", 65)
  assert(decode_failure(deep) == "JSON nests deeper than 64 levels at line 1, column 65", "65 do not")
  assert(decode_failure('{"a":{"b":1}}', { max_depth = 1 }) == "JSON nests deeper than 1 levels at line 1, column 6",
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
  assert(encode_failure({ a = print }, { sorted = false }) == "cannot encode a function at $.a",
    "a failure")
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

local function test_an_encode_failure_says_where()
  local users = { { name = "ada" }, { name = "bob" }, { name = print } }
  assert(encode_failure({ users = users }) == "cannot encode a function at $.users[3].name",
    "a path through objects and arrays")
  assert(encode_failure({ ["a key"] = { 1, 0 / 0 } }) == 'cannot encode NaN at $["a key"][2]',
    "a key that is not a word is quoted")
  assert(encode_failure({ ['q"\1'] = print }) == 'cannot encode a function at $["q\\"?"]',
    "its quotes escaped and its unprintable bytes shown as ?")
  assert(encode_failure({ x = { 1, nil, 3 } as {any} }) ==
    "cannot encode an array with a hole (index 2 is nil) at $.x", "a table's own failure names the table")
  assert(encode_failure({ x = { ["\xff"] = 1 } }) == "cannot encode a key that is not UTF-8 at $.x",
    "a bad key is the object's")
  assert(encode_failure(print) == "cannot encode a function", "nothing to say at the top")
  assert(encode_failure({ a = print }, { sorted = false }) == "cannot encode a function at $.a",
    "unsorted too")
  local long = string.rep("k", 60)
  local deep: {string: any} = { [long] = print }
  for _ = 1, 8 do deep = { [long] = deep } end
  local where = encode_failure(deep)
  assert(where:match('^cannot encode a function at %$%.%.%.%["k') and where:sub(-5) == '..."]',
    "a path too long keeps its innermost segments: " .. where)
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
  assert(bad == "invalid JSON at line 3, column 7: invalid literal, expected 'true'", bad)
  local _, deep = Json.decode_lines('1\n[[1]]', { max_depth = 1 })
  assert(deep == "JSON nests deeper than 1 levels at line 2, column 2", deep)
  -- Records split on \n alone: a lone \r, or in JSON5 a U+2028, is
  -- no record boundary, before a failing record or inside it, and a
  -- failure's column counts from its record's start.
  local _, past_cr = Json.decode_lines('[1,\r2]\n{"a": tru}')
  assert(past_cr == "invalid JSON at line 2, column 7: invalid literal, expected 'true'", past_cr)
  local _, past_ls = Json.decode_lines('[1,\u{2028}2]\n[[1]]', { json5 = true, max_depth = 1 })
  assert(past_ls == "JSON nests deeper than 1 levels at line 2, column 2", past_ls)
  local _, inside_cr = Json.decode_lines('1\n[1,\r x]')
  assert(inside_cr:match("^invalid JSON at line 2, column 6: "), inside_cr)
  local _, inside_ls = Json.decode_lines('1\n[1,\u{2028} x]', { json5 = true })
  assert(inside_ls:match("^invalid JSON at line 2, column 8: "), inside_ls)
  -- A JSON5 record holding only a comment holds no value.
  local _, comment = Json.decode_lines('1\n// c', { json5 = true })
  assert(comment == "invalid JSON at line 2: the line holds no value", comment)
  local kept = Json.decode_lines("null\n1", { null_value = Json.null })
  assert(kept ~= nil and kept[1] == Json.null, "options apply to each line")
  assert(Json.encode_lines({ { b = 1, a = { 1 } }, "x", 3 }, { pretty = false }) ==
    '{"a":[1],"b":1}\n"x"\n3\n', "one compact value to a line")
  local laid_out, why_not = pcall(Json.encode_lines, { 1 }, { pretty = true })
  assert(not laid_out and tostring(why_not):find("each value keeps to its line", 1, true),
    "asking for layout raises rather than being dropped")
  assert(Json.encode_lines({}) == "", "no values, no text")
  local _, why = Json.encode_lines({ 1, { f = print } })
  assert(why == "value 2: cannot encode a function at $.f", why)
  local text = assert(Json.encode_lines({ { a = 1 }, Json.array() }))
  assert(encoded((Json.decode_lines(text))) == '[{"a":1},[]]', "a round trip")
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
  assert(decode_failure("# c\n1"):match("^invalid JSON at line 1, column 1"), "RFC 8259 has no # comment")
  assert(decode_failure("# c\n1", { json5 = true }):match("^invalid JSON at line 1, column 1"),
    "nor does JSON5")
  assert(decode_failure("# only", hash) == "invalid JSON: the text is empty", "a comment is no value")
  -- A # comment ends where a // one does: at U+2028 in JSON5, and
  -- only at \n or \r outside it.
  assert(decoded("# c\u{2028}1", five) == 1, "JSON5 ends it at U+2028")
  assert(decode_failure("# c\u{2028}1", hash) == "invalid JSON: the text is empty",
    "outside JSON5, U+2028 is inside it")
  local values = assert(Json.decode_lines("1 # one\n3", hash))
  assert(#values == 2 and values[2] == 3, "decode_lines takes hash_comments")
  local _, only = Json.decode_lines("1\n# two", hash)
  assert(only == "invalid JSON at line 2: the line holds no value", only)
end

--- A depth failure says where the refused array or object opens,
--- counting past strings that hold brackets, and, in JSON5, past
--- comments and single-quoted strings.
local function test_a_depth_failure_says_where()
  local text = '{"s": "[[{", "a": [\n  [1, {"x": [2]}]]}'
  assert(decode_failure(text, { max_depth = 3 }) ==
    "JSON nests deeper than 3 levels at line 2, column 7", decode_failure(text, { max_depth = 3 }))
  local five = "// [[[\n{'s': '[{', /* { */ a: [[0]]}"
  assert(decode_failure(five, { json5 = true, max_depth = 2 }) ==
    "JSON nests deeper than 2 levels at line 2, column 25", decode_failure(five, { json5 = true, max_depth = 2 }))
  -- JSON5 ends a line comment at \r, U+2028 and U+2029 as well as \n,
  -- and the line it names counts each as a line end.
  for _, eol in ipairs({ "\r", "\r\n", "\u{2028}", "\u{2029}" }) do
    local failure = decode_failure("// c" .. eol .. "[[1]]", { json5 = true, max_depth = 1 })
    assert(failure == "JSON nests deeper than 1 levels at line 2, column 2", failure)
    local hashed = decode_failure("# c" .. eol .. "[[1]]", { json5 = true, hash_comments = true, max_depth = 1 })
    assert(hashed == "JSON nests deeper than 1 levels at line 2, column 2", hashed)
  end
  -- Outside JSON5, a # comment runs past U+2028 to the \n, and the
  -- brackets it holds are no part of the count.
  local past = decode_failure("# [ \u{2028} [\n[[1]]", { hash_comments = true, max_depth = 1 })
  assert(past == "JSON nests deeper than 1 levels at line 2, column 2", past)
end

--- A syntax error's line counts every line end the text's grammar
--- has: \n, a lone \r, and \r\n as one; in JSON5, U+2028 and U+2029
--- too. RFC 8259 has those two only inside a string, where they are
--- characters, and the column counts their bytes.
local function test_a_failure_counts_each_line_end()
  for _, eol in ipairs({ "\n", "\r", "\r\n" }) do
    for _, five in ipairs({ false, true }) do
      local err = decode_failure("[1," .. eol .. eol .. "  x]", { json5 = five })
      assert(err:match("^invalid JSON at line 3, column 3: "), err)
    end
  end
  for _, eol in ipairs({ "\u{2028}", "\u{2029}" }) do
    local err = decode_failure("[1," .. eol .. "  x]", { json5 = true })
    assert(err:match("^invalid JSON at line 2, column 3: "), err)
    local strict = decode_failure('["' .. eol .. '", x]')
    assert(strict:match("^invalid JSON at line 1, column 9: "), strict)
    -- JSON5 takes one raw inside a quoted string, and it ends the
    -- line there too, as an editor shows it.
    local quoted = decode_failure("['a" .. eol .. "b', x]", { json5 = true })
    assert(quoted:match("^invalid JSON at line 2, column 5: "), quoted)
  end
end

--- `ascii` writes every character past ASCII as a \u escape -- U+2028
--- and U+2029 among them -- a surrogate pair past U+FFFF, in keys as in
--- values, and the text reads back to the same string.
local function test_ascii_escapes_every_character_past_ascii()
  local s = "é\u{2028}x\u{2029}\u{1F600}\u{FFFF}\u{80}\u{7FF}\u{800}\u{10FFFF}"
  local text = assert(Json.encode({ [s] = s }, { ascii = true }))
  local escaped = '"\\u00e9\\u2028x\\u2029\\ud83d\\ude00\\uffff\\u0080\\u07ff\\u0800\\udbff\\udfff"'
  assert(text == "{" .. escaped .. ":" .. escaped .. "}", text)
  assert(not text:find("[\128-\255]"), "a byte past ASCII was written")
  local back = assert(Json.decode(text)) as {string: string}
  assert(back[s] == s, "it does not read back")
  assert(Json.encode(s) == '"' .. s .. '"', "without ascii the text is as it was")
  assert(Json.encode_lines({ "é" }, { ascii = true }) == '"\\u00e9"\n', "encode_lines passes it on")
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

--- Every value `Json.lines` reads, and why it stopped.
local function stream_values(text: string, opts?: Json.DecodeOptions, max?: integer): {any}, string
  local lines = Json.lines(Stream.from_string(text), opts, max)
  local got: {any} = {}
  for value in lines:each() do got[#got + 1] = value end
  return got, lines:failure()
end

local function test_lines_reads_json_lines_from_a_reader()
  local got, trouble = stream_values('{"a":1}\r\n\n  \n[2,3]\n"four"')
  assert(trouble == "", trouble)
  assert(#got == 3)
  assert((got[1] as {string:integer}).a == 1)
  assert((got[2] as {integer})[2] == 3 and Json.is_array(got[2]))
  assert(got[3] == "four")
end

--- A null line is a value, never the end: `Json.null` by default, or
--- the `null_value` given.
local function test_lines_reads_a_null_line_as_a_value()
  local got, trouble = stream_values("1\nnull\n2\n")
  assert(trouble == "" and #got == 3 and got[2] == Json.null, trouble)
  local marked, marked_trouble = stream_values("null\n", { null_value = "none" })
  assert(marked_trouble == "" and marked[1] == "none", marked_trouble)
end

--- A line that is not JSON ends the values with a message naming it,
--- blank lines counted, and keeps failing.
local function test_lines_names_the_line_that_is_not_json()
  local lines = Json.lines(Stream.from_string('1\n\n{oops}\n4\n'))
  assert(lines:read() == 1)
  local value, trouble = lines:read()
  assert(value == nil and trouble:find("line 3", 1, true) ~= nil, trouble)
  local again, again_trouble = lines:read()
  assert(again == nil and again_trouble == trouble)
  assert(lines:failure() == trouble)
end

local function test_lines_holds_a_line_to_the_limit()
  local got, trouble = stream_values('"12345"\n' .. '"123456"\n', nil, 7)
  assert(#got == 1 and trouble:find("longer than 7 bytes", 1, true) ~= nil, trouble)
end

--- Values written a line at a time read back the same, and one that
--- cannot be encoded writes nothing.
local function test_write_line_writes_what_lines_reads()
  local out = Stream.collect()
  assert(Json.write_line(out, { b = 1, a = { 2, 3 } }, { sorted = true }))
  assert(Json.write_line(out, "x"))
  local wrote, trouble = Json.write_line(out, { [1] = 1, [3] = 3 })
  assert(not wrote and trouble ~= "")
  assert(out:result() == '{"a":[2,3],"b":1}\n"x"\n', out:result())
  local got, read_trouble = stream_values(out:result())
  assert(read_trouble == "" and #got == 2 and got[2] == "x")
  assert(not pcall(Json.write_line, out, 1, { pretty = true }))
end

--- The decode options reach every line.
local function test_lines_decodes_each_line_under_the_options()
  local got, trouble = stream_values("{a: 1} # one\n[2,] # two\n",
    { json5 = true, hash_comments = true })
  assert(trouble == "" and #got == 2, trouble)
  assert((got[1] as {string:integer}).a == 1)
end

--- A Writer's failure is write_line's, and a bad limit is the caller's
--- to hear about, named where it called.
local function test_write_line_answers_a_writer_failure_and_lines_a_bad_limit()
  local w: Stream.Writer = {}
  w.write = function(_self: Stream.Writer, _data: string): boolean, string
    return false, "disk full"
  end
  w.close = function(_self: Stream.Writer): boolean, string return true, "" end
  w.abort = w.close
  local wrote, trouble = Json.write_line(w, { 1 })
  assert(not wrote and trouble == "disk full", trouble)
  local function bad_limit(): Json.Lines
    -- Not a tail call, which would leave no frame here to name.
    local lines = Json.lines(Stream.from_string(""), nil, 0)
    return lines
  end
  local ok, message = pcall(bad_limit)
  assert(not ok and tostring(message):find("json_test", 1, true) ~= nil, tostring(message))
end

local function got(value: any, path: {string | integer}): any
  local v, err = Json.get(value, path)
  assert(err == "", err)
  return v
end

--- The message get fails with; the test fails if it succeeds.
local function get_failure(value: any, path: {string | integer}): string
  local v, err = Json.get(value, path)
  assert(v == nil and err ~= "", "expected get to fail")
  return err
end

--- Objects, arrays and an empty path.
local function test_get_descends_keys_and_indices_from_one()
  local doc = decoded('{"rows": [{"id": "a"}, {"id": "b", "odd key": [7]}], "n": 3}')
  assert(got(doc, { "rows", 1, "id" }) == "a")
  assert(got(doc, { "rows", 2, "odd key", 1 }) == 7)
  assert(got(doc, {}) == doc, "an empty path is the value")
  assert(got(doc, { "n" }) == 3)
  local nothing, err = Json.get(nil, {})
  assert(nothing == nil and err == "")
end

--- A failure names the path reached, as encode and shape write one.
local function test_get_names_the_path_of_a_failure()
  local doc = decoded('{"a": [{"b": 1}], "s": "x", "e": []}')
  assert(get_failure(doc, { "a", 1, "c" }) == '$.a[1]: no key "c"')
  assert(get_failure(doc, { "a", 2 }) == "$.a: index 2 out of range, the array has 1")
  assert(get_failure(doc, { "a", 0 }) == "$.a: index 0 out of range, the array has 1")
  assert(get_failure(doc, { "e", 1 }) == "$.e: index 1 out of range, the array has 0")
  assert(get_failure(doc, { "s", "x" }) == '$.s: expected an object to look up "x", got string')
  assert(get_failure(doc, { "s", 1 }) == "$.s: expected an array to look up [1], got string")
  assert(get_failure(doc, { "a", "b" }) == '$.a: expected an object to look up "b", got array')
  assert(get_failure(doc, { "a", 1, 1 }) == "$.a[1]: expected an array to look up [1], got object")
  assert(get_failure(doc, { "a key" }) == '$: no key "a key"')
end

--- Json.null is a value at the end and an error to go through.
local function test_get_treats_null_as_a_leaf()
  local doc = decoded('{"a": null, "l": [1, null]}', { null_value = Json.null })
  assert(got(doc, { "a" }) == Json.null)
  assert(got(doc, { "l", 2 }) == Json.null)
  assert(get_failure(doc, { "a", "b" }) == '$.a: expected an object to look up "b", got null')
  assert(get_failure(doc, { "a", 1 }) == "$.a: expected an array to look up [1], got null")
  local plain = decoded('{"a": null}')
  assert(get_failure(plain, { "a" }) == '$: no key "a"')
end

local function test_get_raises_on_a_step_that_is_no_key_or_index()
  local ok, message = pcall(Json.get, {}, { true } as {any} as {string | integer})
  assert(not ok and tostring(message):find("got boolean", 1, true) ~= nil, tostring(message))
  local function float_step(): any
    -- Not a tail call, which would leave no frame here to name.
    local v = Json.get({ 1 }, { 1.0 } as {any} as {string | integer})
    return v
  end
  local ok2, float = pcall(float_step)
  assert(not ok2 and tostring(float):find("got float", 1, true) ~= nil, tostring(float))
  assert(tostring(float):find("json_test", 1, true) ~= nil, "named where it was called: " .. tostring(float))
end

local function test_get_tells_a_key_from_an_index_and_takes_no_negative_one()
  local arr = decoded('[10, 20]')
  assert(get_failure(arr, { "1" }) == '$: expected an object to look up "1", got array')
  assert(get_failure(arr, { "x" }) == '$: expected an object to look up "x", got array')
  assert(get_failure(arr, { -1 }) == "$: index -1 out of range, the array has 2")
  local obj = decoded('{"1": "s"}')
  assert(got(obj, { "1" }) == "s")
  assert(get_failure(obj, { 1 }) == "$: expected an array to look up [1], got object")
  assert(get_failure({ 10, 20 }, { "x" }) == '$: expected an object to look up "x", got array')
  local mixed = { 1, a = 2 }
  assert(get_failure(mixed, { "a" }) == '$: expected an object to look up "a", got table with mixed keys')
  assert(get_failure(mixed, { 1 }) == "$: expected an array to look up [1], got table with mixed keys")
end

--- entries and items take a path as get does, and name it.
local function test_entries_and_items_take_a_path()
  local doc = decoded('{"a": {"rows": [{"id": 1}, {"id": 2}]}, "s": "x"}')
  local ids = 0
  for _, row in ipairs((assert(Json.items(doc, { "a", "rows" })))) do
    for _, id in pairs((assert(Json.entries(row)))) do ids = ids + (id as integer) end
  end
  assert(ids == 3)
  assert(Json.entries(doc, { "a", "rows", 2 }) ~= nil)
  assert(Json.entries(doc, {}) ~= nil, "an empty path is the value")
  local _a, why_a = Json.items(doc, { "a" })
  assert(why_a == "$.a: expected a JSON array, got object", why_a)
  local _b, why_b = Json.entries(doc, { "a", "rows" })
  assert(why_b == "$.a.rows: expected a JSON object, got array", why_b)
  local _c, why_c = Json.items(doc, { "a", "nope" })
  assert(why_c == '$.a: no key "nope"', why_c)
  local _d, why_d = Json.items(doc, { "s", 1 })
  assert(why_d == "$.s: expected an array to look up [1], got string", why_d)
  local _e, why_e = Json.items(doc, {})
  assert(why_e == "$: expected a JSON array, got object", why_e)
end

local function test_entries_and_items_narrow_by_kind()
  local doc = decoded('{"o": {"b": 1, "a": 2}, "l": [1, 2], "e": [], "eo": {}}')
  local o = assert(Json.entries(got(doc, { "o" })))
  local keys: {string} = {}
  for k in pairs(o) do keys[#keys + 1] = k end
  table.sort(keys)
  assert(table.concat(keys, ",") == "a,b")
  local l = assert(Json.items(got(doc, { "l" })))
  assert(#l == 2 and l[2] == 2)
  assert(#assert(Json.items(got(doc, { "e" }))) == 0, "a decoded [] is an array")
  assert(assert(Json.entries(got(doc, { "eo" }))) ~= nil)
  assert(Json.entries(got(doc, { "e" })) == nil, "a decoded [] is not an object")
  local _, why = Json.entries(got(doc, { "l" }))
  assert(why == "expected a JSON object, got array", why)
  local _l, why_l = Json.items(got(doc, { "o" }))
  assert(why_l == "expected a JSON array, got object", why_l)
  local _s, why_s = Json.items("x")
  assert(why_s == "expected a JSON array, got string", why_s)
  local _n, why_n = Json.entries(Json.null)
  assert(why_n == "expected a JSON object, got null", why_n)
  local _z, why_z = Json.entries(nil)
  assert(why_z == "expected a JSON object, got null", why_z)
end

--- An empty table's kind follows encode: an object unless marked.
local function test_entries_and_items_follow_the_encode_rules_for_tables()
  assert(Json.entries({}) ~= nil and Json.items({}) == nil)
  assert(Json.items(Json.array()) ~= nil and Json.entries(Json.array()) == nil)
  assert(Json.items({ 1, 2 }) ~= nil and Json.entries({ 1, 2 }) == nil)
  local mixed = { 1, a = 2 }
  local _, why = Json.entries(mixed)
  assert(why == "expected a JSON object, got table with mixed keys", why)
  assert(Json.items(mixed) == nil)
  local _h, why_h = Json.items({ [1] = 1, [3] = 3 })
  assert(why_h == "expected a JSON array, got array with a hole", why_h)
end

local function test_describe_summarizes_nested_shapes_sorted()
  local doc = decoded('{"today": {"accounts": [{"id": "a", "balance": 1.5}, {"id": "b", "balance": 2}]},'
    .. ' "plans": [{"x": 1}, {"x": 2}, {"x": 3}], "ok": true, "name": "n"}')
  assert(Json.describe(doc) == "{name: string, ok: boolean, plans: [3 x {x: number}],"
    .. " today: {accounts: [2 x {balance: number, id: string}]}}", Json.describe(doc))
  assert(Json.describe(doc, { max_depth = 2 }) == "{name: string, ok: boolean, plans: [3 x {...}],"
    .. " today: {accounts: [2 x ...]}}", Json.describe(doc, { max_depth = 2 }))
  assert(Json.describe(doc, { max_depth = 0 }) == "{...}")
end

local function test_describe_merges_heterogeneous_elements()
  assert(Json.describe(decoded('[1, "a", 2, null, true]', { null_value = Json.null })) == "[5 x boolean|null|number|string]")
  assert(Json.describe(decoded('[{"a": 1}, {"a": 2, "b": "x"}, {"a": "s"}]'))
    == "[3 x {a: number|string, b?: string}]")
  assert(Json.describe(decoded('[[1, 2], [3], []]')) == "[3 x [0..2 x number]]")
  assert(Json.describe(decoded('[{"a": 1}, 2]')) == "[2 x number|{a: number}]")
end

local function test_describe_scalars_empties_and_null()
  assert(Json.describe(nil) == "null")
  assert(Json.describe(Json.null) == "null")
  assert(Json.describe("s") == "string")
  assert(Json.describe(1) == "number" and Json.describe(1.5) == "number")
  assert(Json.describe(decoded("[]")) == "[0]")
  assert(Json.describe(decoded("{}")) == "{}")
  assert(Json.describe(decoded('{"a": {}, "b": [], "c": null}', { null_value = Json.null }))
    == "{a: {}, b: [0], c: null}")
  assert(Json.describe(decoded('{"odd key": 1}')) == '{"odd key": number}', Json.describe(decoded('{"odd key": 1}')))
  assert(not pcall(Json.describe, {}, { max_depth = -1 }))
  local fraction: any = 1.5
  assert(not pcall(Json.describe, {}, { max_depth = fraction as integer }))
end

--- `?` and a depth cut, objects merged across nested arrays, holes.
local function test_describe_optional_keys_cuts_and_holes()
  assert(Json.describe(decoded('[{"a": {"x": 1}}, {"b": 1}]'), { max_depth = 2 })
    == "[2 x {a?: {...}, b?: number}]")
  assert(Json.describe(decoded('[[{"a": 1}], [{"b": 1}]]')) == "[2 x [1 x {a?: number, b?: number}]]")
  local holed = decoded('[1, null, 3]', { null_value = Json.null })
  assert(Json.describe(holed) == "[3 x null|number]")
  local plain = Json.describe(decoded('[1, null, 3]'))
  assert(plain:find("^%[%d x number") ~= nil, plain)
end

local function test_quote_and_child_path_spell_a_path()
  assert(Json.quote('a"b\\c\n') == '"a\\"b\\\\c\\u000a"')
  assert(Json.child_path("$", "rows") == "$.rows")
  assert(Json.child_path("$.rows", 2) == "$.rows[2]")
  assert(Json.child_path("$", "a key") == '$["a key"]')
end

local function test_describe_a_long_array_is_one_merged_shape()
  local items = Json.array()
  for i = 1, 5000 do items[i] = { id = i, tag = "t" } end
  assert(Json.describe(items) == "[5000 x {id: number, tag: string}]")
  local cycle: {any:any} = {}
  cycle.self = cycle
  assert(Json.describe(cycle, { max_depth = 3 }) == "{self: {self: {self: {...}}}}")
end

--- The float-step raise reaches a caller of entries and items too.
local function test_entries_and_items_raise_on_a_float_step_naming_the_caller()
  local function entries_step(): any
    local v = Json.entries({ {} }, { 1.0 } as {any} as {string | integer})
    return v
  end
  local function items_step(): any
    local v = Json.items({ {} }, { 1.0 } as {any} as {string | integer})
    return v
  end
  for _, f in ipairs({ entries_step, items_step }) do
    local ok, message = pcall(f)
    assert(not ok and tostring(message):find("got float", 1, true) ~= nil, tostring(message))
    assert(tostring(message):find("json_test", 1, true) ~= nil, tostring(message))
  end
end

local function test_get_raises_on_a_path_with_a_nil_hole()
  local path: {any} = { "a", nil, "b" }
  local function hole(): any
    local v = Json.get({}, path as {string | integer})
    return v
  end
  local ok, message = pcall(hole)
  assert(not ok and tostring(message):find("nil hole", 1, true) ~= nil, tostring(message))
end

--- A lookup in a large decoded object is direct, not a scan of its keys:
--- a scan apiece would take minutes here.
local function test_get_on_a_large_object_does_not_scan_it()
  local parts: {string} = {}
  for i = 1, 100000 do parts[i] = '"k' .. i .. '": ' .. i end
  local doc = decoded("{" .. table.concat(parts, ",") .. "}")
  local started = Time.monotonic_ns()
  local total = 0
  for i = 1, 20000 do
    total = total + (got(doc, { "k" .. i }) as integer)
  end
  assert(total == 20000 * 20001 // 2)
  assert(Time.monotonic_ns() - started < 1000000000, "get scanned the object")
end

local function path_of(text: string): {string | integer}
  local steps, err = Json.parse_path(text)
  assert(steps ~= nil, text .. ": " .. err)
  assert(err == "")
  return steps
end

local function assert_steps(text: string, want: {string | integer})
  local read = path_of(text)
  assert(#read == #want, text .. " read as " .. #read .. " steps")
  for i, step in ipairs(want) do
    assert(read[i] == step and math.type(read[i] as number) == math.type(step as number), text .. " step " .. i)
  end
end

local function refused_path(text: string, why: string)
  local steps, err = Json.parse_path(text)
  assert(steps == nil, text .. " read")
  assert(err:find(why, 1, true), text .. ": " .. err)
end

local function test_parse_path_reads_the_forms_child_path_writes()
  assert_steps("$", {})
  assert_steps("$.a", { "a" })
  assert_steps("$.rows[2].name", { "rows", 2, "name" })
  assert_steps('$["a key"][1]', { "a key", 1 })
  assert_steps('$["\\"\\\\\\n\\u00e9\\ud83d\\ude00"]', { '"\\\né\u{1F600}' })
  assert_steps("$[-1]", { -1 })
end

local function test_parse_path_takes_a_bare_or_dotted_start()
  assert_steps("a.b", { "a", "b" })
  assert_steps(".a.b", { "a", "b" })
  assert_steps("[1]", { 1 })
  assert_steps('["a b"].c', { "a b", "c" })
  assert_steps("a[1].b", { "a", 1, "b" })
  assert_steps("$.foo-bar", { "foo-bar" })
end

local function test_parse_path_names_where_a_path_stops_being_one()
  refused_path("", "empty")
  refused_path("$.", "column 3: expected a key")
  refused_path("$..a", "column 2: `..`")
  refused_path("$a", "expected `.` or `[`")
  refused_path("$[", "expected an integer or a quoted key")
  refused_path("$[]", "expected an integer or a quoted key")
  refused_path("$[1.5]", "expected an integer or a quoted key")
  refused_path("$[ 1 ]", "expected an integer or a quoted key")
  refused_path('$["a', "unclosed [")
  refused_path('$["a"', "expected `]`")
  refused_path('$["a"]x', "expected `.` or `[`")
  refused_path('$["\\x"]', "no such escape")
  refused_path('$["\\ud83d"]', "lone surrogate")
  refused_path('$["\\ude00"]', "lone surrogate")
  refused_path('$["\\u12"]', "four hex digits")
  refused_path("$[9223372036854775808]", "does not fit an integer")
end

local function test_parse_path_refuses_wildcards_and_descent_pointing_at_patterns()
  refused_path("$.a..b", "`..` (recursive descent) is a pattern, not a path")
  refused_path("..balance", "Json.parse_pattern")
  refused_path("$..", "recursive descent")
  refused_path("$.*", "Json.parse_pattern")
  refused_path("$.a.*.b", "wildcard")
  refused_path("*", "wildcard")
  refused_path("$[*]", "Json.parse_pattern")
  refused_path("a[*]", "wildcard")
  refused_path("$..[1]", "recursive descent")
  -- A key named `*` is still reachable, quoted, and `*` inside a longer key is a key.
  assert_steps('$["*"]', { "*" })
  assert_steps("$.a*", { "a*" })
  assert_steps("$.*a", { "*a" })
  assert_steps(Json.child_path("$", "*"), { "*" })
end

local function test_parse_path_round_trips_child_path()
  local keys = { "a", "a key", "", "a.b", '"', "\\", "\n", "\xff", "é", "[1]" }
  for _, key in ipairs(keys) do
    local text = Json.child_path(Json.child_path("$", key), 3)
    assert_steps(text, { key, 3 })
  end
end

local function flat_lines(value: any, opts?: Json.WalkOptions): {string}
  local leaves, err = Json.flatten(value, opts)
  assert(leaves ~= nil, err)
  assert(err == "")
  local lines: {string} = {}
  for i, leaf in ipairs(leaves) do
    local line, why = Json.flat_line(leaf.path, leaf.value)
    assert(line ~= nil, why)
    lines[i] = line
  end
  return lines
end

local function assert_lines(got_lines: {string}, want: {string})
  assert(table.concat(got_lines, "\n") == table.concat(want, "\n"),
    "got:\n" .. table.concat(got_lines, "\n") .. "\nwant:\n" .. table.concat(want, "\n"))
end

local function pat(text: string): {Json.Step}
  local steps, err = Json.parse_pattern(text)
  assert(steps ~= nil, text .. ": " .. err)
  return steps
end

local function test_flatten_lists_every_leaf_in_a_fixed_order()
  local doc = decoded('{"n": null, "c": "s", "b": [10, {"z": 1, "a": []}], "a": {}, "f": 1200.5, "t": true}',
    { null_value = Json.null })
  assert_lines(flat_lines(doc), {
    "$.a = {}", "$.b[1] = 10", "$.b[2].a = []", "$.b[2].z = 1", "$.c = \"s\"",
    "$.f = 1200.5", "$.n = null", "$.t = true",
  })
end

local function test_flatten_spells_keys_as_child_path_does()
  local doc = decoded('{"k k": [{"a.b": 1}], "": 2, "q\\"": 3}')
  assert_lines(flat_lines(doc), { '$[""] = 2', '$["k k"][1]["a.b"] = 1', '$["q\\""] = 3' })
end

local function test_flatten_of_a_scalar_or_an_empty_container_is_that_one_leaf()
  assert_lines(flat_lines(3), { "$ = 3" })
  assert_lines(flat_lines("x"), { '$ = "x"' })
  assert_lines(flat_lines(decoded("{}")), { "$ = {}" })
  assert_lines(flat_lines(decoded("[]")), { "$ = []" })
  assert_lines(flat_lines(Json.array()), { "$ = []" })
  assert_lines(flat_lines(decoded("null", { null_value = Json.null })), { "$ = null" })
  assert_lines(flat_lines(decoded('[[], [[]], {}]')), { "$[1] = []", "$[2][1] = []", "$[3] = {}" })
end

local function test_flatten_skips_holes_and_keeps_the_neighbours_indexes()
  local holey: {integer:string} = { [1] = "a", [3] = "c", [7] = "g" }
  assert_lines(flat_lines(holey), { '$[1] = "a"', '$[3] = "c"', '$[7] = "g"' })
  -- Nulls decoded to nothing leave an object member absent, and an object of only those is empty.
  assert_lines(flat_lines(decoded('{"a": null, "b": 1}')), { "$.b = 1" })
  assert_lines(flat_lines(decoded('{"a": null}')), { "$ = {}" })
end

local function test_flatten_root_spells_the_value_where_it_was_found()
  local doc = decoded('{"users": [{"id": 1}]}')
  local user = got(doc, { "users", 1 })
  assert_lines(flat_lines(user, { root = "$.users[1]" }), { "$.users[1].id = 1" })
end

local function test_flatten_stops_at_max_depth_naming_the_path()
  local doc = decoded('{"a": {"b": [1]}}')
  local leaves, err = Json.flatten(doc, { max_depth = 2 })
  assert(leaves == nil and err:find("$.a.b", 1, true) and err:find("max_depth 2", 1, true), err)
  assert_lines(flat_lines(doc, { max_depth = 3 }), { "$.a.b[1] = 1" })
  -- An empty container still nests: it is a container.
  local _, empty_err = Json.flatten(decoded('[[[]]]'), { max_depth = 2 })
  assert(empty_err:find("$[1][1]", 1, true), empty_err)
  local deep: any = 1
  for _ = 1, 100 do deep = { deep } end
  local _, default_err = Json.flatten(deep)
  assert(default_err:find("max_depth 64", 1, true), default_err)
  assert(Json.flatten(deep, { max_depth = 200 }) ~= nil)
  assert(not pcall(Json.flatten, doc, { max_depth = 0 }))
  assert(not pcall(Json.flatten, doc, { max_depth = Json.depth_limit + 1 }))
end

local function test_flatten_fails_on_a_cycle_and_on_mixed_keys()
  local loop: {string:any} = { name = "x" }
  loop.self = loop
  local leaves, err = Json.flatten(loop)
  assert(leaves == nil and err:find("$.self: the table contains itself", 1, true), err)
  local mixed: {any:any} = { a = 1, [1] = 2 }
  local m, mixed_err = Json.flatten({ rows = mixed })
  assert(m == nil and mixed_err:find("$.rows: expected an object or an array, got table with mixed keys", 1, true), mixed_err)
  -- The same table twice is no cycle.
  local shared = { 1 }
  assert_lines(flat_lines({ a = shared, b = shared }), { "$.a[1] = 1", "$.b[1] = 1" })
end

local function test_flat_line_prints_the_compact_value()
  assert(Json.flat_line("$.a[1].b", 1200.5) == "$.a[1].b = 1200.5")
  assert(Json.flat_line("$", Json.null) == "$ = null")
  assert(Json.flat_line("$.s", 'a "q" = b\n') == '$.s = "a \\"q\\" = b\\n"')
  local line, err = Json.flat_line("$.f", function() end)
  assert(line == nil and err:find("$.f", 1, true), err)
end

local function test_every_flat_path_reads_back_to_its_leaf()
  local doc = decoded('{"a b": [1, {"c\\"d": [true, null, {}], "e": "s"}], "": {"": 0}, "$": 1.5}',
    { null_value = Json.null })
  local leaves = assert(Json.flatten(doc))
  assert(#leaves == 7, #leaves)
  for _, leaf in ipairs(leaves) do
    local steps = path_of(leaf.path)
    local value = got(doc, steps)
    local expected = leaf.value
    if expected is {any:any} then
      assert(encoded(value) == encoded(expected), leaf.path)
    else
      assert(value == expected, leaf.path)
    end
  end
end

local record Kinds
  kind: Json.StepKind
  key: string
  index: integer
end

local function assert_pattern(text: string, want: {Kinds})
  local steps, err = Json.parse_pattern(text)
  assert(steps ~= nil, text .. ": " .. err)
  assert(err == "")
  assert(#steps == #want, text .. " read as " .. #steps .. " steps")
  for i, w in ipairs(want) do
    assert(steps[i].kind == w.kind and steps[i].key == w.key and steps[i].index == w.index,
      text .. " step " .. i .. " is " .. steps[i].kind)
  end
  assert(Json.spell_pattern(steps) == Json.spell_pattern(pat(Json.spell_pattern(steps))))
end

local function refused_pattern(text: string, why: string)
  local steps, err = Json.parse_pattern(text)
  assert(steps == nil, text .. " read")
  assert(err:find(why, 1, true), text .. ": " .. err)
end

local function test_parse_pattern_reads_wildcards_and_descent()
  assert_pattern("$", {})
  assert_pattern("$.a.*", { { kind = "key", key = "a" }, { kind = "any" } })
  assert_pattern("a[*].b", { { kind = "key", key = "a" }, { kind = "any" }, { kind = "key", key = "b" } })
  assert_pattern("*", { { kind = "any" } })
  assert_pattern("$..id", { { kind = "deep_key", key = "id" } })
  assert_pattern("..id", { { kind = "deep_key", key = "id" } })
  assert_pattern("$.a..[3]", { { kind = "key", key = "a" }, { kind = "deep_index", index = 3 } })
  assert_pattern('$..["a key"].x', { { kind = "deep_key", key = "a key" }, { kind = "key", key = "x" } })
  assert_pattern("$..*", { { kind = "deep_any" } })
  assert_pattern("$..[*]", { { kind = "deep_any" } })
  assert_pattern("$[-1]..a[2]", { { kind = "index", index = -1 }, { kind = "deep_key", key = "a" }, { kind = "index", index = 2 } })
  -- Quoted `*` and `..` are keys.
  assert_pattern('$["*"]["..x"]', { { kind = "key", key = "*" }, { kind = "key", key = "..x" } })
  assert_pattern("$.a*.*b", { { kind = "key", key = "a*" }, { kind = "key", key = "*b" } })
end

local function test_parse_pattern_refuses_what_parse_path_refuses()
  refused_pattern("", "empty")
  refused_pattern("$.", "column 3: expected a key")
  refused_pattern("$..", "column 4: expected a key after `..`")
  refused_pattern("$...a", "expected a key after `..`")
  refused_pattern("$.a..", "expected a key after `..`")
  refused_pattern("$[", "expected an integer or a quoted key")
  refused_pattern("$[**]", "expected an integer or a quoted key")
  refused_pattern("$..[", "expected an integer or a quoted key")
  refused_pattern("$..[1.5]", "expected an integer or a quoted key")
  refused_pattern('$.*["a', "unclosed [")
  refused_pattern("$.*x[1]y", "expected `.` or `[`")
end

local function test_parse_pattern_and_parse_path_agree_on_plain_text_and_split_on_the_rest()
  for _, text in ipairs({ "$", "$.a[2][\"b c\"]", "a.b", "[1]", '$["*"]' }) do
    local plain = path_of(text)
    local steps = pat(text)
    assert(#steps == #plain, text)
    for i, step in ipairs(steps) do
      local want: string | integer = plain[i]
      if want is string then
        assert(step.kind == "key" and step.key == want, text)
      else
        assert(step.kind == "index" and step.index == want, text)
      end
    end
  end
  for _, text in ipairs({ "$.*", "$.a[*]", "$..a", "$.a..[1]", "$..*" }) do
    refused_path(text, "Json.parse_pattern")
    assert(#pat(text) > 0, text)
  end
end

local function test_spell_pattern_reads_back_as_the_same_steps()
  for _, text in ipairs({ "$", "$.a.*", "$..id", '$..["a key"]', "$..[3]", "$..*", '$["*"]..["*"]', "$[-2]" }) do
    assert(Json.spell_pattern(pat(text)) == text, text)
  end
  assert(Json.spell_pattern(pat("a[*]..b")) == "$.a.*..b")
  assert(not pcall(Json.spell_pattern, { { kind = "key" } }))
end

--- The paths `Json.select` finds for `pattern` in `doc`, joined by spaces.
local function selected(doc: any, pattern: string): string
  local found, err = Json.select(doc, pat(pattern))
  assert(found ~= nil, pattern .. ": " .. err)
  assert(err == "")
  local paths: {string} = {}
  for i, match in ipairs(found) do paths[i] = match.path end
  return table.concat(paths, " ")
end

local SELECT_DOC <const> = [=[
{"id": 0, "users": [{"id": 1, "name": "ann", "tags": ["x", "y"], "kin": {"id": 11}},
                    {"id": 2, "name": "bo", "tags": []}],
 "meta": {"id": 9, "n": null, "deep": {"deep": {"id": 10}}}, "k k": [[1, 2], [3]]}
]=]

local function test_select_a_plain_pattern_matches_what_get_finds()
  local doc = decoded(SELECT_DOC)
  assert(selected(doc, "$") == "$")
  assert(selected(doc, "$.users[2].name") == "$.users[2].name")
  assert(selected(doc, '$["k k"][2][1]') == '$["k k"][2][1]')
  assert(selected(doc, "$.nope") == "")
  assert(selected(doc, "$.users[3]") == "")
  assert(selected(doc, "$.id.x") == "")
end

local function test_select_wildcards_take_every_member_or_element()
  local doc = decoded(SELECT_DOC, { null_value = Json.null })
  assert(selected(doc, "$.users[*].name") == "$.users[1].name $.users[2].name")
  assert(selected(doc, "$.users.*.name") == "$.users[1].name $.users[2].name")
  assert(selected(doc, "$.meta.*") == "$.meta.deep $.meta.id $.meta.n")
  assert(selected(doc, "$.users[1].tags[*]") == "$.users[1].tags[1] $.users[1].tags[2]")
  assert(selected(doc, '$["k k"][*][*]') == '$["k k"][1][1] $["k k"][1][2] $["k k"][2][1]')
  assert(selected(doc, "$.users[*].tags[*]") == "$.users[1].tags[1] $.users[1].tags[2]")
  assert(selected(doc, "$.users[2].tags[*]") == "")
  -- A wildcard over a scalar or a null matches nothing, and is no error.
  assert(selected(doc, "$.id.*") == "")
  assert(selected(doc, "$.meta.n[*]") == "")
  assert(selected(doc, "$.users[*].nope") == "")
  assert(selected(doc, "$.id[*]") == "")
  assert(selected(doc, "$.tags[*]") == "")
end

local function test_select_a_wildcard_meeting_the_other_kind_of_container_matches_by_kind()
  local doc = decoded('{"o": {"1": "s"}, "a": ["t"]}')
  assert(selected(doc, "$.o[1]") == "")
  assert(selected(doc, "$.a.x") == "")
  assert(selected(doc, "$.o[*]") == '$.o["1"]')
  assert(selected(doc, "$.*[*]") == '$.a[1] $.o["1"]')
end

local function test_select_descent_finds_a_key_at_any_depth_root_level_included()
  local doc = decoded(SELECT_DOC, { null_value = Json.null })
  assert(selected(doc, "$..id") ==
    "$.id $.meta.deep.deep.id $.meta.id $.users[1].id $.users[1].kin.id $.users[2].id")
  -- At the root's own level and below, and a match before what is inside it.
  assert(selected(decoded('{"a": {"a": 1}, "b": {"a": 2}}'), "$..a") == "$.a $.a.a $.b.a")
  assert(selected(decoded('{"a": 1}'), "..a") == "$.a")
  assert(selected(doc, "$..deep") == "$.meta.deep $.meta.deep.deep")
  assert(selected(doc, "$.meta..deep.id") == "$.meta.deep.deep.id")
  assert(selected(doc, "$.users..name") == "$.users[1].name $.users[2].name")
  assert(selected(doc, "$..nope") == "")
  assert(selected(decoded("5"), "$..a") == "")
end

local function test_select_descent_by_index_and_over_everything()
  local doc = decoded(SELECT_DOC, { null_value = Json.null })
  assert(selected(doc, "$..[1]") == '$["k k"][1] $["k k"][1][1] $["k k"][2][1] $.users[1] $.users[1].tags[1]')
  assert(selected(doc, "$.users[1].kin..*") == "$.users[1].kin.id")
  assert(selected(decoded('{"a": [1, [2]]}'), "$..*") == "$.a $.a[1] $.a[2] $.a[2][1]")
  assert(selected(decoded('{"a": [1, [2]]}'), "$..[*]") == "$.a $.a[1] $.a[2] $.a[2][1]")
end

local function test_select_lists_each_value_once_however_it_is_reached()
  local doc = decoded('{"a": {"a": {"a": {"b": 1}}}}')
  assert(selected(doc, "$..a..b") == "$.a.a.a.b")
  assert(selected(doc, "$..a.a.b") == "$.a.a.a.b")
  assert(selected(doc, "$..a..*") == "$.a.a $.a.a.a $.a.a.a.b")
  local paired = decoded('{"x": {"x": 1}}')
  assert(selected(paired, "$..x..x") == "$.x.x")
end

local function test_select_answers_the_values_with_the_paths()
  local doc = decoded('{"a": [{"n": 1}, {"n": 2.5}], "b": {"n": "s"}}')
  local found = assert(Json.select(doc, pat("$..n")))
  assert(#found == 3)
  assert(found[1].path == "$.a[1].n" and found[1].value == 1)
  assert(found[2].path == "$.a[2].n" and found[2].value == 2.5)
  assert(found[3].path == "$.b.n" and found[3].value == "s")
  local whole = assert(Json.select(doc, {}))
  assert(#whole == 1 and whole[1].path == "$" and rawequal(whole[1].value, doc))
  local container = assert(Json.select(doc, pat("$.a[*]")))
  assert(rawequal(container[1].value, (got(doc, { "a", 1 }))))
  -- Each match's path reads back to it.
  for _, match in ipairs(found) do assert(got(doc, path_of(match.path)) == match.value) end
end

local function test_select_spells_paths_from_the_root_it_is_given()
  local doc = decoded('{"n": 1, "m": [2]}')
  local found = assert(Json.select(doc, pat("$.*"), { root = "$.x" }))
  assert(#found == 2 and found[1].path == "$.x.m" and found[2].path == "$.x.n")
end

local function test_select_hole_matches_nothing_and_neighbours_keep_indexes()
  local holey: {any:any} = { [1] = "a", [3] = "c" }
  assert(selected(holey, "$[*]") == "$[1] $[3]")
  assert(selected(holey, "$[2]") == "")
  assert(selected(holey, "$[3]") == "$[3]")
  assert(selected(holey, "$..*") == "$[1] $[3]")
end

local function test_select_fails_like_flatten_on_depth_cycles_and_mixed_keys()
  local doc = decoded('{"a": {"b": {"c": 1}}}')
  local found, err = Json.select(doc, pat("$..c"), { max_depth = 2 })
  assert(found == nil and err:find("$.a.b: nested deeper than max_depth 2", 1, true), err)
  assert(Json.select(doc, pat("$..c"), { max_depth = 3 }) ~= nil)
  -- A pattern that never goes down that far does not meet the limit.
  assert(Json.select(doc, pat("$.a"), { max_depth = 1 }) ~= nil)
  local loop: {string:any} = { name = "x" }
  loop.self = loop
  local _, cycle = Json.select(loop, pat("$..zzz"))
  assert(cycle:find("contains itself", 1, true), cycle)
  local _, mixed = Json.select({ a = 1, [1] = 2 }, pat("$.*"))
  assert(mixed:find("mixed keys", 1, true), mixed)
  assert(not pcall(Json.select, doc, { { kind = "key" } }))
  assert(not pcall(Json.select, doc, {}, { max_depth = 0 }))
end

--- `value` with every table replaced by an empty one that answers for it,
--- and counts in `counter[1]` each time it is walked by `pairs`: one for
--- every container a walk lays out, so a test can bound the work a walk
--- does by what it counted, not by how long it took.
local function counted(value: any, counter: {integer}): any
  if not (value is {any:any}) then return value end
  local copy: {any:any} = {}
  for key, member in pairs(value) do copy[key] = counted(member, counter) end
  local walk_copy: function(): any, any, any = function(): any, any, any
    counter[1] = counter[1] + 1
    return next, copy, nil
  end
  return setmetatable({}, { __index = copy, __pairs = walk_copy })
end

local function test_select_descent_over_a_large_document_lays_out_each_container_once()
  local parts: {string} = {}
  for i = 1, 16000 do
    parts[i] = '{"id": ' .. i .. ', "tags": ["a", "b"], "in": {"id": -' .. i .. '}}'
  end
  -- 16000 records of 7 values each is over 100k values, of which 48002
  -- are containers: the root, rows, and per record the record, tags and
  -- in.
  local counter = { 0 }
  local doc = counted(decoded('{"rows": [' .. table.concat(parts, ",") .. ']}'), counter)
  local ids = assert(Json.select(doc, pat("$..id")))
  assert(#ids == 32000, #ids)
  assert(ids[1].path == "$.rows[1].id" and ids[2].path == "$.rows[1].in.id")
  assert(counter[1] == 48002, "laid out " .. counter[1] .. " containers")
  -- Nor does a second descent, or a wildcard, walk anything twice.
  counter[1] = 0
  assert(#assert(Json.select(doc, pat("$..in..id"))) == 16000)
  assert(counter[1] == 48002, "laid out " .. counter[1] .. " containers")
end

local function test_select_chained_descents_are_linear_not_a_product()
  -- Every `a` is inside every earlier `a`: a walk that restarts at each
  -- match meets the innermost ones once per way of reaching them, over
  -- 100 million times here, and lists them that often.
  local chain: any = { leaf = 1 }
  for _ = 1, 900 do chain = { a = chain } end
  local counter = { 0 }
  local found = assert(Json.select(counted(chain, counter), pat("$..a..a..a"), { max_depth = 1000 }))
  assert(#found == 898, #found)
  assert(found[1].path == "$.a.a.a" and found[898].path:sub(-6) == ".a.a.a")
  assert(counter[1] == 901, "laid out " .. counter[1] .. " containers")
end

local function test_select_spells_each_path_from_the_one_before_it()
  -- 900 matches at depths 1 to 900: spelling each from `$` would be
  -- 400k steps; the paths have to come out right all the same.
  local chain: any = { leaf = 1 }
  for _ = 1, 900 do chain = { a = chain } end
  local found = assert(Json.select(chain, pat("$..a"), { max_depth = 1000 }))
  assert(#found == 900, #found)
  local text = "$"
  for i = 1, 900 do
    text = text .. ".a"
    assert(found[i].path == text, i)
  end
end

local function test_flatten_of_a_large_document_lays_out_each_container_once()
  local rows: {any} = {}
  for i = 1, 25000 do rows[i] = { id = i, tags = { "a", "b" }, ["in"] = { id = -i } } end
  local counter = { 0 }
  local leaves = assert(Json.flatten(counted({ rows = Json.array(rows) }, counter)))
  assert(#leaves == 100000, #leaves)
  assert(leaves[1].path == "$.rows[1].id" and leaves[4].path == "$.rows[1].tags[2]")
  assert(counter[1] == 75002, "laid out " .. counter[1] .. " containers")
end

local function test_a_decoded_array_with_holes_keeps_the_elements_past_them()
  assert_lines(flat_lines(decoded("[null, 2, 3]")), { "$[2] = 2", "$[3] = 3" })
  assert_lines(flat_lines(decoded("[1, null, 3]")), { "$[1] = 1", "$[3] = 3" })
  assert_lines(flat_lines(decoded("[1, null, null]")), { "$[1] = 1" })
  assert_lines(flat_lines(decoded('{"a": [null, {"b": 1}, null, [4]]}')), { "$.a[2].b = 1", "$.a[4][1] = 4" })
  assert_lines(flat_lines(decoded("[null, null]")), { "$ = []" })
  assert(selected(decoded("[null, 2, 3]"), "$[*]") == "$[2] $[3]")
  assert(selected(decoded("[1, null, 3]"), "$[*]") == "$[1] $[3]")
  assert(selected(decoded("[1, null, 3]"), "$[3]") == "$[3]")
  assert(selected(decoded("[1, null, 3]"), "$[2]") == "")
  assert(selected(decoded('{"a": [null, {"b": 1}, [null, 5]]}'), "$..*") == "$.a $.a[2] $.a[2].b $.a[3] $.a[3][2]")
  assert(selected(decoded('[null, {"id": 1}, null, {"id": 2}]'), "$..id") == "$[2].id $[4].id")
end

local function test_select_refuses_a_pattern_of_more_than_62_steps()
  local steps: {Json.Step} = {}
  for i = 1, 62 do steps[i] = { kind = "any" } end
  local deep: any = 1
  for _ = 1, 62 do deep = { deep } end
  local found = assert(Json.select(deep, steps, { max_depth = 100 }))
  assert(#found == 1 and found[1].path:sub(1, 6) == "$[1][1")
  steps[63] = { kind = "any" }
  local none, err = Json.select(deep, steps)
  assert(none == nil and err:find("at most 62 steps, not 63", 1, true), err)
end

local function test_select_a_plain_step_meets_mixed_keys_as_a_wildcard_does()
  local mixed: {any:any} = { a = 1, [1] = 2 }
  for _, text in ipairs({ "$.x.a", "$.x[1]", "$.x.*", "$.x..a" }) do
    local found, err = Json.select({ x = mixed }, pat(text))
    assert(found == nil and err:find("$.x: expected an object or an array, got table with mixed keys", 1, true), text .. ": " .. tostring(err))
  end
end

local function test_get_finds_an_element_past_a_hole_of_a_decoded_array()
  local doc = decoded("[1, null, 3]")
  assert(got(doc, { 3 }) == 3)
  local hole, err = Json.get(doc, { 2 })
  assert(hole == nil and err == "", err)
  assert(get_failure(doc, { 4 }):find("index 4 out of range, the array has 3", 1, true))
  assert(got(decoded("[null, null, 7]"), { 3 }) == 7)
  assert(got(decoded('{"a": [null, {"b": 2}]}'), { "a", 2, "b" }) == 2)
end
