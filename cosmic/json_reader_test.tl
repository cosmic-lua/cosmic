--- Proves [`Json.reader`] reads JSON text a token at a time as `decode`
--- reads it whole: the same values, however the stream splits the text,
--- the same refusals, placed by line, column and path.

local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")

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

-- ---- JSON5 and `#` comments ----------------------------------------

local JSON5: Json.ReaderOptions = { json5 = true }
local HASH: Json.ReaderOptions = { hash_comments = true }
local BOTH: Json.ReaderOptions = { json5 = true, hash_comments = true }

--- The tokens of `text` as one string, however it is split: every size
--- gives these, or the test fails; the failure that ended them follows a `!`.
local function read_all(text: string, opts: Json.ReaderOptions): string
  local whole, err = tokens(text, nil, opts)
  local line = table.concat(whole, " ") .. "!" .. err
  for size = 1, 7 do
    local got, why = tokens(text, size, opts)
    local split = table.concat(got, " ") .. "!" .. why
    assert(split == line, ("%q in chunks of %d: %s, not %s"):format(text, size, split, line))
  end
  return line
end

--- Each form JSON5 adds to JSON is a token the reader gives as `decode`
--- reads it.
local function test_json5_forms_are_tokens()
  local cases: {{string}} = {
    { "{a: 1, $b_2: 2, \\u0063d: 3, é: 4, true: 5, null: 6, Infinity: 7}",
      "object@ key=a@/a number=1@/a key=$b_2@/$b_2 number=2@/$b_2 key=cd@/cd number=3@/cd " ..
        "key=\u{e9}@/\u{e9} number=4@/\u{e9} key=true@/true number=5@/true key=null@/null number=6@/null " ..
        "key=Infinity@/Infinity number=7@/Infinity end_object@!" },
    { "{'a': 'b', \"c\": 'd'}", "object@ key=a@/a string=b@/a key=c@/c string=d@/c end_object@!" },
    { [['it\'s "q" \x41\u00e9\v\0\z']], "string=it's \"q\" A\u{e9}\v\0z@!" },
    { "'a\\\nb' 'c\\\r\nd' 'e\\\u{2028}f'", "string=ab@ string=cd@ string=ef@!" },
    { "[1,]", "array@ number=1@/0 end_array@!" },
    { "{\"a\": 1,}", "object@ key=a@/a number=1@/a end_object@!" },
    { "[+1, -1, .5, 5., +.5, -.5, 0x1F, -0xff, +0XA, 1e2, 1E+2, 5.e1, .5e1, 0e0]",
      "array@ number=1@/0 number=-1@/1 number=0.5@/2 number=5.0@/3 number=0.5@/4 number=-0.5@/5 " ..
        "number=31@/6 number=-255@/7 number=10@/8 number=100.0@/9 number=100.0@/10 number=50.0@/11 " ..
        "number=5.0@/12 number=0.0@/13 end_array@!" },
    { "[Infinity, -Infinity, +Infinity, inf, -INF, infinity]",
      "array@ number=inf@/0 number=-inf@/1 number=inf@/2 number=inf@/3 number=-inf@/4 number=inf@/5 end_array@!" },
    { "[null, nul]", "array@ null@/0!json: a word JSON has no literal for at line 1, column 8 (pointer \"/1\")" },
    { "\u{feff}[\v1\f,\u{a0}2\u{2028}\u{2029}\u{1680}\u{2000}\u{200a}\u{202f}\u{205f}\u{3000},3]",
      "array@ number=1@/0 number=2@/1 number=3@/2 end_array@!" },
    { "[1 // one\n, /* two\n */ 2 // three", "array@ number=1@/0 number=2@/1!json: the text ends inside an array at line 3, column 15 (pointer \"/1\")" },
    { "{a /* c */ : // d\n 1 /**/ , /***/ }", "object@ key=a@/a number=1@/a end_object@!" },
  }
  for _, case in ipairs(cases) do
    local got = read_all(case[1], JSON5)
    assert(got == case[2], ("%q: %s, not %s"):format(case[1], got, case[2]))
  end
  -- NaN, which prints by platform as `nan` or `-nan`, is a number no
  -- number equals, written any way `decode` reads it.
  for _, text in ipairs({ "NaN", "nan", "+NaN", "-NaN", "nAn" }) do
    local got = assert(Json.reader(Stream.from_string(text), JSON5):next())
    local value = got.value as number
    assert(got.kind == "number" and value ~= value, text)
    assert(Json.reader(Stream.from_string(text), JSON5):peek() == "number", text .. " peeks as a number")
  end
