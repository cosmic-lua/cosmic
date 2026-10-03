--- Fuzz properties for [`Json.reader`]: on any text, however the stream
--- splits it, the reader reads the same tokens and fails the same way,
--- never raising; and it agrees with `decode`, reading one whole value
--- exactly when `decode` reads the text, and the same value, by tokens
--- and by `value` alike, and counting lines and columns as it does --
--- under every combination of `json5` and `hash_comments`, which both
--- are told. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")

--- A Reader that answers `text` in chunks of `size` bytes.
local record Chunked is Stream.Reader
  text: string
  at: integer
  size: integer
  read: function(Chunked, max_bytes?: integer): string | nil, string
  close: function(Chunked): boolean, string
end

local chunked_mt: metatable<Chunked> = { __index = Chunked }

function Chunked:read(_max_bytes?: integer): string | nil, string
  if self.at > #self.text then return nil, "" end
  local chunk = self.text:sub(self.at, self.at + self.size - 1)
  self.at = self.at + self.size
  return chunk, ""
end

function Chunked:close(): boolean, string
  return true, ""
end

local function chunked(text: string, size: integer): Stream.Reader
  local r: Chunked = setmetatable({ text = text, at = 1, size = size }, chunked_mt)
  return r
end

--- Texts to mutate: every token and nesting the reader walks.
local SAMPLES <const> = {
  '{"a": [1, 2.5, "x", true, false, null], "b": {"c": {}, "d": []}}',
  '[0, -0, 1e308, 5e-324, -12.5E+3, 18446744073709551616, 123456789012345678901234567890]',
  '"\\u0000\\u001f\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9\\ud83d\\ude00\xc3\xa9"',
  '{"k": {"k": [{"k": null}, [[]], {}]}, "\\u006b2": "v"}',
  '[\r\n  1,\n  {"a b": "[{\\"}"},\r  "]"\n]',
  "null", "true", "0", '""', "[]", "{}", "1 2 [3]", "[1\r,\n2\r]\n", "\r1\n",
}

-- JSON5's forms and `#` comments: each read under `json5` or
-- `hash_comments`, and refused, in their place, without.
local EXTENDED <const> = {
  "{a: 1, 'b': 'x', \"c\": [.5, 5., +1, 0x1F, -0xff, Infinity, -Infinity, NaN, nan, inf,],}",
  "// head\n[1, /* mid\n */ 2, // tail\n 3]\n// end",
  "{\n  unquoted_key: 'single \\'quoted\\' \\x41 \\u00e9 \\\n continued',\n  $id: true, _x1: null, \\u0061b: 0,\n}",
  "[1,\u{2028} 2,\u{2029} 3\u{a0}, \u{feff}4\u{3000}]",
  "['a\u{2028}b', \"c\u{2029}d\", /* \u{2028} */ 1]// \u{2028}",
  "[1 /**/, /***/ 2, /*/ x */ 3, /* * / */ 4]",
  "# head\n{\"a\": [1, # one\n 2] # two\r}\n# end",
  "[1, # \" ' [ ] { } /* \n 2, # \u{2028} 3\n]",
  "{a /* c */ : // d\n 1 , 'b'#x\n:#y\n[0x1F,],}",
  "[Infinity, -Infinity, +NaN, -.5e1, 0XA, 1e+2, nan, -inf]",
  "{true: 1, null: 2, \\u0041: 3, é\u{2028}: 4, $: 5}",
  "'\\0\\v\\b\\f\\z\\x7e\\\r\nq'",
}

-- Texts that read with `hash_comments` alone.
local HASHED <const> = {
  "# head\n{\"a\": [1, # one\n 2] # two\r}\n# end",
  "[1, # \" ' [ ] { } /* // \n 2, # \u{2028} 3\n]",
  "{#c\n\"a\"#c\n:#c\n1#c\n}#c",
  "[true#c\n,null#c\r,1#c\n]# x",
}

local TOKENS <const> = { "{", "}", "[", "]", ":", ",", '"', "\\", "\\u", "0", "1", "-", ".", "e",
  "true", "false", "null", "a", " ", "\n", "\r", "\t", "\xc3", "\xa9", "\xff" }

