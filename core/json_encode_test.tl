--- The options core/json.c's encoder keeps that [`cosmic.json`] does not
--- pass on: unsorted keys, an indent of the caller's, NaN and holes
--- written as `null`, and `\u` escapes past ASCII. They are reached
--- through [`build.json_raw`], the raw table's `encode`.

local Json = require("cosmic.json")
local json_raw = require("build.json_raw")

local function encoded(value: any, opts?: json_raw.Options): string
  local text, err = json_raw.encode(value, opts)
  assert(text ~= nil, "encode failed: " .. err)
  assert(err == "", "a success carries \"\" in the error slot")
  return text
end

local function encode_failure(value: any, opts?: json_raw.Options): string
  local text, err = json_raw.encode(value, opts)
  assert(text == nil and err ~= "", "expected encode to fail, got " .. tostring(text))
  return err
end

local function test_nan_as_null_writes_null_for_nan_and_the_infinities()
  assert(encode_failure(0 / 0) == "cannot encode NaN", "NaN")
  assert(encoded({ 0 / 0, math.huge, -math.huge }, { nan_as_null = true }) == "[null,null,null]")
end

local function test_sparse_as_null_writes_a_hole_as_null()
  local holed = assert(Json.decode("[1, null, 3]")) as {any}
  assert(encode_failure(holed) == "cannot encode an array with a hole (index 2 is nil)",
    "a hole is an error by default")
  assert(encoded(holed, { sparse_as_null = true }) == "[1,null,3]", "sparse_as_null writes it")
  assert(encode_failure({ [100] = 1 } as {any: any}, { sparse_as_null = true }) ==
    "cannot encode an array this sparse: its highest index is 100, and only 1 of its slots hold a value",
    "too sparse to mean")
  assert(encoded({ [3] = 1 } as {any: any}, { sparse_as_null = true }) == "[null,null,1]",
    "a few holes are written")
end

local function test_indent_is_one_level_of_a_pretty_layout()
  assert(encoded({ 1 }, { pretty = true, indent = "\t" }) == "[\n\t1\n]", "a tab")
  local ok, why = pcall(json_raw.encode, 1, { pretty = true, indent = "x" })
  assert(not ok and tostring(why):match("indent must be spaces and tabs"), tostring(why))
end

local function test_unsorted_keeps_every_member()
  local t: {string: integer} = {}
  for i = 1, 50 do t["k" .. i] = i end
  local back = assert(Json.decode(encoded(t, { sorted = false }))) as {string: integer}
  for i = 1, 50 do
    assert(back["k" .. i] == i, "member k" .. i)
  end
  assert(encoded({}, { sorted = false }) == "{}", "empty")
  assert(encode_failure({ a = print }, { sorted = false }) == "cannot encode a function at $.a",
    "a failure")
end

--- `ascii` writes every character past ASCII as a \u escape -- U+2028
--- and U+2029 among them -- a surrogate pair past U+FFFF, in keys as in
--- values, and the text reads back to the same string.
local function test_ascii_escapes_every_character_past_ascii()
  local s = "é\u{2028}x\u{2029}\u{1F600}\u{FFFF}\u{80}\u{7FF}\u{800}\u{10FFFF}"
  local text = encoded({ [s] = s }, { ascii = true })
  local escaped = '"\\u00e9\\u2028x\\u2029\\ud83d\\ude00\\uffff\\u0080\\u07ff\\u0800\\udbff\\udfff"'
  assert(text == "{" .. escaped .. ":" .. escaped .. "}", text)
  assert(not text:find("[\128-\255]"), "a byte past ASCII was written")
  local back = assert(Json.decode(text)) as {string: string}
  assert(back[s] == s, "it does not read back")
  assert(encoded(s) == '"' .. s .. '"', "without ascii the text is as it was")
end