end

--- A value reads as `decode` reads the same text, whatever the form.
local function test_json5_numbers_and_strings_are_what_decode_reads()
  local texts = { "+1", ".5", "5.", "0x1F", "-0x1f", "+0xA", "Infinity", "-Infinity", "1e5", "'a\\x41'",
    "'\\u00e9\\n'", "\"\\'\"", "'\\0\\v\\b'", "'q\\\n'", "'\u{2028}'" }
  for _, text in ipairs(texts) do
    local want = assert(Json.decode(text, { json5 = true }))
    local got = assert(Json.reader(Stream.from_string(text), JSON5):next())
    assert(got.value == want, ("%q: %s, not %s"):format(text, tostring(got.value), tostring(want)))
    assert(math.type(got.value as number) == math.type(want as number))
    local viewed = assert(Json.reader(Stream.from_string(text), JSON5):value())
    assert(viewed == want, "value reads the same")
  end
  local nan = assert(Json.reader(Stream.from_string("NaN"), JSON5):next()).value as number
  assert(nan ~= nan, "NaN is not a number equal to itself")
  local big = assert(Json.reader(Stream.from_string("[0xFFFFFFFFFFFFFFFFFF]"),
    { json5 = true, big_numbers_as_strings = true }))
  assert(assert(big:next()).kind == "array")
  assert(assert(big:next()).value == "0xFFFFFFFFFFFFFFFFFF", "a hex number past 64 bits is its text")
  local _, overflow = tokens("[0xFFFFFFFFFFFFFFFFFF]", nil, JSON5)
  assert(overflow:match("hex number overflow"), overflow)
end

--- JSON5's forms are refused without `json5`, with the reader's own
--- message, as `decode` refuses them.
local function test_json5_forms_are_refused_without_json5()
  for _, text in ipairs({ "'a'", "{a: 1}", "[1,]", "[.5]", "[+1]", "[0x1]", "[Infinity]", "[NaN]", "[1 //c\n]",
      "[1 /*c*/]", "[1]\u{a0}", "[\v1]", "{\"a\": 1,}", "[nan]", "[1] // c" }) do
    local _, err = tokens(text)
    assert(err ~= "", ("%q is read: "):format(text))
    assert(not Json.check(text), ("decode reads %q"):format(text))
  end
  -- The same texts, under json5, are read.
  for _, text in ipairs({ "'a'", "{a: 1}", "[1,]", "[.5]", "[+1]", "[0x1]", "[Infinity]", "[NaN]", "[1 //c\n]",
      "[1 /*c*/]", "[1]\u{a0}", "[\v1]", "{\"a\": 1,}", "[nan]", "[1] // c" }) do
    local _, err = tokens(text, nil, JSON5)
    assert(err == "", ("%q: %s"):format(text, err))
  end
end

