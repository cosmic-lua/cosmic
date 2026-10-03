--- Proves [`Json.reader`] reads JSON text a token at a time as `decode`
--- reads it whole: the same values, however the stream splits the text,
--- the same refusals, placed by line, column and path.

local Json = require("cosmic.json")
local Stream = require("cosmic.stream")

--- A Reader that answers `text` in chunks of `size` bytes, then `last`
--- (nil for the end) on every read after.
local record Chunked is Stream.Reader
  text: string
  at: integer
  size: integer
  last: string
  read: function(Chunked, max_bytes?: integer): string | nil, string
  close: function(Chunked): boolean, string
end

local chunked_mt: metatable<Chunked> = { __index = Chunked }

function Chunked:read(_max_bytes?: integer): string | nil, string
  if self.at > #self.text then return nil, self.last end
  local chunk = self.text:sub(self.at, self.at + self.size - 1)
  self.at = self.at + self.size
  return chunk, ""
end

function Chunked:close(): boolean, string
  return true, ""
end

local function chunked(text: string, size: integer, last?: string): Stream.Reader
  local r: Chunked = setmetatable({ text = text, at = 1, size = size, last = last or "" }, chunked_mt)
  return r
end

--- Every token of `text`, read `size` bytes at a time, as `kind=value@path`,
--- and the failure that ended them, or "".
local function tokens(text: string, size?: integer, opts?: Json.ReaderOptions): {string}, string
  local r = Json.reader(chunked(text, size or #text + 1), opts)
  local out: {string} = {}
  while true do
    local t, err = r:next()
    if t == nil then return out, err end
    local value = t.value
    out[#out + 1] = t.kind .. (value ~= nil and "=" .. tostring(value) or "") .. "@" .. assert(Json.pointer(r:steps()))
  end
end

local DOCUMENT <const> = '{"rows": [{"id": 1}, {"id": 2.5, "x": "\\u00e9\\n"}],\r\n "ok": true, "n": null, ' ..
  '"a b": [[], {}], "big": -12e-3}'

local function test_tokens_and_paths()
  local got, err = tokens(DOCUMENT)
  assert(err == "", err)
  assert(table.concat(got, " ") == table.concat({
    "object@", "key=rows@/rows", "array@/rows", "object@/rows/0", "key=id@/rows/0/id",
    "number=1@/rows/0/id", "end_object@/rows/0", "object@/rows/1", "key=id@/rows/1/id",
    "number=2.5@/rows/1/id", "key=x@/rows/1/x", "string=\u{e9}\n@/rows/1/x", "end_object@/rows/1",
    "end_array@/rows", "key=ok@/ok", "boolean=true@/ok", "key=n@/n", "null@/n",
    'key=a b@/a b', 'array@/a b', 'array@/a b/0', 'end_array@/a b/0',
    'object@/a b/1', 'end_object@/a b/1', 'end_array@/a b', "key=big@/big",
    "number=-0.012@/big", "end_object@",
  }, " "), table.concat(got, " "))
end

--- However the stream splits the text -- inside a string, an escape, a
--- number, a literal or a \r\n -- the tokens are the same.
local function test_any_split_reads_the_same()
  local whole = table.concat(tokens(DOCUMENT), " ")
  for size = 1, 7 do
    local got, err = tokens(DOCUMENT, size)
    assert(err == "", err)
    assert(table.concat(got, " ") == whole, size .. ": " .. table.concat(got, " "))
  end
end

local function test_a_stream_of_values()
  local got, err = tokens('1 "two"\n[3]{"four": 4}null', 2)
  assert(err == "", err)
  assert(table.concat(got, " ") == 'number=1@ string=two@ array@ number=3@/0 end_array@ ' ..
      "object@ key=four@/four number=4@/four end_object@ null@", table.concat(got, " "))
  local none, quiet = tokens(" \n\t ")
  assert(#none == 0 and quiet == "", "only whitespace holds no token")
  local empty, nothing = tokens("")
  assert(#empty == 0 and nothing == "", "nor does nothing")
end

--- Each refusal names where the text stopped being JSON, and every call
--- after answers it again.
local function test_refusals_name_where()
  local cases: {{string}} = {
    { "[1, 2,]", "json: a trailing `,` at line 1, column 7 (pointer \"/1\")" },
    { "[1 2]", "json: expected `,` or `]` at line 1, column 4 (pointer \"/0\")" },
    { '{"a" 1}', "json: expected `:` after a key at line 1, column 6 (pointer \"/a\")" },
    { "[1}", "json: expected `,` or `]` at line 1, column 3 (pointer \"/0\")" },
    { "[}", "json: a close that does not match its open at line 1, column 2 (pointer \"\")" },
    { "]", "json: a close with nothing open at line 1, column 1 (pointer \"\")" },
    { "{1: 2}", "json: expected a key at line 1, column 2 (pointer \"\")" },
    { '{"a": 1', "json: the text ends inside an object at line 1, column 8 (pointer \"/a\")" },
    { '{"a"', "json: the text ends before a key's `:` at line 1, column 5 (pointer \"/a\")" },
    { "[tru]", "json: a word JSON has no literal for at line 1, column 2 (pointer \"/0\")" },
    { "[@]", "json: expected a value at line 1, column 2 (pointer \"\")" },
    { "@", "json: a byte no JSON token starts with at line 1, column 1 (pointer \"\")" },
    { '["abc', "json: a string the text ends inside at line 1, column 2 (pointer \"/0\")" },
    { '{"a": 1, "a": 2}', "json: duplicate key at line 1, column 10 (pointer \"/a\")" },
    { "\n\n  [01]", "json: invalid JSON at line 3, column 4: number with leading zero is not allowed" },
    { '[\r\n "x\\q"]', "json: invalid JSON at line 2, column 4: invalid escaped sequence in string" },
  }
  for _, case in ipairs(cases) do
    for _, size in ipairs({ 1, 3, 100 }) do
      local _, err = tokens(case[1], size)
      assert(err == case[2], case[1] .. " in chunks of " .. size .. ": " .. err)
    end
  end
  local r = Json.reader(Stream.from_string("[1,]"))
  assert(assert(r:next()).kind == "array" and assert(r:next()).value == 1)
  local _, first = r:next()
  local _, again = r:next()
  local _, peeked = r:peek()
  assert(first ~= "" and again == first and peeked == first, "a failure answers again")
end

local function test_options_mean_what_they_mean_to_decode()
  local got, err = tokens('{"a": 1, "a": 2}', nil, { duplicate_keys = true })
  assert(err == "" and got[#got - 1] == "number=2@/a", err)
  local _, deep = tokens("[[[1]]]", nil, { max_depth = 2 })
  assert(deep == "json: JSON nests deeper than 2 levels at line 1, column 3 (pointer \"/0/0\")", deep)
  local ok = tokens("[[1]]", nil, { max_depth = 2 })
  assert(#ok == 5, "two levels read under a limit of two")
  local big = tokens("18446744073709551616", nil, { big_numbers_as_strings = true })
  assert(big[1] == "number=18446744073709551616@", big[1])
  local lone = tokens('"\\ud800"', nil, { lone_surrogates = true })
  assert(lone[1] == "string=\u{fffd}@", lone[1])
  local _, refused = tokens('"\\ud800"')
  assert(refused:match("surrogate"), refused)
  assert(not pcall(Json.reader, Stream.from_string("1"), { max_depth = 0 }), "a depth below 1 raises")
end

--- `value` decodes one whole value, a part of a stream too large to
--- decode at once, as `decode` would decode it.
local function test_value_reads_one_whole_value()
  local text = '{"rows": [\n  {"id": 1, "tags": ["a"]},\n  {"id": 2, "tags": []},\n  null\n], "after": 3}'
  for _, size in ipairs({ 1, 4, 1000 }) do
    local r = Json.reader(chunked(text, size), { null_value = Json.null })
    assert(assert(r:next()).kind == "object" and assert(r:next()).value == "rows")
    assert(assert(r:next()).kind == "array")
    local ids: {integer} = {}
    while r:peek() == "object" do
      local row = assert(r:value()) as {string: any}
      ids[#ids + 1] = row.id as integer
      assert(Json.is_array(row.tags), "an array decodes marked, as decode marks one")
    end
    assert(r:peek() == "null" and r:value() == Json.null, "null_value stands in")
    assert(#ids == 2 and ids[1] == 1 and ids[2] == 2)
    assert(assert(r:next()).kind == "end_array" and Json.pointer(r:steps()) == "/rows")
    assert(assert(r:next()).value == "after" and r:value() == 3)
    assert(assert(r:next()).kind == "end_object")
    local done, err = r:next()
    assert(done == nil and err == "", err)
    assert(r:offset() == #text, "every byte read past")
  end
end

local function test_value_refusals_are_placed_in_the_stream()
  local r = Json.reader(Stream.from_string('[\n {"a": 1},\n {"a": 1, "a": 2}]'))
  assert(assert(r:next()).kind == "array" and r:value() ~= nil)
  local _, err = r:value()
  assert(err == "json: duplicate key at line 3, column 11 (pointer \"/1/a\")", err)
  local deep = Json.reader(Stream.from_string('[{"a": [1, {"b": [[[1]]]}]}]'), { max_depth = 4 })
  assert(assert(deep:next()).kind == "array")
  local _, too_deep = deep:value()
  assert(too_deep == "json: JSON nests deeper than 4 levels at line 1, column 18 (pointer \"/0/a/1/b\")", too_deep)
  local syntax = Json.reader(Stream.from_string('[1,\n  {"a": [1,]}]'))
  assert(assert(syntax:next()).kind == "array" and syntax:value() == 1)
  local _, bad = syntax:value()
  assert(bad:match("^json: invalid JSON at line 2, column %d+: "), bad)
  local at_key = Json.reader(Stream.from_string('{"a": 1}'))
  assert(assert(at_key:next()).kind == "object")
  local _, key = at_key:value()
  assert(key == "json: expected a value at line 1, column 2 (pointer \"\")", key)
  local spent = Json.reader(Stream.from_string(""))
  local _, ended = spent:value()
  assert(ended == "json: no value: the stream has ended", ended)
  -- After a value that spans lines, a refusal counts the lines it held.
  local after = Json.reader(Stream.from_string('[{"a":\n\n1}, x]'))
  assert(assert(after:next()).kind == "array" and after:value() ~= nil)
  local _, x = after:next()
  assert(x == "json: expected a value at line 3, column 5 (pointer \"/0\")", x)
end

local function test_a_failing_stream_fails_the_reader()
  local r = Json.reader(chunked("[1, 2", 2, "disk on fire"))
  local got: {string} = {}
  local err: string
  while true do
    local t, why = r:next()
    if t == nil then
      err = why
      break
    end
    got[#got + 1] = t.kind
  end
  assert(err == "json: disk on fire", err)
  assert(select(2, r:next()) == err, "and answers it again")
end

--- A \r passed as part of whitespace joins a \n right after it into one
--- line end, and only then: a token between them leaves two.
local function test_a_carriage_return_joins_only_the_newline_after_it()
  for _, case in ipairs({ { "[1\r,\nx]", 3, 1 }, { "1\r2\n x", 3, 2 }, { "[1\r\n,x]", 2, 2 } }) do
    local text, line, column = case[1] as string, case[2] as integer, case[3] as integer
    for _, size in ipairs({ 1, 2, 100 }) do
      local _, err = tokens(text, size)
      local at = ("at line %d, column %d "):format(line, column)
      assert(err:find(at, 1, true), ("%q in chunks of %d: %s"):format(text, size, err))
    end
  end
  local _, twice = tokens('{"a":1\r,\n"a":2}')
  assert(twice == "json: duplicate key at line 3, column 1 (pointer \"/a\")", twice)
  local r = Json.reader(Stream.from_string('[1\r,\n{"a":1,"a":2}]'))
  assert(assert(r:next()).kind == "array" and r:value() == 1)
  local _, inside = r:value()
  assert(inside == "json: duplicate key at line 3, column 8 (pointer \"/1/a\")", inside)
end

local function test_what_follows_a_number_or_word_must_end_it()
  for _, text in ipairs({ "1true", "true1", "[1x]", "null-1" }) do
    local _, err = tokens(text)
    assert(err:match("^json: expected whitespace, `,` or a close after a "), text .. ": " .. err)
  end
  local got, err = tokens('1 true\n""""[2]')
  assert(err == "" and #got == 7, table.concat(got, " ") .. err)
  local _, missing = tokens('{"a":}')
  assert(missing == "json: expected a value at line 1, column 6 (pointer \"/a\")", missing)
  local _, doubled = tokens("[1,,2]")
  assert(doubled == "json: expected a value at line 1, column 4 (pointer \"/0\")", doubled)
end

--- After a failure the offset stays where the reader stopped, however
--- the stream was split.
local function test_the_offset_stays_where_it_failed()
  local text = '[\r\n{"a":\r\n[1,\r\n2]}\r\n, x]'
  local offsets: {integer: boolean} = {}
  for size = 1, 8 do
    local r = Json.reader(chunked(text, size))
    while r:next() ~= nil do end
    offsets[r:offset()] = true
  end
  local count = 0
  for _ in pairs(offsets) do count = count + 1 end
  assert(count == 1, "one offset however it was split")
  for _, cut in ipairs({ '["\\', '["\\u12', '["ab' }) do
    for size = 1, 3 do
      local r = Json.reader(chunked(cut, size))
      while r:next() ~= nil do end
      assert(r:offset() == #cut, ("%q in chunks of %d: %d"):format(cut, size, r:offset()))
    end
  end
end

--- A key's segment is spelled as the core spells one, so a path the
--- reader builds and one `value` builds read alike.
local function test_paths_spell_keys_as_decode_does()
  local long = string.rep("k", 60)
  for _, key in ipairs({ "\u{e9}", "a\\u0001", "a b", long }) do
    local text = ('{"%s": 1, "%s": 2}'):format(key, key)
    local _, by_tokens = tokens(text)
    local _, by_decode = Json.decode(text)
    assert(by_tokens == by_decode, by_tokens .. " vs " .. by_decode)
  end
end

--- A token however long, in chunks however small, costs time in
--- proportion to its length.
local function test_a_long_token_in_small_chunks_reads_in_linear_time()
  local long = string.rep("x", 200000)
  local got, err = tokens('["' .. long .. '", ' .. "0." .. string.rep("7", 100000) .. "]", 1)
  assert(err == "" and #got == 4, err)
  assert(#got[2] == #"string=@/0" + #long)
  local r = Json.reader(chunked('[{"a": "' .. long .. '"}]', 3))
  assert(assert(r:next()).kind == "array")
  local value = assert(r:value()) as {string: string}
  assert(value.a == long)
end

--- A failure inside `value`, under a place too long for a message, is
--- named as `decode` names it in the whole text: the reader's steps and
--- the core's path shortened as one pointer.
local function test_a_value_failure_under_a_long_place_reads_as_decode_names_it()
  local key = string.rep("k", 60)
  local text = ('{"%s": {"%s": {"%s": {"%s": [{"a": 1, "a": 2}]}}}}'):format(key, key, key, key)
  local r = Json.reader(Stream.from_string(text))
  for _ = 1, 4 do
    assert(assert(r:next()).kind == "object" and assert(r:next()).value == key)
  end
  local _, err = r:value()
  local _, whole = Json.decode(text)
  assert(err == whole and err:find('pointer ending "', 1, true), err .. " vs " .. whole)
end
