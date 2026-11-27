--- Proves `layout = "fractured"` lays JSON out by FracturedJson's rules:
--- what fits on a line on one, short arrays several elements to a line,
--- rows that are alike in aligned columns, and the rest expanded.

local Json = require("cosmic.json")
local Test = require("cosmic.test")

--- `text` laid out, read as `format` reads it, in lines of `width`.
local function laid(text: string, width?: integer): string
  return assert(Json.format(text, { layout = "fractured", width = width }))
end

local function test_what_fits_is_on_one_line()
  assert(laid('{"a":1,"b":"x"}') == '{"a": 1, "b": "x"}')
  assert(laid('{"a":1,"b":[1,2]}') == '{ "a": 1, "b": [1, 2] }', "a bracket that holds nesting is padded")
  assert(laid('[[1,2],[3]]') == '[ [1, 2], [3] ]')
  assert(laid('{"a":{},"b":[]}') == '{"a": {}, "b": []}', "empty brackets are not")
  assert(laid('"x"') == '"x"' and laid("12.50") == "12.50", "a scalar as written")
  assert(laid('{"a":{"b":{"c":1}}}') == '{\n  "a": { "b": {"c": 1} }\n}', "complexity 3 is not inline")
end

local function test_an_array_of_short_values_is_written_several_to_a_line()
  local numbers: mut {string} = {}
  for i = 1, 30 do numbers[i] = tostring(i * 7) end
  local text = laid("[" .. table.concat(numbers, ",") .. "]", 40)
  assert(text == [=[
[
    7,  14,  21,  28,  35,  42,  49,
   56,  63,  70,  77,  84,  91,  98,
  105, 112, 119, 126, 133, 140, 147,
  154, 161, 168, 175, 182, 189, 196,
  203, 210
]]=], text)
  local words = laid('["ab","c","def","g","hi","jkl"]', 20)
  assert(words == '[\n  "ab",  "c",\n  "def", "g",\n  "hi",  "jkl"\n]', words)
end

local function test_rows_that_are_alike_line_up_in_columns()
  local text = laid('[{"id":1,"name":"ann","score":9.5},{"id":22,"name":"bo","score":10},' ..
      '{"name":"cy","id":3,"score":null}]', 50)
  assert(text == [=[
[
  {"id":  1, "name": "ann", "score":  9.5},
  {"id": 22, "name": "bo",  "score": 10  },
  {"id":  3, "name": "cy",  "score": null}
]]=], text)
end

local function test_a_key_a_row_lacks_leaves_its_column_blank()
  local text = laid('{"p":{"x":1,"y":2},"q":{"x":10},"r":{"y":3,"z":4}}', 40)
  assert(text == [=[
{
  "p": {"x":  1, "y": 2        },
  "q": {"x": 10                },
  "r": {         "y": 3, "z": 4}
}]=], text)
end

local function test_nested_rows_line_up_inside()
  local text = laid('[{"at":[1,2],"c":"red"},{"at":[10,-20.25],"c":"blue"}]', 40)
  assert(text == [=[
[
  { "at": [ 1,   2   ], "c": "red"  },
  { "at": [10, -20.25], "c": "blue" }
]]=], text)
end

local function test_too_wide_a_table_is_expanded()
  local text = laid('[{"name":"aaaaaaaaaa","v":1},{"name":"b","v":2}]', 26)
  assert(text == [=[
[
  {
    "name": "aaaaaaaaaa",
    "v"   : 1
  },
  {"name": "b", "v": 2}
]]=], text)
end

local function test_keys_line_up_unless_far_apart_in_length()
  local long = string.rep("k", 20)
  local text = laid('{"a":{"b":{"c":1}},"' .. long .. '":1}')
  assert(text == '{\n  "a": { "b": {"c": 1} },\n  "' .. long .. '": 1\n}', text)
  local near = laid('{"a":{"b":{"c":1}},"abc":1}')
  assert(near == '{\n  "a"  : { "b": {"c": 1} },\n  "abc": 1\n}', near)
end

local function test_encode_lays_out_and_round_trips()
  local value: Json.Value = { tags = { "x", "y" }, rows = Json.array({ { 1, 2 }, { 3, 4 } }) }
  local text = assert(Json.encode(value, { layout = "fractured" }))
  assert(text == '{\n  "rows": [ [1, 2], [3, 4] ],\n  "tags": ["x", "y"]\n}', text)
  assert(assert(Json.format(text)) == assert(Json.encode(value)), "the same value")
  local wide = assert(Json.encode("\u{e9}\u{e9}\u{e9}", { layout = "fractured", width = 5 }))
  assert(wide == '"\u{e9}\u{e9}\u{e9}"', "a value longer than a line is written whole")
end

local function test_a_width_below_one_raises()
  Test.raises(function() local _, _ = Json.encode(1, { layout = "fractured", width = 0 }) end)
  Test.raises(function() local _, _ = Json.format("1", { width = -1 }) end)
end

local function test_an_empty_row_takes_nothing_from_the_next()
  local text = laid('{"p":{"x":1,"y":2},"q":{},"x":{"x":3,"y":4}}', 30)
  assert(text == [=[
{
  "p": {"x": 1, "y": 2},
  "q": {              },
  "x": {"x": 3, "y": 4}
}]=], text)
end

local function test_a_key_twice_in_a_row_keeps_both_values()
  local text = assert(Json.format('[{"a":1,"a":2},{"a":3,"b":4}]', { duplicate_keys = true, layout = "fractured",
    width = 20 }))
  assert(text == '[\n  {"a": 1, "a": 2},\n  {"a": 3, "b": 4}\n]', text)
end

local function test_a_null_row_wider_than_the_others_keeps_the_columns()
  local text = laid('[[[1],"x"],[null,"y"],[[2],"z"]]', 16)
  assert(text == [=[
[
  [ [1],  "x" ],
  [ null, "y" ],
  [ [2],  "z" ]
]]=], text)
end

local function test_elements_too_wide_to_line_up_are_packed_as_they_are()
  local words: mut {string} = {}
  for i = 1, 12 do table.insert(words, '"w' .. tostring(i) .. '"') end
  table.insert(words, '"' .. string.rep("long", 4) .. '"')
  local text = laid("[" .. table.concat(words, ",") .. "]", 40)
  assert(text == [=[
[
  "w1", "w2", "w3", "w4", "w5", "w6",
  "w7", "w8", "w9", "w10", "w11", "w12",
  "longlonglonglong"
]]=], text)
end
