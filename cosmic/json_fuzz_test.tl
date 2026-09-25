--- Fuzz properties for `cosmic.json`: decode is total on any bytes, in
--- either grammar; what decodes encodes, to text that is a fixed point;
--- text RFC 8259 reads, JSON5 reads the same; encode is total on any
--- Lua value, and what it writes decodes back to the same value; the
--- depth limits hold exactly; and JSON Lines is total and round-trips.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
---
--- yyjson itself is fuzzed upstream. What these reach is this tree's
--- own C in core/json.c -- the walk from yyjson's document into Lua
--- values, the encoder, its error paths -- and the Teal above it.

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")

--- Well-formed and nearly well-formed texts to mutate: every shape the
--- walk builds, the number and string corners, and JSON5's forms.
local SAMPLES <const> = {
  '{"\\udbff": ["\\ud83d", "x\\ude00", "\\ud83d\\ude00"]}',
  '{"a": [1, 2.5, "x", true, false, null], "b": {"c": {}, "d": []}}',
  '[0, -0, 1e308, 5e-324, 1E+2, 0.1e-5, -9223372036854775808, 9223372036854775807]',
  '[18446744073709551615, 18446744073709551616, 123456789012345678901234567890, 1e400]',
  '"\\u0000\\u001f\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9\\ud83d\\ude00"',
  '"\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80"',
  '{"a": 1, "a": null, "a": [null, {"a": null}]}',
  '[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]',
  '{"k":{"k":{"k":{"k":{"k":{"k":[{"k":null}]}}}}}}',
  "// c\n{unquoted: 'single', trailing: [1, 2,], hex: 0x1F, lead: .5, nan: NaN, inf: -Infinity,}",
  "/* block */ ['\\a\\e\\x41', +1, 5.,]",
  "null", "true", "0", '""', "[]", "{}",
}

--- Bytes JSON singles out, drawn more often than chance would.
local TOKENS <const> = { "{", "}", "[", "]", ":", ",", '"', "\\", "\\u", "d8", "dc", "0", "1",
  "-", "+", ".", "e", "E", "x", "true", "false", "null", "NaN", "Infinity", "/", "*", "'",
  " ", "\n", "\r", "\t", "\0", "\xc3", "\xa9", "\xed", "\xa0", "\x80", "\xff", "\xef\xbb\xbf",
  "\\ud83d", "\\ude00", "\\uDBFF" }