--- What `decode` refuses under `json5` the reader refuses, in any chunks.
local function test_json5_refusals_agree_with_decode()
  local texts = { "[,]", "[1,,]", "{,}", "{a:1,,}", "{1a:1}", "{a b:1}", "{a}", "{a:}", "{:1}", "{\\x41:1}",
    "[1_0]", "[0x]", "[01]", "[1.5.5]", "[+]", "[.]", "[1e]", "[1e+]", "['a\nb']", "[\"\\01\"]", "[\"\\xZZ\"]",
    "['a\\\tb']", "[tru]", "[1 true]", "[1true]", "[0x1.5]", "[1 2]", "[1/ 2]", "[1 /x]", "[/*/ 1]", "[1/*c",
    "[1 /", "[Infinit]", "{'a'}", "{'a': 1 'b': 2}", "[1\u{200b}]", "['a", "{a\u{a0}b: 1}", "[nul]", "[na]",
    "{\"a\": 1, \"a\": 2}", "[-0x]", "[- 1]", "{a: 1, a: 2}", "{a: 1, 'a': 2}", "[0xFFFFFFFFFFFFFFFFF]" }
  for _, text in ipairs(texts) do
    assert(not Json.check(text, { json5 = true }), ("decode reads %q"):format(text))
    for _, size in ipairs({ 1, 3, 100 }) do
      local got, err = tokens(text, size, JSON5)
      assert(err ~= "", ("%q in chunks of %d is read as %s"):format(text, size, table.concat(got, " ")))
    end
  end
  -- A failure that is decode's own reads as decode says it, placed.
  for _, text in ipairs({ "{\\x41:1}", "{a\\x: 1}", "\n\n  [0x]", "['a\\\n\\xZZ']", "[1,\n  {a\\u00zz: 1}]" }) do
    local _, want = Json.decode(text, { json5 = true })
    local _, got = tokens(text, 2, JSON5)
    assert(got == want, ("%q: %s, not %s"):format(text, got, want))
  end
end

--- `hash_comments` reads a `#` comment to the end of its line without
--- `json5` too, ending at \n or \r and not at U+2028; `//` is still no comment.
local function test_hash_comments_read_as_decode_reads_them()
  assert(read_all("# lead\n[1, # one\r2,#\n3] # end", HASH) ==
      "array@ number=1@/0 number=2@/1 number=3@/2 end_array@!")
  assert(read_all('{#c\n"a"#c\n:#c\n1#c\n}#c', HASH) == "object@ key=a@/a number=1@/a end_object@!")
  assert(read_all('["#", "# x", \'#\']', BOTH) == "array@ string=#@/0 string=# x@/1 string=#@/2 end_array@!")
  assert(read_all("[true#c\n,null#c\n,1#c\n]", HASH) == "array@ boolean=true@/0 null@/1 number=1@/2 end_array@!")
  assert(read_all("# only", HASH) == "!", "a comment is no token")
  -- Outside JSON5 the comment runs on past U+2028, which counts no line.
  assert(read_all("[1, # c\u{2028} 2,\n3]", HASH) == "array@ number=1@/0 number=3@/1 end_array@!")
  assert(read_all("[1, # c\u{2028} 2,\n3]", BOTH) == "array@ number=1@/0 number=2@/1 number=3@/2 end_array@!")
  local _, plain = tokens("[1] # c")
  assert(plain:match("^json: a byte no JSON token starts with"), "# is no comment unless asked for")
  local _, slashes = tokens("[1] // c", nil, HASH)
  assert(slashes:match("^json: a byte no JSON token starts with"), "nor is //, without json5")
  local _, block = tokens("[1 /* c */]", nil, HASH)
  assert(block ~= "", "nor /* */")
  local _, glued = tokens("[1#c\n]", nil, { hash_comments = false, json5 = true })
  assert(glued ~= "", "json5 alone reads no # comment")
  assert(Json.decode("[1,#c\r2]", { hash_comments = true }) ~= nil, "decode ends it at \\r")
end

--- A comment, a `\u{2028}` or a `*/` the stream splits mid-way reads as
--- one that arrives whole, and costs no extra pass over what came before.
local function test_a_comment_split_across_chunks()
  local texts = {
    "[1, /* a * b ** c */ 2]", "[1, /***/ 2]", "[1, /**/ 2]", "[1, /*/ */ 2]", "[1,//c\n2]", "[1,//c\r\n2]",
    "[1,//c\u{2028}2]", "[1,//c\u{2029}2]", "[1,/*\u{2028}*/\n2]", "[1,#c\u{2028}2]", "[1, //\u{2028}\u{2028}\n 2]",
    "// head\n{\"a\": /* ] */ 1, // }\n \"b\": '/*', 'c': \"//\"} // end", "[1 /* \xe2\x80 */ ]", "[1, // \xe2\x80\n 2]", "[1, # \xe2\n 2]",
    "[1,\u{2028}\u{2029}\u{a0}\u{feff}\u{3000}2]", "{ab\u{2028}: 1, cd /*x*/ \u{a0}: 2 \u{3000}}",
  }
  for _, text in ipairs(texts) do
    local want = read_all(text, BOTH)
    local one = tokens(text, nil, BOTH)
    assert(table.concat(one, " ") .. "!" == want, ("%q: %s"):format(text, want))
  end
  -- Each way of ending the text inside a comment fails as a text that
  -- ends inside an array does, whether the stream ends there or after.
  for _, text in ipairs({ "[1 /*", "[1 /* *", "[1 /* x *", "[1 // x" }) do
    local _, err = tokens(text, 1, JSON5)
    assert(err:match("^json: the text ends inside "), err)
  end
  local _, unterminated = tokens("[1 /* x *", 1, JSON5)
  assert(unterminated == "json: the text ends inside a comment at line 1, column 10 (pointer \"/0\")", unterminated)
