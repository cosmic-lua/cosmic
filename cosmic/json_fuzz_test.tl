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
  '# c\n{"a": [1, # two\n2], "#": "# not one"} # end',
  "null", "true", "0", '""', "[]", "{}",
}

--- Bytes JSON singles out, drawn more often than chance would.
local TOKENS <const> = { "{", "}", "[", "]", ":", ",", '"', "\\", "\\u", "d8", "dc", "0", "1",
  "-", "+", ".", "e", "E", "x", "true", "false", "null", "NaN", "Infinity", "/", "*", "'", "#",
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
--- container's elements drawn with [`Fuzz.more`] so shrinking can cut
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
    if kind == 5 then
      item = leaf(src, KEYS, json5) .. leaf(src, GAPS, json5) .. ":" .. leaf(src, GAPS, json5) .. item
    end
    items[#items + 1] = leaf(src, GAPS, json5) .. item .. leaf(src, GAPS, json5)
  end
  local trailing = json5 and #items > 0 and src:int(0, 3) == 0 and "," or ""
  local open, close = "[", "]"
  if kind == 5 then open, close = "{", "}" end
  return open .. table.concat(items, ",") .. trailing .. close
end

--- A text drawn from the grammar with each `//` comment a `#` one and a
--- `#` one ending each line. No drawn string holds a raw line end, so
--- none lands inside one.
local function hashed(text: string): string
  return (text:gsub("// c\n", "# c\n"):gsub("\n", " # c\n"))
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
  local base: string
  if src:int(0, 1) == 0 then
    base = Fuzz.pick(src, SAMPLES)
  else
    base = gen_value(src, 4, src:int(0, 1) == 0)
    -- On a third of drawn texts, `#` comments only `hash_comments`
    -- reads.
    if src:int(0, 2) == 0 then base = hashed(base) end
  end
  if shape >= 3 then return base end
  return Fuzz.mutate(src, base, shape == 1 and 8 or 1)
end

--- The options every check re-encodes with.
local CANONICAL <const>: Json.EncodeOptions = { max_depth = 1000 }

--- `value` as it re-encodes: a decoded value holds NaN and the
--- infinities where JSON5 wrote them, which `encode` refuses, so each
--- becomes [`Json.null`]. Every null is a stand-in, never a hole, in what
--- the checks decode.
local function finite(value: any): any
  if value is number then
    if value ~= value or value == math.huge or value == -math.huge then return Json.null end
    return value
  end
  if not (value is {any: any}) then return value end
  local out: {any: any} = Json.is_array(value) and Json.array() as {any: any} or {}
  for k, v in pairs(value) do out[k] = finite(v) end
  return out
end

--- `value`'s canonical text, which must re-read as itself.
local function canonical(value: any, where: string): string | nil, string
  local text, err = Json.encode(finite(value), CANONICAL)
  if text == nil then return nil, where .. ": decoded, but did not encode: " .. err end
  local back, berr = Json.decode(text, { null_value = Json.null, max_depth = 1000 })
  if berr ~= "" then return nil, where .. ": encode wrote what decode refuses: " .. berr end
  local again, aerr = Json.encode(finite(back), CANONICAL)
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

--- Whether `compact`, the text [`Json.format`] writes, has an object that
--- holds one key twice, or nil when it is nothing. One scan keeps, for
--- each open object, the key literals it has had; it shares nothing with
--- the check in core/json.c. Format writes a string one way, so equal
--- keys are equal literals.
local function holds_key_twice(compact: string | nil): boolean | nil
  if compact == nil then return nil end
  local open: {{string: boolean}} = {}
  local objects: {boolean} = {}
  local expecting = false
  local i = 1
  while i <= #compact do
    local c = compact:sub(i, i)
    if c == '"' then
      local j = i + 1
      while compact:sub(j, j) ~= '"' do
        j = j + (compact:sub(j, j) == "\\" and 2 or 1)
      end
      if expecting then
        local keys = open[#open]
        local literal = compact:sub(i, j)
        if keys[literal] then return true end
        keys[literal] = true
        expecting = false
      end
      i = j
    elseif c == "{" then
      open[#open + 1] = {}
      objects[#open] = true
      expecting = true
    elseif c == "[" then
      open[#open + 1] = {}
      objects[#open] = false
      expecting = false
    elseif c == "}" or c == "]" then
      open[#open] = nil
      objects[#objects] = nil
      expecting = false
    elseif c == "," then
      expecting = #open > 0 and objects[#open]
    end
    i = i + 1
  end
  return false
end

local function decode_holds(input: string): boolean, string
  local strict_text: string = nil
  for _, json5 in ipairs({ false, true }) do
    for _, big in ipairs({ false, true }) do
      local where = ("json5=%s big=%s"):format(tostring(json5), tostring(big))
      local ok, value, err = decode_once(input, { null_value = Json.null, json5 = json5,
        big_numbers_as_strings = big, duplicate_keys = true }, where)
      if not ok then return false, err end
      -- Without duplicate_keys, a text reads as it did with it, or is
      -- refused for a key twice, naming where; and only such a text.
      local once_ok, once_value, once_err = decode_once(input, { null_value = Json.null, json5 = json5,
        big_numbers_as_strings = big }, where .. " refusing duplicate keys")
      if not once_ok then return false, once_err end
      -- Whether a text that reads holds a key twice is answered from
      -- the members `format` writes, not by decode's own check.
      if err == "" then
        local twice = holds_key_twice((Json.format(input, { json5 = json5, duplicate_keys = true })))
        if twice ~= nil then
          Fuzz.label(twice and "oracle saw a key twice" or "oracle saw no key twice")
          if twice ~= (once_err ~= "") then
            return false, where .. ": a key twice in the members, but decode said \"" .. once_err .. "\""
          end
        end
      end
      if once_err:match("^json: duplicate key ") then
        -- A key twice comes before whatever the text holds after it,
        -- which may nest too deep to read.
        if err ~= "" and not err:match("^json: JSON nests deeper ") then
          return false, where .. ": a key twice in text that did not read: " .. err
        end
        if not once_err:match('^json: duplicate key at line %d+, column %d+ %(pointer "[^\n]*"%)$') then
          return false, where .. ": " .. once_err
        end
        Fuzz.label("refused a key twice")
      elseif (once_err == "") ~= (err == "") then
        return false, where .. ": duplicate_keys changed more than a key twice: " .. once_err .. " vs " .. err
      elseif err == "" and canonical(value, where) ~= canonical(once_value, where) then
        return false, where .. ": duplicate_keys read a text without a key twice differently"
      end
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
      local plain_ok, _, plain_err = decode_once(input, { json5 = json5, duplicate_keys = true },
        where .. " without null_value")
      if not plain_ok then return false, plain_err end
      -- lone_surrogates is total too, and changes only what failed.
      local lone_ok, lone_value, lone_err = decode_once(input, { null_value = Json.null, json5 = json5,
        big_numbers_as_strings = big, lone_surrogates = true, duplicate_keys = true }, where .. " lone_surrogates")
      if not lone_ok then return false, lone_err end
      if err == "" then
        if lone_err ~= "" then
          return false, where .. ": lone_surrogates refused what read: " .. lone_err
        end
        local a, b = canonical(value, where), canonical(lone_value, where)
        if a ~= b then return false, where .. ": lone_surrogates read it differently" end
      elseif lone_err == "" then
        local text, why = canonical(lone_value, where .. " lone_surrogates")
        if text == nil then return false, why end
      end
      -- hash_comments is total too, and only widens what reads: a text
      -- that read without it holds `#` only inside strings.
      local hash_ok, hash_value, hash_err = decode_once(input, { null_value = Json.null, json5 = json5,
        big_numbers_as_strings = big, hash_comments = true, duplicate_keys = true }, where .. " hash_comments")
      if not hash_ok then return false, hash_err end
      if err == "" then
        if hash_err ~= "" then
          return false, where .. ": hash_comments refused what read: " .. hash_err
        end
        if canonical(value, where) ~= canonical(hash_value, where) then
          return false, where .. ": hash_comments read it differently"
        end
      elseif hash_err == "" then
        Fuzz.label("decoded only with # comments")
        local text, why = canonical(hash_value, where .. " hash_comments")
        if text == nil then return false, why end
      end
    end
  end
  return true, ""
end

--- `a` and `b`'s decodes under `a_opts` and `b_opts` agree: both fail,
--- or both read the same value. Whether they read.
local function same_reading(a: string, a_opts: Json.DecodeOptions, b: string,
                            b_opts: Json.DecodeOptions, where: string): boolean, boolean, string
  local va, ea = Json.decode(a, a_opts)
  local vb, eb = Json.decode(b, b_opts)
  if (ea == "") ~= (eb == "") then
    return false, false, where .. ": one read and one did not: " .. (ea ~= "" and ea or eb)
  end
  if ea ~= "" then return true, false, "" end
  if canonical(va, where) ~= canonical(vb, where) then
    return false, false, where .. ": read differently"
  end
  return true, true, ""
end

-- A `#` comment reads as a `//` one or a line end would: a text drawn
-- from the grammar, made `hashed`, reads with `hash_comments` exactly
-- as it read before as JSON5, and as RFC 8259 as it read with each
-- `//` comment a bare line end; and one that gained a `#` comment
-- reads without `hash_comments` as neither. About 70% of drawn texts
-- read strictly, 88% as JSON5, and 22% gain a `#` comment; a share
-- well under each fails the run.
local function test_hash_comments_read_as_line_comments(tmp: string)
  Fuzz.run({
    name = "json hash comments",
    dir = tmp,
    gen = function(src: Fuzz.Source): string return gen_value(src, 4, src:int(0, 1) == 0) end,
    check = function(input: string): boolean, string
      local text = hashed(input)
      for _, five in ipairs({ false, true }) do
        local where = five and "JSON5" or "RFC 8259"
        local before = five and input or (input:gsub("// c\n", "\n"))
        local ok, read, why = same_reading(before, { null_value = Json.null, json5 = five, duplicate_keys = true },
          text, { null_value = Json.null, json5 = five, hash_comments = true, duplicate_keys = true }, where)
        if not ok then return false, why end
        if read then Fuzz.label(five and "read as JSON5" or "read") end
        if text ~= input then
          Fuzz.label("held a # comment")
          local _, err = Json.decode(text, { json5 = five, duplicate_keys = true })
          if err == "" then return false, where .. ": read a # comment without hash_comments" end
        end
      end
      return true, ""
    end,
    shares = { read = 0.3, ["read as JSON5"] = 0.4, ["held a # comment"] = 0.05 },
  })
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

--- The JSON Pointer to the container the `limit + 1`th open of
--- `opens` starts, as a message names it: `/0` into each array and
--- `/k` into each object before it. Only its innermost segments are
--- kept when they run past the 199 bytes a message's pointer holds,
--- named then as the pointer's ending.
local function path_into(opens: string, limit: integer): string
  local segments: {string} = {}
  for open in opens:gmatch("[%[{]") do
    if #segments == limit then break end
    segments[#segments + 1] = open == "[" and "/0" or "/k"
  end
  local kept, length = "", 0
  for i = #segments, 1, -1 do
    if length + #segments[i] >= 200 then return 'pointer ending "' .. kept .. '"' end
    kept = segments[i] .. kept
    length = length + #segments[i]
  end
  return 'pointer "' .. kept .. '"'
end

-- Most drawn texts parse -- 44% strictly and 51% as JSON5, far above
-- the 13% and 15% that edits and token soup alone reach -- so the walk
-- into Lua values and the re-encoding checks run on most; a share under
-- a fifth fails the run. A key twice is too rare among them (one input
-- in fifty) for a share of 64 inputs to hold; the key-twice property
-- below draws it.
local function test_decode_is_total_on_mutated_json(tmp: string)
  Fuzz.run({ name = "json decode total", dir = tmp, gen = gen_text, check = decode_holds,
    shares = { decoded = 0.2, ["decoded as JSON5"] = 0.2, ["oracle saw no key twice"] = 0.2 } })
end

--- Texts that hold a key twice, or do not, with the answer known from
--- how each was drawn: a member's key is written where the text records
--- it, so the first key to repeat one of its own object's, in text
--- order, is the one decode must name, with the line and column it
--- starts at and the pointer to it. Nothing here reads core/json.c's
--- check.
local record Shape
  --- The members the object holds, set when it is whole.
  count: integer
end

--- The first key written that repeats an earlier one of its object.
local record Repeat
  --- The 1-based byte offset in the text where the key starts.
  at: integer
  --- The JSON Pointer to the member, as a message names it.
  pointer: string
  --- Whether it is spelled otherwise than the key it repeats.
  spelled: boolean
  --- The containers open around the object that holds it.
  depth: integer
  --- That object, whose size says which way core/json.c looked.
  object: Shape
end

--- A text being written.
local record Built
  parts: {string}
  --- The bytes in `parts`.
  length: integer
  json5: boolean
  --- Whether objects but the top one repeat no key, so that a key twice
  --- in a large top object is the first in the text.
  quiet: boolean
  first: Repeat
end

--- FNV-1a as core/json.c's `key_hash` computes it. A change to that hash
--- leaves these keys no longer colliding, and nothing here fails: change
--- this copy with it.
local function fnv(s: string): integer
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
  return h
end

--- Keys whose hashes share their low 7 bits, so that in a set of 32,
--- 64 or 128 slots (what 9 to 64 members take) each probes from the
--- slot the one before it filled.
local COLLIDING <const>: {string} = (function(): {string}
  local keys: {string} = {}
  local n = 0
  while #keys < 20 do
    local key = "h" .. n
    if fnv(key) & 127 == 0 then keys[#keys + 1] = key end
    n = n + 1
  end
  return keys
end)()

--- Names a key is drawn from before numbered ones: one that a pointer
--- escapes, empty, multibyte, astral, with a NUL, a line end, a quote,
--- a backslash, a word cannot be, and keys that differ only in their
--- last byte.
local NAMES <const> = { "a", "b", "k", "", "\xc3\xa9", "a b", "x~y", "p/q", "\0", "\n", '"', "\\",
  "\xf0\x9f\x98\x80", "ab", "ac", "a\xc3\xa9", "a\xc3\xa8" }

--- Gaps between tokens. Strict JSON has whitespace; JSON5 has comments
--- that hold line ends, and U+2028 and U+2029.
local OFFICIAL_GAPS <const> = { "", "", "", " ", "\n", "\t", "\r\n", "\r" }
local JSON5_GAPS <const> = { "/* c */", "// c\n", "/* a\nb */", "\xe2\x80\xa8", "\xe2\x80\xa9", "\xc2\xa0" }

local function emit(b: Built, text: string)
  b.parts[#b.parts + 1] = text
  b.length = b.length + #text
end

--- A gap, which before a key is never one of the Unicode spaces: the
--- JSON5 reader refuses a bare key after one.
local function gap(src: Fuzz.Source, b: Built, before_key: boolean)
  if b.json5 and src:int(0, 3) == 0 then
    local choice = Fuzz.pick(src, JSON5_GAPS)
    emit(b, before_key and choice:byte(1) > 127 and " " or choice)
  else
    emit(b, Fuzz.pick(src, OFFICIAL_GAPS))
  end
end

--- The ways one character of a key may be written in a quoted string,
--- the plainest first.
local function forms_of(ch: string, json5: boolean): {string}
  local code = utf8.codepoint(ch)
  local forms: {string} = {}
  if code >= 32 and ch ~= '"' and ch ~= "\\" then forms[1] = ch end
  if ch == "\n" then forms[#forms + 1] = "\\n" end
  if ch == '"' then forms[#forms + 1] = '\\"' end
  if ch == "\\" then forms[#forms + 1] = "\\\\" end
  if ch == "/" then forms[#forms + 1] = "\\/" end
  if code >= 0x10000 then
    local high, low = 0xd800 + ((code - 0x10000) >> 10), 0xdc00 + ((code - 0x10000) & 0x3ff)
    forms[#forms + 1] = ("\\u%04x\\u%04x"):format(high, low)
    forms[#forms + 1] = ("\\u%04X\\u%04X"):format(high, low)
  else
    forms[#forms + 1] = ("\\u%04x"):format(code)
    forms[#forms + 1] = ("\\u%04X"):format(code)
  end
  if json5 and code < 256 then forms[#forms + 1] = ("\\x%02x"):format(code) end
  return forms
end

--- `key` spelled as a text may: quoted, each character plain or
--- another way, and in JSON5 also single-quoted, with `\x` escapes, or
--- bare. A key of a large object is mostly written plain, since the
--- draws for 70 members would dominate a run.
local function spell(src: Fuzz.Source, key: string, json5: boolean, large: boolean): string
  local plain = large and src:int(0, 3) ~= 0
  if json5 and not plain and key:match("^[%a_$][%w_$]*$") and src:int(0, 3) == 0 then return key end
  local quote = json5 and not plain and src:int(0, 3) == 0 and "'" or '"'
  local varied = not plain
  local body: {string} = {}
  for ch in key:gmatch(utf8.charpattern) do
    local forms = forms_of(ch, json5)
    body[#body + 1] = varied and src:int(0, 2) == 0 and Fuzz.pick(src, forms) or forms[1]
  end
  return quote .. table.concat(body) .. quote
end

--- `pointer` as a message writes it inside quotes: a quote or backslash
--- escaped, a control character as `\u00XX`.
local function quoted(pointer: string): string
  return (pointer:gsub('[%c"\\]', function(c: string): string
    if c == '"' or c == "\\" then return "\\" .. c end
    return ("\\u%04x"):format(c:byte())
  end))
end

--- `key` as a pointer's segment.
local function segment(key: string): string
  return "/" .. key:gsub("~", "~0"):gsub("/", "~1")
end

local gen_member_value: function(Fuzz.Source, Built, integer, string, integer)

--- An object of `size` members at least, and `more` draws up to `most`
--- unless `exact`, written into `b` at `path`, `depth` containers open
--- around it. Each member after the first repeats an earlier key at the
--- rate its object draws, some objects never repeating; `large` says
--- the object is one whose members are many, so the rate is per
--- member lower.
local function gen_object(src: Fuzz.Source, b: Built, depth: integer, path: string,
                          size: integer, most: integer, exact: boolean, large: boolean)
  emit(b, "{")
  local names: {string} = {}
  local spelling: {string: string} = {}
  local shape: Shape = { count = 0 }
  local rate = b.quiet and not large and 0 or Fuzz.pick(src, large and { 0, 3, 4, 4 } or { 0, 2, 3, 4, 5 })
  local colliding = src:int(0, 3) == 0
  local count = 0
  while count < size or (not exact and Fuzz.more(src, count, most)) do
    if count > 0 then emit(b, ",") end
    gap(src, b, true)
    local key: string
    if count > 0 and src:int(0, large and 30 or 6) < rate then
      key = names[src:int(1, #names)]
    else
      local fresh = #names + 1
      if colliding and fresh <= #COLLIDING then
        key = COLLIDING[fresh]
      elseif fresh <= #NAMES then
        key = NAMES[fresh]
      else
        key = "k" .. #names
      end
      names[#names + 1] = key
    end
    local written = spell(src, key, b.json5, large)
    if b.first == nil and spelling[key] ~= nil then
      b.first = { at = b.length + 1, pointer = path .. segment(key), depth = depth,
        spelled = written ~= spelling[key], object = shape }
    end
    spelling[key] = spelling[key] or written
    emit(b, written)
    if not large then gap(src, b, false) end
    emit(b, ":")
    if not large then gap(src, b, false) end
    gen_member_value(src, b, depth, path .. segment(key), large and 8 or 3)
    if not large then gap(src, b, false) end
    count = count + 1
  end
  shape.count = count
  if b.json5 and count > 0 and src:int(0, 3) == 0 then emit(b, ",") end
  emit(b, "}")
end

--- A member's value: usually a scalar, a null often, else a small
--- array or object, one in `nest_in` draws.
gen_member_value = function(src: Fuzz.Source, b: Built, depth: integer, path: string, nest_in: integer)
  if depth >= 4 or src:int(0, nest_in) ~= 0 then
    emit(b, Fuzz.pick(src, { "null", "null", "1", "true", '"s"', "2.5" }))
  elseif src:int(0, 2) == 0 then
    emit(b, "[")
    local n = 0
    while Fuzz.more(src, n, 3) do
      if n > 0 then emit(b, ",") end
      gap(src, b, false)
      gen_member_value(src, b, depth + 1, path .. "/" .. n, 1)
      gap(src, b, false)
      n = n + 1
    end
    emit(b, "]")
  else
    gen_object(src, b, depth + 1, path, 0, 6, false, false)
  end
end

--- The line and column of byte `at` of `text`, counted from 1, a line
--- ending at \n, \r or \r\n, and in JSON5 at U+2028 and U+2029 too.
local function place(text: string, at: integer, json5: boolean): integer, integer
  local line, column = 1, 1
  local i = 1
  while i < at do
    local c = text:sub(i, i)
    if c == "\r" and text:sub(i + 1, i + 1) == "\n" then i = i + 1 end
    local separator = text:sub(i, i + 2)
    if json5 and (separator == "\xe2\x80\xa8" or separator == "\xe2\x80\xa9") then
      i = i + 2
      c = "\n"
    end
    if c == "\n" or c == "\r" then
      line, column = line + 1, 1
    else
      column = column + 1
    end
    i = i + 1
  end
  return line, column
end

--- An input for [`repeating_holds`], packed with [`Fuzz.pack`]: a text,
--- whether it is JSON5, the options to read it under, what decode must
--- answer (empty for a text with no key twice) and the labels for what
--- the repeat is. The top object has the size that decides how
--- core/json.c looks for a key twice: at most 8 members, 9 to 64, or 65
--- and more, with the edges of each drawn on their own; and sits bare,
--- in an array or in an object. A top object of more than 8 members
--- holds no repeat in the objects below it, so its own is the first.
local function gen_repeating(src: Fuzz.Source): string
  local b: Built = { parts = {}, length = 0, json5 = src:int(0, 2) == 0 }
  local wrap = src:int(0, 2)
  local path = ""
  if wrap == 1 then
    emit(b, "[1,")
    path = "/1"
  elseif wrap == 2 then
    emit(b, '{"w":')
    path = "/w"
  end
  local depth = wrap == 0 and 1 or 2
  local size, most, exact = 2, 8, false
  local shape = src:int(0, 7)
  if shape == 4 then
    size, exact = Fuzz.pick(src, { 8, 9, 64, 65 }), true
  elseif shape == 5 or shape == 6 then
    size, most = 9, 64
  elseif shape == 7 then
    size, most = 65, 70
  end
  b.quiet = size > 8
  -- A strict text reads as JSON5 too, which is drawn half the time.
  local as_json5 = b.json5 or src:int(0, 1) == 0
  local null_value = src:int(0, 1) == 0
  gap(src, b, false)
  gen_object(src, b, depth, path, size, most, exact, size > 8)
  gap(src, b, false)
  emit(b, wrap == 1 and "]" or wrap == 2 and "}" or "")
  local text = table.concat(b.parts)
  local expected, labels = "", {} as {string}
  local first = b.first
  if first ~= nil then
    local line, column = place(text, first.at, b.json5)
    expected = ('json: duplicate key at line %d, column %d (pointer "%s")'):format(line, column, quoted(first.pointer))
    local n = first.object.count
    labels[#labels + 1] = n <= 8 and "key twice in 8 or fewer" or n <= 64 and "key twice in 9 to 64" or
      "key twice in more than 64"
    if first.spelled then labels[#labels + 1] = "key twice spelled otherwise" end
    if first.depth > 1 then labels[#labels + 1] = "key twice in a nested object" end
  end
  return Fuzz.pack({ text, b.json5 and "json5" or "", as_json5 and "json5" or "", null_value and "null" or "",
    expected, table.concat(labels, ";") })
end

local function repeating_holds(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local text, as_json5, null_value = fields[1], fields[3] == "json5", fields[4] == "null"
  local expected, labels = fields[5], fields[6]
  for label in (expected == "" and "no key twice" or labels):gmatch("[^;]+") do
    Fuzz.label(label)
  end
  local opts: Json.DecodeOptions = { json5 = as_json5, null_value = null_value and Json.null or nil }
  local where = ("json5=%s null_value=%s"):format(tostring(as_json5), tostring(null_value))
  local value, err = Json.decode(text, opts)
  if err ~= expected then
    return false, where .. ": decode said \"" .. err .. "\", expected \"" .. expected .. "\""
  end
  if expected ~= "" and value ~= nil then return false, where .. ": a refusal with a value" end
  local ok, check_err = Json.check(text, { json5 = as_json5 })
  if ok ~= (expected == "") or check_err ~= expected then
    return false, where .. ": check said \"" .. check_err .. "\""
  end
  if expected ~= "" then
    local _, format_err = Json.format(text, { json5 = as_json5 })
    if format_err ~= expected then
      return false, where .. ": format said \"" .. format_err .. "\""
    end
  end
  opts.duplicate_keys = true
  local _, allowed = Json.decode(text, opts)
  if allowed ~= "" then return false, where .. ": duplicate_keys refused: " .. allowed end
  return true, ""
end

-- Whether a text holds a key twice is known from how it is drawn, not
-- from decode: the object that has one is drawn at each size the walk
-- tells apart -- compared pair by pair (8 or fewer members), through a
-- set (9 to 64) and through the table being built (65 or more) -- its
-- keys including ones that share a hash, and the repeat spelled as
-- escapes, quotes or bare in JSON5, the object nested, and the first
-- repeat in the text is the one named, by line, column and pointer.
-- Decode, check and format are held to it, each input under one choice
-- of JSON5 and of a stand-in for null. What a repeat of a key is
-- compared as is checked only for what the names and spellings reach:
-- the NUL, empty, multibyte and astral keys, and keys differing in
-- their last byte. A break that overlooks a repeat of one particular
-- key, the empty one say, in objects of one size is found only once a
-- draw repeats that key there: a few hundred inputs, not 64. A share
-- well under what a run reaches fails the run.
-- TODO: a key twice under `lone_surrogates` is not drawn: it reads two
-- different lone surrogates in keys as one key, U+FFFD twice; spell
-- them in keys and expect the repeat.
local function test_a_refusal_for_a_key_twice_is_exactly_a_key_twice(tmp: string)
  Fuzz.run({
    name = "json key twice",
    dir = tmp,
    gen = gen_repeating,
    check = repeating_holds,
    -- An input draws hundreds of values for its large objects, so each
    -- costs several times a mutated text.
    max_iters = 3000,
    requires = { "no key twice", "key twice in 8 or fewer", "key twice in 9 to 64",
      "key twice in more than 64", "key twice spelled otherwise", "key twice in a nested object" },
    shares = { ["no key twice"] = 0.1, ["key twice in 8 or fewer"] = 0.1, ["key twice in 9 to 64"] = 0.05,
      ["key twice in more than 64"] = 0.03, ["key twice spelled otherwise"] = 0.1,
      ["key twice in a nested object"] = 0.1 },
  })
end

--- What the text-to-text functions hold to on `input`, read as RFC
--- 8259 and as JSON5: `check` answers what `decode` does; `format`
--- reads what `decode` reads, with its messages, refusing beyond it only
--- NaN and the infinities, writes text that decodes to the same value and formats
--- to itself, compact or laid out; `canonical` is a fixed point, the
--- same through `format` and through `decode` and `encode`.
local function text_holds(input: string): boolean, string
  for _, json5 in ipairs({ false, true }) do
    local where = json5 and "JSON5" or "RFC 8259"
    local value, err = Json.decode(input, { null_value = Json.null, json5 = json5 })
    local ok, check_err = Json.check(input, { json5 = json5 })
    if ok ~= (err == "") or (not ok and check_err ~= err) then
      return false, where .. ": check said " .. check_err .. ", decode " .. err
    end
    local compact, ferr = Json.format(input, { json5 = json5 })
    if compact == nil then
      if err == "" and not ferr:match("^json: cannot format ") then
        return false, where .. ": format refused what decode read: " .. ferr
      end
      if err ~= "" and ferr ~= err then
        return false, where .. ": format refused otherwise than decode: " .. ferr .. " vs " .. err
      end
    else
      if err ~= "" then return false, where .. ": format read what decode refused: " .. err end
      Fuzz.label(json5 and "formatted JSON5" or "formatted")
      -- JSON5 reads a number past a double's range, as an infinity; RFC
      -- 8259 refuses it, so the text is read back as the input was.
      local back, berr = Json.decode(compact, { null_value = Json.null, max_depth = 1000, json5 = json5 })
      if berr ~= "" then return false, where .. ": format wrote what decode refuses: " .. berr end
      if canonical(back, where) ~= canonical(value, where) then
        return false, where .. ": format changed the value: " .. compact
      end
      if Json.format(compact, { json5 = json5 }) ~= compact then
        return false, where .. ": format is no fixed point: " .. compact
      end
      local pretty = Json.format(input, { json5 = json5, pretty = true })
      if pretty == nil or Json.format(pretty, { json5 = json5 }) ~= compact then
        return false, where .. ": laid out, it is not the same text: " .. tostring(pretty)
      end
    end
    local jcs, cerr = Json.canonical(input, { json5 = json5 })
    if jcs ~= nil then
      Fuzz.label("canonical")
      if Json.canonical(jcs) ~= jcs then
        return false, where .. ": canonical is no fixed point: " .. jcs
      end
      if compact == nil or Json.canonical(compact) ~= jcs then
        return false, where .. ": canonical differs through format: " .. jcs
      end
      local encoded = Json.encode(finite(value), CANONICAL)
      if encoded == nil or Json.canonical(encoded) ~= jcs then
        return false, where .. ": canonical differs through decode and encode: " .. jcs
      end
    elseif compact ~= nil and not (cerr:match("^json: cannot format ") or cerr:match("infinity")) then
      return false, where .. ": canonical refused what format wrote: " .. cerr
    end
  end
  return true, ""
end

local function test_text_to_text_holds_on_mutated_json(tmp: string)
  Fuzz.run({ name = "json text to text", dir = tmp, gen = gen_text, check = text_holds,
    shares = { formatted = 0.15, ["formatted JSON5"] = 0.15, canonical = 0.1 } })
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
-- first, unlike the generators here, so cutting a recipe's bytes drops
-- a middle element only by reshaping everything after it; a byte before
-- each element whose low values stop, as [`Fuzz.more`] draws, would let
-- shrinking drop any (measure "encoded" and "refused" again).
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
  local opts: Json.EncodeOptions = { pretty = bits & 1 ~= 0 }
  if bits & 2 ~= 0 then opts.max_depth = next_byte(r) % 8 + 1 end
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
    -- A path too long to tell whole names its innermost part.
    if err:find(" at ", 1, true) and not err:find(' at pointer "', 1, true) and
        not err:find(' at pointer ending "', 1, true) then
      return false, "a location that is not a pointer: " .. err
    end
    return true, ""
  end
  if err ~= "" then return false, "a success with a message: " .. err end
  local expected, eerr = Json.encode(value, { max_depth = opts.max_depth })
  if expected == nil then
    return false, "encoded laid out, but not compactly: " .. eerr
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
      while Fuzz.more(src, #opens, 1200) do
        opens[#opens + 1] = src:int(0, 1) == 0 and "[" or '{"k":'
      end
      return Fuzz.pack({ table.concat(opens), tostring(src:int(1, 1000)) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local opens, limit = fields[1], math.tointeger(tonumber(fields[2])) as integer
      local closes = opens:reverse():gsub(":\"k\"{", "}"):gsub("%[", "]")
      local _, n = opens:gsub("[%[{]", "")
      local value, err = Json.decode(opens .. "1" .. closes, { max_depth = limit })
      if n <= limit then
        if err ~= "" then
          return false, ("%d levels under a limit of %d: %s"):format(n, limit, err)
        end
      elseif value ~= nil or err ~= ("json: JSON nests deeper than %d level%s at line 1, column %d (%s)"):
          format(limit, limit == 1 and "" or "s", deepest(opens, limit + 1), path_into(opens, limit)) then
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

--- JSON Lines text: samples a line each, joined by any line end, then
--- mutated.
local function gen_lines(src: Fuzz.Source): string
  local lines: {string} = {}
  while Fuzz.more(src, #lines, 5) do lines[#lines + 1] = Fuzz.pick(src, SAMPLES):gsub("\n", " ") end
  return Fuzz.mutate(src, table.concat(lines, Fuzz.pick(src, { "\n", "\r\n", "\n\n" })), 6)
end

local function test_json_lines_are_total_and_round_trip(tmp: string)
  Fuzz.run({
    name = "json lines",
    dir = tmp,
    gen = gen_lines,
    check = function(input: string): boolean, string
      local ok, values, err = pcall(Json.decode_lines, input,
        { null_value = Json.null, json5 = true, duplicate_keys = true })
      if not ok then return false, "raised: " .. tostring(values) end
      if values == nil then
        if err == "" then return false, "a failure without a message" end
        return true, ""
      end
      local written: {string} = {}
      for i = 1, #values do
        local line, eerr = Json.encode(finite(values[i]))
        if line == nil then return false, "decoded line " .. i .. " did not encode: " .. eerr end
        written[i] = line .. "\n"
      end
      local text = table.concat(written)
      local back, berr = Json.decode_lines(text, { null_value = Json.null })
      if back == nil then return false, "encoded lines are what decode_lines refuses: " .. berr end
      local a, b = Json.encode(finite(values), CANONICAL), Json.encode(finite(back), CANONICAL)
      if a ~= b then
        return false, "lines did not read back the same: " .. tostring(a) .. " vs " .. tostring(b)
      end
      return true, ""
    end,
  })
end