--- The leaves a drawn text is built from: numbers at the edges of an
--- integer, a double and what only a big number holds; a string's
--- escapes, paired and lone surrogates, and multibyte UTF-8; keys, some
--- repeated; and the whitespace between tokens. Each list's second half
--- is JSON5's alone, drawn only into a text meant for JSON5.
local NUMBERS <const>: {{string}} = {
  { "0", "-0", "1", "-1", "2.5", "1e308", "5e-324", "1E+2", "0.1e-5", "1e400", "-9223372036854775808",
    "9223372036854775807", "9223372036854775808", "18446744073709551616", "123456789012345678901234567890" },
  { "0x1F", ".5", "5.", "+1", "NaN", "-Infinity", "Infinity" },
}
local CHUNKS <const>: {{string}} = {
  { "a", "x", " ", "\\\"", "\\\\", "\\/", "\\b", "\\f", "\\n", "\\r", "\\t", "\\u0000", "\\u001f",
    "\\u00e9", "\\ud83d\\ude00", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80" },
  { "\\x41", "\\a", "'" },
}
--- Halves of a surrogate pair, alone: rare, since each makes a text
--- only `lone_surrogates` reads.
local LONE <const> = { "\\ud83d", "\\ude00", "\\uDBFF" }
local KEYS <const>: {{string}} = {
  { '"a"', '"k"', '""', '"\\u0000"', '"\xc3\xa9"' },
  { "unquoted", "'single'", "$_" },
}
local GAPS <const>: {{string}} = {
  { "", "", "", " ", "\n", "\t", "\r\n" },
  { "/* c */", "// c\n", "\xc2\xa0" },
}

--- One of `lists`' strict half, or, in a text meant for JSON5, now and
--- then one of its JSON5 half.
local function leaf(src: Fuzz.Source, lists: {{string}}, json5: boolean): string
  if json5 and src:int(0, 3) == 0 then return Fuzz.pick(src, lists[2]) end
  return Fuzz.pick(src, lists[1])
end

--- A value drawn from the grammar, nested at most `depth` deep, each
--- container's elements drawn with `Fuzz.more` so shrinking can cut
--- any of them. Strict JSON unless `json5`, which adds its forms and
--- trailing commas.
local function gen_value(src: Fuzz.Source, depth: integer, json5: boolean): string
  local kind = src:int(0, depth > 0 and 5 or 2)
  if kind == 0 then return Fuzz.pick(src, { "null", "true", "false" }) end
  if kind == 1 then return leaf(src, NUMBERS, json5) end
  if kind == 2 or kind == 3 then
    local chunks: {string} = {}
    while Fuzz.more(src, #chunks, 8) do
      chunks[#chunks + 1] = src:int(0, 31) == 0 and Fuzz.pick(src, LONE) or leaf(src, CHUNKS, json5)
    end
    local text = table.concat(chunks)
    if json5 and src:int(0, 3) == 0 then return "'" .. text:gsub("'", "\\'") .. "'" end
    return '"' .. text .. '"'
  end
  local items: {string} = {}
  while Fuzz.more(src, #items, 6) do
    local item = gen_value(src, depth - 1, json5)
    if kind == 5 then item = leaf(src, KEYS, json5) .. leaf(src, GAPS, json5) .. ":" .. leaf(src, GAPS, json5) .. item end
    items[#items + 1] = leaf(src, GAPS, json5) .. item .. leaf(src, GAPS, json5)
  end
  local trailing = json5 and #items > 0 and src:int(0, 3) == 0 and "," or ""
  local open, close = "[", "]"
  if kind == 5 then open, close = "{", "}" end
  return open .. table.concat(items, ",") .. trailing .. close
end

--- A text to decode: on a fifth of draws a soup of tokens; else a
--- sample or a value drawn from the grammar, under up to 8 edits on a
--- fifth, at most one on a fifth, and none on the rest, so that the
--- walk into Lua values and the re-encoding checks run on most draws
--- while edits still reach the refusals.
local function gen_text(src: Fuzz.Source): string
  local shape = src:int(0, 4)
  if shape == 0 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 40) do
      parts[#parts + 1] = src:int(0, 3) == 0 and Fuzz.bytes(src, 3) or Fuzz.pick(src, TOKENS)
    end
    return table.concat(parts)
  end
  local base = src:int(0, 1) == 0 and Fuzz.pick(src, SAMPLES) or gen_value(src, 4, src:int(0, 1) == 0)
  if shape >= 3 then return base end
  return Fuzz.mutate(src, base, shape == 1 and 8 or 1)
end

--- The options every check re-encodes with: whatever decoded, JSON can
--- say, since a stand-in holds every null and NaN becomes `null`.
local CANONICAL <const>: Json.EncodeOptions = { nan_as_null = true, sparse_as_null = true, max_depth = 1000 }

--- `value`'s canonical text, which must re-read as itself.
local function canonical(value: any, where: string): string | nil, string
  local text, err = Json.encode(value, CANONICAL)
  if text == nil then return nil, where .. ": decoded, but did not encode: " .. err end
  local back, berr = Json.decode(text, { null_value = Json.null, max_depth = 1000 })
  if berr ~= "" then return nil, where .. ": encode wrote what decode refuses: " .. berr end
  local again, aerr = Json.encode(back, CANONICAL)
  if again ~= text then
    return nil, where .. ": not a fixed point: " .. text .. " -> " .. tostring(again or aerr)
  end
  return text, ""
end

--- One decode, under pcall: nil and why when it broke its contract,
--- else what it answered.
local function decode_once(input: string, opts: Json.DecodeOptions, where: string): boolean, any, string
  local ok, value, err = pcall(Json.decode, input, opts)
  if not ok then return false, nil, where .. ": raised: " .. tostring(value) end
  if not (err is string) then return false, nil, where .. ": no message slot" end
  if err ~= "" and value ~= nil then return false, nil, where .. ": a failure with a value" end
  return true, value, err
end

local function decode_holds(input: string): boolean, string
  local strict_text: string = nil
  for _, json5 in ipairs({ false, true }) do
    for _, big in ipairs({ false, true }) do
      local where = ("json5=%s big=%s"):format(tostring(json5), tostring(big))
      local ok, value, err = decode_once(input,
        { null_value = Json.null, json5 = json5, big_numbers_as_strings = big }, where)
      if not ok then return false, err end
      if err == "" then
        Fuzz.label(json5 and "decoded as JSON5" or "decoded")
        local text, why = canonical(value, where)
        if text == nil then return false, why end
        if not json5 and not big then
          strict_text = text
        elseif json5 and not big and strict_text ~= nil and text ~= strict_text then
          return false, "JSON5 read strict JSON differently: " .. strict_text .. " vs " .. text
        end
      elseif json5 and not big and strict_text ~= nil then
        return false, "strict JSON read, JSON5 refused it: " .. err
      end
      -- Without a stand-in, a null is a hole: still total.
      local plain_ok, _, plain_err = decode_once(input, { json5 = json5 }, where .. " without null_value")
      if not plain_ok then return false, plain_err end
      -- lone_surrogates is total too, and changes only what failed.
      local lone_ok, lone_value, lone_err = decode_once(input, { null_value = Json.null, json5 = json5,
        big_numbers_as_strings = big, lone_surrogates = true }, where .. " lone_surrogates")
      if not lone_ok then return false, lone_err end
      if err == "" then
        if lone_err ~= "" then return false, where .. ": lone_surrogates refused what read: " .. lone_err end
        local a, b = canonical(value, where), canonical(lone_value, where)
        if a ~= b then return false, where .. ": lone_surrogates read it differently" end
      elseif lone_err == "" then
        local text, why = canonical(lone_value, where .. " lone_surrogates")
        if text == nil then return false, why end
      end
    end
  end
  return true, ""
end

--- The column of the `n`th `[` or `{` in `opens`, which holds nothing
--- else that brackets: the one a depth limit of n - 1 refuses.
local function deepest(opens: string, n: integer): integer
  local at = 0
  for _ = 1, n do
    at = assert(opens:find("[%[{]", at + 1))
  end
  return at
end

-- Most drawn texts parse -- 44% strictly and 51% as JSON5, where a
-- generator of edits and token soup reached 13% and 15% -- so the walk
-- into Lua values and the re-encoding checks run on most; a share under
-- a fifth fails the run.
local function test_decode_is_total_on_mutated_json(tmp: string)
  Fuzz.run({ name = "json decode total", dir = tmp, gen = gen_text, check = decode_holds,
    shares = { decoded = 0.2, ["decoded as JSON5"] = 0.2 } })
end

local function test_decode_is_total_on_arbitrary_bytes(tmp: string)
  Fuzz.run({
    name = "json decode total on bytes",
    dir = tmp,
    gen = function(src: Fuzz.Source): string return Fuzz.bytes(src, 64) end,
    check = decode_holds,
  })
end

--- Reads a value out of a recipe's bytes, so the encoder's input is
--- drawn -- and shrunk -- as bytes. Every value a Lua program could hand
--- `encode` is reachable: each JSON type, NaN and the infinities, bytes
--- that are not UTF-8, holes, mixed and odd keys, functions, the null
--- stand-in, marked arrays, and a table that contains itself.
local record Recipe
  bytes: string
  at: integer
end

local function next_byte(r: Recipe): integer
  r.at = r.at + 1
  return r.bytes:byte(r.at) or 0
end

local function next_bytes(r: Recipe, n: integer): string
  local s = r.bytes:sub(r.at + 1, r.at + n)
  r.at = r.at + n
  return s .. string.rep("\0", n - #s)
end

local CHARS <const> = { "a", "Z", "0", " ", '"', "\\", "/", "\n", "\t", "\r", "\b", "\f", "\0", "\31", "\127",
  "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80" }

-- TODO: a recipe's strings and tables read their count from one byte
-- first, as the generators here no longer do, so cutting a recipe's bytes
-- drops a middle element only by reshaping everything after it; a byte
-- before each element whose low values stop, as `Fuzz.more` draws, would
-- let shrinking drop any (measure "encoded" and "refused" again).
local function recipe_value(r: Recipe, depth: integer, parent: {any: any}): any
  local op = next_byte(r) % 13
  if depth > 6 and op >= 7 then op = op % 7 end
  if op == 0 then return nil end
  if op == 1 then return next_byte(r) % 2 == 1 end
  if op == 2 then return next_byte(r) - 128 end
  if op == 3 then return (string.unpack("<i8", next_bytes(r, 8))) end
  if op == 4 then return (string.unpack("<d", next_bytes(r, 8))) end
  if op == 5 then return next_bytes(r, next_byte(r) % 12) end
  if op == 6 then
    local parts: {string} = {}
    for i = 1, next_byte(r) % 8 do parts[i] = CHARS[next_byte(r) % #CHARS + 1] end
    return table.concat(parts)
  end
  if op == 7 then
    local t: {any: any} = {}
    for i = 1, next_byte(r) % 5 do t[i] = recipe_value(r, depth + 1, t) end
    return t
  end
  if op == 8 then
    local t: {any: any} = {}
    for _ = 1, next_byte(r) % 5 do
      local key = recipe_value(r, 9, t)
      if key is string then t[key] = recipe_value(r, depth + 1, t) end
    end
    return t
  end
  if op == 9 then return Json.null end
  if op == 10 then
    local t = Json.array()
    for i = 1, next_byte(r) % 4 do t[i] = recipe_value(r, depth + 1, t) end
    return t
  end
  if op == 11 then
    local odd: {{any: any}} = { { [true] = 1 }, { [1.5] = 1 }, { [0] = 1 }, { 1, nil, 3 },
      { [40] = 1 }, { 1, a = 2 }, { [{}] = 1 }, { ["\xff"] = 1 } }
    return odd[next_byte(r) % #odd + 1]
  end
  if parent ~= nil and next_byte(r) % 2 == 0 then return parent end
  return print
end

local function recipe_options(r: Recipe): Json.EncodeOptions
  local bits = next_byte(r)
  local opts: Json.EncodeOptions = {
    pretty = bits & 1 ~= 0,
    sorted = bits & 2 == 0,
    nan_as_null = bits & 4 ~= 0,
    sparse_as_null = bits & 8 ~= 0,
    ascii = bits & 64 ~= 0,
  }
  if bits & 16 ~= 0 then opts.max_depth = next_byte(r) % 8 + 1 end
  if opts.pretty and bits & 32 ~= 0 then opts.indent = "\t" end
  return opts
end

local function encode_holds(input: string): boolean, string
  local r: Recipe = { bytes = input, at = 0 }
  local opts = recipe_options(r)
  local value = recipe_value(r, 0, nil)
  local ok, text, err = pcall(Json.encode, value, opts)
  if not ok then return false, "raised: " .. tostring(text) end
  Fuzz.label(text ~= nil and "encoded" or "refused")
  if text == nil then
    if not (err is string) or err == "" then return false, "a failure without a message" end
    if err:find(" at ", 1, true) and not err:find(" at %$") then
      return false, "a location that is not a path: " .. err
    end
    return true, ""
  end
  if err ~= "" then return false, "a success with a message: " .. err end
  if opts.ascii and text:find("[\128-\255]") then
    return false, "ascii wrote a byte past ASCII: " .. text
  end
  local same: Json.EncodeOptions = { nan_as_null = opts.nan_as_null,
    sparse_as_null = opts.sparse_as_null, max_depth = opts.max_depth }
  local expected, eerr = Json.encode(value, same)
  if expected == nil then
    return false, "encoded laid out or unsorted, but not canonically: " .. eerr
  end
  local back, berr = Json.decode(text, { null_value = Json.null, max_depth = 1000 })
  if berr ~= "" then return false, "wrote what decode refuses: " .. berr .. ": " .. text end
  local got, gerr = Json.encode(back, { max_depth = 1000 })
  if got ~= expected then
    return false, "did not read back the same: " .. expected .. " vs " .. tostring(got or gerr)
  end
  return true, ""
end

local function test_encode_is_total_and_round_trips(tmp: string)
  Fuzz.run({
    name = "json encode total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string return Fuzz.bytes(src, 200) end,
    check = encode_holds,
    requires = { "encoded", "refused" },
  })
end

--- An input `n` containers deep, and the limit to read it under.
local function test_the_depth_limits_are_exact(tmp: string)
  Fuzz.run({
    name = "json depth",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local opens: {string} = {}
      while Fuzz.more(src, #opens, 1200) do opens[#opens + 1] = src:int(0, 1) == 0 and "[" or '{"k":' end
      return Fuzz.pack({ table.concat(opens), tostring(src:int(1, 1000)) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local opens, limit = fields[1], math.tointeger(tonumber(fields[2])) as integer
      local closes = opens:reverse():gsub(":\"k\"{", "}"):gsub("%[", "]")
      local _, n = opens:gsub("[%[{]", "")
      local value, err = Json.decode(opens .. "1" .. closes, { max_depth = limit })
      if n <= limit then
        if err ~= "" then return false, ("%d levels under a limit of %d: %s"):format(n, limit, err) end
      elseif value ~= nil or err ~= ("JSON nests deeper than %d levels at line 1, column %d"):
           format(limit, deepest(opens, limit + 1)) then
        return false, ("%d levels over a limit of %d: %s"):format(n, limit, err)
      end
      if err == "" then
        local text, eerr = Json.encode(value, { max_depth = limit })
        if n <= limit and text == nil then
          return false, ("%d levels encode under a limit of %d: %s"):format(n, limit, eerr)
        end
      end
      return true, ""
    end,
  })
end

local function test_json_lines_are_total_and_round_trip(tmp: string)
  Fuzz.run({
    name = "json lines",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local lines: {string} = {}
      while Fuzz.more(src, #lines, 5) do lines[#lines + 1] = Fuzz.pick(src, SAMPLES):gsub("\n", " ") end
      return Fuzz.mutate(src, table.concat(lines, Fuzz.pick(src, { "\n", "\r\n", "\n\n" })), 6)
    end,
    check = function(input: string): boolean, string
      local ok, values, err = pcall(Json.decode_lines, input, { null_value = Json.null, json5 = true })
      if not ok then return false, "raised: " .. tostring(values) end
      if values == nil then
        if err == "" then return false, "a failure without a message" end
        return true, ""
      end
      local text, eerr = Json.encode_lines(values, { nan_as_null = true })
      if text == nil then return false, "decoded lines did not encode: " .. eerr end
      local back, berr = Json.decode_lines(text, { null_value = Json.null })
      if back == nil then return false, "encode_lines wrote what decode_lines refuses: " .. berr end
      local a, b = Json.encode(values, CANONICAL), Json.encode(back, CANONICAL)
      if a ~= b then return false, "lines did not read back the same: " .. tostring(a) .. " vs " .. tostring(b) end
      return true, ""
    end,
  })
end