end

--- Under `json5` a U+2028 or U+2029 ends a line, in whitespace, a
--- comment or a string, as `decode` counts them -- and not otherwise;
--- a stream that splits the three bytes counts them the same.
local function test_json5_line_ends_count_as_decode_counts_them()
  for _, eol in ipairs({ "\u{2028}", "\u{2029}" }) do
    local cases: {{string}} = {
      { "[1," .. eol .. eol .. "  x]" },
      { "[1, // c" .. eol .. " x]" },
      { "[1, /* a" .. eol .. "b" .. eol .. "*/ x]" },
      { "['a" .. eol .. "b', x]" },
      { "{'a" .. eol .. "': 1, x}" },
      { "[1, \\" .. eol .. " 'x" .. eol .. "', y" .. eol .. "x]" },
      { "[1, # c" .. eol .. " x]" },
    }
    for _, case in ipairs(cases) do
      local text = case[1]
      -- `decode` reads each text to its `x` and fails there: its line and
      -- column are the ones the reader names.
      local _, want = Json.decode(text, { json5 = true, hash_comments = true })
      local line, column = want:match("at line (%d+), column (%d+)")
      for _, size in ipairs({ 1, 2, 3, 100 }) do
        local _, got = tokens(text, size, BOTH)
        local at = ("at line %s, column %s"):format(line, column)
        assert(got:find(at, 1, true), ("%q in chunks of %d: %s, wanted %s"):format(text, size, got, at))
      end
    end
    -- Without json5 neither is a line end: the column counts its bytes.
    local _, strict = tokens('["' .. eol .. '", x]')
    assert(strict:find("at line 1, column 9 ", 1, true), strict)
    local _, hashed = tokens("[1, # c" .. eol .. "\n x]", nil, HASH)
    assert(hashed:find("at line 2, column 2 ", 1, true), hashed)
  end
  -- A failure after a value read whole counts the lines it held.
  local r = Json.reader(chunked("[/* a\u{2028} */ {'k': 'v\u{2029}'}, // x\u{2028}\n  x]", 2), JSON5)
  assert(assert(r:next()).kind == "array" and r:value() ~= nil)
  local _, err = r:next()
  assert(err == "json: expected a value at line 5, column 3 (pointer \"/0\")", err)
end