local EXTENDED_TOKENS <const> = { "'", "/", "*", "//", "/*", "*/", "#", "\xe2\x80\xa8", "\xe2\x80\xa9",
  "\xe2\x80", "\xe2", "\xc2\xa0", "\xef\xbb\xbf", "+", "I", "Infinity", "NaN", "nan", "n", "0x1F", "0x",
  "\\x41", "\v", "\f", "$", "#", "#", "_", "é", "\\u0041" }

--- What `holds` is told about how to read the text: `json5` and
--- `hash_comments`, as two booleans in a number 0 to 3.
local function options_of(flags: integer): Json.ReaderOptions, Json.DecodeOptions
  local json5, hash = flags & 1 == 1, flags & 2 == 2
  return { null_value = Json.null, json5 = json5, hash_comments = hash },
    { null_value = Json.null, json5 = json5, hash_comments = hash }
end

local function gen(src: Fuzz.Source): string
  local text: string
  local flags = src:int(0, 3)
  local shape = src:int(0, 9)
  if shape < 2 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 30) do parts[#parts + 1] = Fuzz.pick(src, TOKENS) end
    text = table.concat(parts)
  elseif shape < 4 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 30) do
      parts[#parts + 1] = src:int(0, 1) == 0 and Fuzz.pick(src, EXTENDED_TOKENS) or Fuzz.pick(src, TOKENS)
    end
    text = table.concat(parts)
  elseif shape < 7 then
    text = Fuzz.pick(src, flags == 2 and HASHED or EXTENDED)
    local edits = src:int(0, 2)
    if edits > 0 then text = Fuzz.mutate(src, text, edits == 1 and 1 or 6) end
  else
    text = Fuzz.pick(src, SAMPLES)
    local edits = src:int(0, 2)
    if edits > 0 then text = Fuzz.mutate(src, text, edits == 1 and 1 or 6) end
  end
  return Fuzz.pack({ text, tostring(src:int(1, 9)), tostring(flags) })
end

--- The tokens of `text` read `size` bytes at a time, one to a line, and
--- the failure that ended them; nil and why when the reader raised.
local function token_lines(text: string, size: integer, opts: Json.ReaderOptions): string | nil, string
  local ok, result, err = pcall(function(): string, string
    local r = Json.reader(chunked(text, size), opts)
    local out: {string} = {}
    while true do
      local t, why = r:next()
      if t == nil then return table.concat(out, "\n"), why end
      out[#out + 1] = t.kind .. "=" .. Json.quote(tostring(t.value)) .. "@" .. assert(Json.pointer(r:steps()))
    end
  end)
  if not ok then return nil, "raised: " .. tostring(result) end
  return result .. "\n!" .. err, ""
end

--- The values the tokens of `text` build, each with the null stand-in;
--- nil and the failure that ended them.
local function token_values(text: string, size: integer, opts: Json.ReaderOptions): {any} | nil, string
  local r = Json.reader(chunked(text, size), opts)
  local values: {any} = {}
  local stack: {{any: any}} = {}
  local keys: {string} = {}
  local function place(v: any)
    local top = stack[#stack]
    if top == nil then
      values[#values + 1] = v
    elseif Json.is_array(top) then
      top[rawlen(top) + 1] = v
    else
      top[keys[#stack]] = v
    end
  end
  while true do
    local t, why = r:next()
    if t == nil then
      if why ~= "" then return nil, why end
      return values, ""
    end
    if t.kind == "object" or t.kind == "array" then
      local container: {any: any} = t.kind == "array" and Json.array() as {any: any} or {}
      place(container)
      stack[#stack + 1] = container
    elseif t.kind == "end_object" or t.kind == "end_array" then
      stack[#stack] = nil
    elseif t.kind == "key" then
      keys[#stack] = t.value as string
    elseif t.kind == "null" then
      place(Json.null)
    else
      place(t.value)
    end
  end
end

--- Whether `a` and `b` are one value: the same numbers of the same kind,
--- NaN equal to NaN (JSON has no text for it, so encoding cannot compare
--- them), the same members, arrays marked alike.
local function same(a: any, b: any): boolean
  if a is table then
    if not (b is table) or Json.is_array(a) ~= Json.is_array(b) then return false end
    for k, v in pairs(a) do
      if not same(v, b[k]) then return false end
    end
    for k in pairs(b) do
      if a[k] == nil then return false end
    end
    return true
  end
  if a is number and b is number then
    return (a == b or (a ~= a and b ~= b)) and math.type(a) == math.type(b)
  end
  return a == b
end

--- The line and column of byte `pos` of `text`, counted as `decode`
--- counts them: a line ends at \n, \r, or \r\n taken as one, and in JSON5
--- at U+2028 and U+2029.
local function line_and_column(text: string, pos: integer, json5: boolean): integer, integer
  local line, column, i = 1, 1, 1
  while i < pos do
    local c = text:byte(i)
    if c == 13 and i + 1 < pos and text:byte(i + 1) == 10 then i = i + 1 end
    if json5 and c == 0xE2 and i + 2 < pos and text:byte(i + 1) == 0x80 and
        (text:byte(i + 2) == 0xA8 or text:byte(i + 2) == 0xA9) then
      i = i + 2
      c = 10
    end
    if c == 10 or c == 13 then
      line, column = line + 1, 1
    else
      column = column + 1
    end
    i = i + 1
  end
  return line, column
end

--- A stray byte after a text that decodes, on a line of its own so that
--- no comment holds it, is refused where it is, read by tokens and by
--- `value` alike.
local function placed_after(text: string, size: integer, opts: Json.ReaderOptions): boolean, string
  local stray = text .. "\n@"
  local line, column = line_and_column(stray, #stray, opts.json5 == true)
  local want = ("json: a byte no JSON token starts with at line %d, column %d (pointer \"\")"):format(line, column)
  local r = Json.reader(chunked(stray, size), opts)
  local why: string
  repeat
    local t, err = r:next()
    why = err
  until t == nil
  if why ~= want then return false, "by tokens: " .. why .. ", not " .. want end
  local v = Json.reader(chunked(stray, size), opts)
  local _, verr = v:value()
  if verr ~= "" then return false, "value: " .. verr end
  local _, after = v:next()
  if after ~= want then return false, "after value: " .. after .. ", not " .. want end
  return true, ""
end

local function holds(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local text, size = fields[1], math.tointeger(tonumber(fields[2])) as integer
  local flags = math.tointeger(tonumber(fields[3])) as integer
  local opts, dopts = options_of(flags)
  local whole, raised = token_lines(text, #text + 1, opts)
  if whole == nil then return false, raised end
  local split, split_raised = token_lines(text, size, opts)
  if split == nil then return false, split_raised end
  if split ~= whole then
    return false, "split in " .. size .. "s:\n" .. split .. "\nwhole:\n" .. whole
  end
  local decoded, err = Json.decode(text, dopts)
  local values, why = token_values(text, size, opts)
  if err == "" then
    Fuzz.label("decoded")
    if flags & 1 == 1 and not Json.check(text) then Fuzz.label("json5") end
    if flags == 2 and not Json.check(text) then Fuzz.label("hash") end
    if values == nil then return false, "decode read it, the reader refused: " .. why end
    if #values ~= 1 or not same(values[1], decoded) then
      return false, "the tokens built another value"
    end
    local r = Json.reader(chunked(text, size), opts)
    local value, verr = r:value()
    if verr ~= "" then return false, "value refused what decode read: " .. verr end
    if not same(value, decoded) then return false, "value read another value" end
    local after, aerr = r:next()
    if after ~= nil or aerr ~= "" then return false, "a token after the one value: " .. aerr end
    local ok, why_not = placed_after(text, size, opts)
    if not ok then return false, why_not end
  elseif values ~= nil and #values == 1 then
    return false, "the reader read one value, decode refused it: " .. err
  elseif values == nil then
    Fuzz.label("refused")
    -- Text another combination of the options reads, refused by this one.
    if Json.check(text, { json5 = true, hash_comments = true }) then
      Fuzz.label("refused_extended")
    end
  end
  return true, ""
end

-- About half the drawn texts decode; a share well under it fails the run.
-- The JSON5 and comment forms are a share of those, and each is read
-- by the reader or refused by it as decode does.
local function test_the_reader_agrees_with_decode(tmp: string)
  Fuzz.run({ name = "json reader", dir = tmp, gen = gen, check = holds,
    requires = { "decoded", "refused", "json5", "hash", "refused_extended" },
    shares = { decoded = 0.2, json5 = 0.03, hash = 0.01, refused_extended = 0.01 } })
end