--- `value` reads a whole array or object with comments and JSON5 in it
--- as `decode` reads it, whatever brackets and quotes its comments hold.
local function test_value_reads_json5_and_comments()
  local text = "{/* ] */ rows: [ // }\n  {id: 1, 'name': 'a}', tags: [0x1F, .5,],}, # ]\n  {id: 2,},\n ], // \"\n n: 3}"
  local want = assert(Json.decode(text, { json5 = true, hash_comments = true, null_value = Json.null }))
  for _, size in ipairs({ 1, 2, 5, 1000 }) do
    local r = Json.reader(chunked(text, size), { json5 = true, hash_comments = true, null_value = Json.null })
    assert(assert(r:next()).kind == "object" and assert(r:next()).value == "rows")
    assert(r:peek() == "array")
    local rows = assert(r:value()) as {{string: any}}
    local whole = want as {string: any}
    assert(#rows == 2 and rows[1].id == 1 and rows[1].name == "a}" and rows[2].id == 2 and whole.n == 3)
    assert(assert(r:next()).value == "n" and r:value() == 3)
    assert(assert(r:next()).kind == "end_object")
    local done, err = r:next()
    assert(done == nil and err == "", err)
  end
  local r = Json.reader(Stream.from_string("// lead\n[1, /* c\n */ {'a': 1, 'a': 2}]"), JSON5)
  assert(assert(r:next()).kind == "array" and r:value() == 1)
  local _, dup = r:value()
  assert(dup == "json: duplicate key at line 3, column 14 (pointer \"/1/a\")", dup)
  -- Without the options the same comment is a refusal, by value too.
  local plain = Json.reader(Stream.from_string("[[1, /* ] */ 2]]"))
  assert(assert(plain:next()).kind == "array")
  local _, refused = plain:value()
  assert(refused:match("^json: invalid JSON at line 1, column 6: "), refused)
end

--- A trailing comma is read only under json5, and only before a close.
local function test_a_trailing_comma_needs_json5_and_a_close()
  local _, strict = tokens("[1,]")
  assert(strict == "json: a trailing `,` at line 1, column 4 (pointer \"/0\")", strict)
  local _, object = tokens('{"a": 1,}')
  assert(object:match("^json: a trailing `,`"), object)
  for _, text in ipairs({ "[,]", "[1,,]", "{,}", '{"a": 1,,}', '{"a":,}', "[,1]" }) do
    local _, err = tokens(text, nil, JSON5)
    assert(err ~= "", text)
  end
end

--- A long comment, or a `*` or a lead byte at every chunk's end, in
--- one-byte chunks, costs time in proportion to its length.
local function test_a_long_comment_in_small_chunks_reads_in_linear_time()
  local long = string.rep("*", 150000)
  for _, text in ipairs({
      "[1, /*" .. long .. "*/ 2]", "[1, //" .. long .. "\n 2]", "[1, #" .. long .. "\n 2]",
      "[1, //" .. string.rep("\xe2\x80", 50000) .. "\n 2]", "[1, /* " .. string.rep("/* ", 75000) .. "*/ 2]",
      "[1," .. string.rep(" \u{a0}", 50000) .. "2]", "{" .. string.rep("\u{e9}", 50000) .. ": 1}",
  }) do
    for _, size in ipairs({ 1, 2 }) do
      local got, err = tokens(text, size, BOTH)
      assert(err == "", err)
      assert(#got >= 4)
    end
  end
  -- Many short line comments in one chunk, or a few: each costs its own length.
  for _, size in ipairs({ 1000000, 65536, 100 }) do
    for _, comment in ipairs({ "// c\n", "# c\n", "// c\u{2028}", "// \xe2\x80\n" }) do
      local many = "[" .. string.rep("1, " .. comment, 50000) .. "2]"
      local started = Time.now_ns()
      local got, err = tokens(many, size, BOTH)
      assert(err == "" and #got == 50003, err)
      -- Linear takes a fraction of a second; a scan of the rest of the
      -- chunk for each comment takes a minute.
      assert(Time.now_ns() - started < Time.seconds(10), "many short comments take linear time")
    end
  end
  local text = "[" .. string.rep("1, /* c */ ", 20000) .. "2]"
  local r = Json.reader(chunked("[" .. text .. "]", 1), JSON5)
  assert(assert(r:next()).kind == "array" and #(assert(r:value()) as {integer}) == 20001)
end

--- yyjson reads JSON5's extra whitespace right after an object's `{` or
--- `,` as the start of a key, and refuses the object: the reader does,
--- where `decode` says, but not after a comment, nor elsewhere.
local function test_extended_whitespace_where_an_object_key_starts_is_refused()
  for _, space in ipairs({ "\u{a0}", "\u{2028}", "\u{2029}", "\u{feff}", "\u{3000}", "\u{1680}", "\u{2000}",
      "\u{200a}", "\u{202f}", "\u{205f}", " \u{a0}", "\n\u{a0}" }) do
    for _, shape in ipairs({ "{%sa:1}", "{%s'a':1}", '{%s"a":1}', "{a:1,%sb:2}", "{%s}", "{a:1,%s}",
        "{a:1,%s'b':2}", '{%s/**/"a":1}', "[{%sa:1}]" }) do
      local text = shape:format(space)
      local _, want = Json.decode(text, { json5 = true })
      assert(want ~= "", ("decode reads %q"):format(text))
      local line, column = want:match("at line (%d+), column (%d+)")
      for _, size in ipairs({ 1, 2, 3, 100 }) do
        local _, got = tokens(text, size, JSON5)
        assert(got:find(("at line %s, column %s "):format(line, column), 1, true),
          ("%q in chunks of %d: %s, decode %s"):format(text, size, got, want))
        -- However often a caller peeks before it reads, it is the same.
        for _, peeks in ipairs({ 1, 2 }) do
          local r = Json.reader(chunked(text, size), JSON5)
          local failure = ""
          while true do
            for _ = 1, peeks do r:peek() end
            local t, err = r:next()
            if t == nil then
              failure = err
              break
            end
          end
          assert(failure == got, ("%q peeking %d times: %s, not %s"):format(text, peeks, failure, got))
        end
      end
    end
  end
  -- Read with a peek before each token, an empty key and a refusal stand.
  for _, text in ipairs({ "{a:1,\u{a0}:2}", "{\u{a0}:2}" }) do
    local r = Json.reader(Stream.from_string(text), JSON5)
    local kinds: {string} = {}
    while r:peek() ~= nil do kinds[#kinds + 1] = assert(r:next()).kind end
    assert(#kinds >= 4 and assert(Json.decode(text, { json5 = true })), text)
  end
  -- Whitespace after a comment, or anywhere else, is read.
  for _, text in ipairs({ "{/**/\u{a0}a:1}", "{a:1,// c\n\u{a0}b:2}", "{a\u{a0}:\u{a0}1\u{a0}, 'b':2\u{a0}}",
      "{\u{a0}:1}", "[\u{a0}1,\u{a0}2]" }) do
    local decoded, why = Json.decode(text, { json5 = true })
    assert(decoded ~= nil, why)
    local _, err = tokens(text, 2, JSON5)
    assert(err == "", ("%q: %s"):format(text, err))
  end
  -- yyjson reads the whitespace at a key as an empty key: `{<space>:1}`.
  local got = tokens("{\u{a0}:1}", nil, JSON5)
  assert(table.concat(got, " ") == "object@ key=@/ number=1@/ end_object@", table.concat(got, " "))
end

--- A word or number cut short is refused where it starts, as `decode`
--- places it, in chunks however small.
local function test_a_truncated_word_is_placed_where_it_starts()
  for _, text in ipairs({ "[na]", "[I]", "[in]", "[infi]", "[Infin]", "[Infinit]", "[+n]", "[-I]", "[-N]", "[nul]",
      "[1e]", "[0x]", "[+]", "[-]", "[.]" }) do
    local _, want = Json.decode(text, { json5 = true })
    for _, size in ipairs({ 1, 100 }) do
      local _, got = tokens(text, size, JSON5)
      local line, column = want:match("at line (%d+), column (%d+)")
      assert(got:find(("at line %s, column %s"):format(line, column), 1, true),
        ("%q in chunks of %d: %s, decode %s"):format(text, size, got, want))
    end
  end
end

--- An `n` that ends a chunk waits for the byte after it, through empty
--- chunks, to tell `nan` from `null`.
local function test_an_n_waits_for_its_next_byte()
  local chunks = { "[", "n", "", "", "an", "]" }
  local at = 0
  local source: Stream.Reader = {
    read = function(_self: Stream.Reader, _max?: integer): string | nil, string
      at = at + 1
      return chunks[at], ""
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
  local r = Json.reader(source, JSON5)
  assert(assert(r:next()).kind == "array")
  assert(r:peek() == "number", "nan is a number")
end

--- A number that stops early inside an array or object is refused in
--- the container's own words, as `decode` says it, not as a second document.
local function test_a_token_that_stops_early_inside_a_container()
  for _, text in ipairs({ "[1.5.5, +]", "{a: [0x1.5, 1_0]}", "{a: 1.5.5}" }) do
    local _, want = Json.decode(text, { json5 = true })
    local _, got = tokens(text, 2, JSON5)
    assert(want:find("expected ',' or", 1, true) and got == want, ("%q: %s, decode %s"):format(text, got, want))
  end
end
