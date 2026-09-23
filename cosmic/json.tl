--- JSON text to Lua values and back.
---
--- Reading is RFC 8259 and nothing else: no comments, no trailing
--- commas, no NaN, and a string must be UTF-8 with no lone surrogate.
--- A failure names the line and column where the text stopped being
--- JSON. The reader is yyjson, vendored and fuzzed upstream.
---
--- `decode(text, { json5 = true })` reads JSON5 instead -- comments,
--- trailing commas, single-quoted strings, unquoted keys, hexadecimal
--- and `+`/`.5`/`5.` numbers, NaN and Infinity -- for text people
--- write, like configuration. yyjson's JSON5 is a little wider than
--- the specification: it also takes escapes such as `\a` and `\e`,
--- unquoted keys with any character past U+007F, and `nan`, `inf` and
--- `infinity` in any case. Output is always RFC 8259, which every JSON5
--- reader reads.
---
---     local value, err = Json.decode('{"name": "cosmic", "tags": ["lua"]}')
---     if err ~= "" then error(err) end
---
--- Every fallible function answers `value, ""` on success and
--- `nil, message` on failure, so test the message, not the value: a
--- document that is just `null` decodes to nil with an empty message.
---
--- A number decodes to an integer when it is written as one and fits
--- in 64 bits, and to a float otherwise, so `9007199254740993` survives
--- a round trip exactly and `1.0` stays a float. An encoded float is
--- the shortest text that reads back to the same float.
---
--- Lua tables cannot hold nil, so JSON `null` decodes to nil by
--- default: a null-valued key is absent, and a null in an array leaves
--- a hole. Two opt-in escapes close the round trip:
---
--- - `decode(text, { null_value = Json.null })` puts `Json.null` where
---   the text says `null`, and `Json.null` encodes as `null`.
--- - `encode(value, { sparse_as_null = true })` writes an array's
---   holes as `null`; without it, an array with a hole is an error,
---   never a silent truncation.
---
--- A decoded array carries a mark (`Json.is_array`), so an empty `[]`
--- encodes back as `[]` and not `{}`; `Json.array` marks a table you
--- build. An unmarked table is an object when every key is a string, an
--- array when every key is an integer from 1 up, and an error when its
--- keys mix the two or are anything else.
---
--- Duplicate keys are allowed, and the last one stands. Encoded
--- objects list their keys in byte order unless `sorted = false`, so
--- the same value always encodes to the same text.

--- The raw module behind this one lives under the reserved
--- `cosmic.internal.` namespace -- see cosmic/sqlite.tl for why this
--- indirection exists.
local type raw_json = require("cosmic.internal.json")

local extra: any = select(2, ...)
local raw: raw_json
if type(extra) == "table" then
  raw = extra as raw_json
else
  raw = require("cosmic.internal.json")
end

local record Json
  --- What `encode` may be told. Every field is optional.
  record EncodeOptions
    --- Lay the text out over lines, one member or element to a line
    --- (default false).
    pretty: boolean
    --- One level's indentation when `pretty`: spaces and tabs only
    --- (default two spaces).
    indent: string
    --- List an object's keys in byte order (default true). False
    --- lists them in table order, which is faster and differs run to
    --- run.
    sorted: boolean
    --- How many arrays and objects may nest, 1 to 1000 (default 64).
    --- A table that contains itself fails here.
    max_depth: integer
    --- Write NaN and the infinities as `null` rather than failing
    --- (default false).
    nan_as_null: boolean
    --- Write an array's holes as `null` rather than failing (default
    --- false). An array whose highest index is past 10 and past twice
    --- its number of values still fails, as too sparse to mean.
    sparse_as_null: boolean
  end

  --- What `decode` may be told. Every field is optional.
  record DecodeOptions
    --- What to put where the text says `null`, so a Lua table can hold
    --- it. `Json.null` is the usual choice: it encodes back as `null`.
    null_value: any
    --- How many arrays and objects may nest, 1 to 1000 (default 64).
    max_depth: integer
    --- Read JSON5 rather than RFC 8259 JSON (default false). NaN and
    --- Infinity decode to the float they name.
    json5: boolean
    --- Decode an integer that does not fit in 64 bits, or a number
    --- past a double's range, as its digits in a string rather than
    --- the nearest float (default false): `18446744073709551615` stays
    --- exact as `"18446744073709551615"`. For large unsigned IDs. It
    --- encodes back as a string, not a number.
    big_numbers_as_strings: boolean
  end

  --- The stand-in for JSON `null`: pass it as `null_value` to keep a
  --- document's nulls, and it encodes as `null`. It is a userdata, so
  --- indexing it by mistake raises; `v == Json.null` is the test.
  null: any
end

Json.null = raw.null

--- The value `text` holds, and "". nil and a message, naming the line
--- and column, when the text is not one JSON value or nests past
--- `max_depth`. The value is `any`: when the text is from outside,
--- narrow it with `is` before trusting its shape, or use
--- `decode_object` or `decode_array`, which check the outermost one.
function Json.decode(text: string, opts?: Json.DecodeOptions): any | nil, string
  if opts == nil then
    return raw.decode(text)
  end
  return raw.decode(text, opts.null_value, opts.max_depth, opts.json5,
    opts.big_numbers_as_strings)
end

--- What JSON calls a decoded value, for a wrong-shape message.
local function kind(v: any): string
  if v == nil or rawequal(v, raw.null) then
    return "null"
  end
  if type(v) == "table" then
    return raw.is_array(v) and "array" or "object"
  end
  return type(v)
end

--- The object `text` holds, as a map, and "". nil and a message when
--- the text is not JSON, or its outermost value is not an object.
function Json.decode_object(text: string, opts?: Json.DecodeOptions): {string: any} | nil, string
  local value, err = Json.decode(text, opts)
  if err ~= "" then
    return nil, err
  end
  if value is {string: any} and not raw.is_array(value) then
    return value, ""
  end
  return nil, "expected a JSON object, got " .. kind(value)
end

--- The array `text` holds, as a list, and "". nil and a message when
--- the text is not JSON, or its outermost value is not an array.
function Json.decode_array(text: string, opts?: Json.DecodeOptions): {any} | nil, string
  local value, err = Json.decode(text, opts)
  if err ~= "" then
    return nil, err
  end
  if value is {any} and raw.is_array(value) then
    return value, ""
  end
  return nil, "expected a JSON array, got " .. kind(value)
end

--- `value` as JSON text, and "". nil and a message when it holds a
--- function, userdata other than `Json.null`, NaN or an infinity, a
--- string that is not UTF-8, a table whose keys are neither all strings
--- nor all integers from 1 up, an array with a hole, or nesting past
--- `max_depth`. The message says where, as a path from the value:
--- `cannot encode a function at $.users[3].name`, with array indices
--- counted from 1 as Lua counts them. nil encodes as `null`.
function Json.encode(value: any, opts?: Json.EncodeOptions): string | nil, string
  if opts == nil then
    return raw.encode(value)
  end
  return raw.encode(value, opts.pretty, opts.indent, opts.sorted,
    opts.max_depth, opts.nan_as_null, opts.sparse_as_null)
end

--- The values of JSON Lines text (NDJSON): one JSON value to a line,
--- in a marked array, and "". A blank line is skipped, and a line may
--- end in `\r\n`. nil and a message naming the line when one is not
--- JSON. `opts` applies to every line; a `null` line leaves a hole
--- unless `null_value` is given.
function Json.decode_lines(text: string, opts?: Json.DecodeOptions): {any} | nil, string
  local values = raw.array()
  local number = 0
  local count = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    if line:find("%S") then
      count = count + 1
      local value, err = Json.decode(line, opts)
      if err ~= "" then
        local located = err:gsub("^invalid JSON at line 1,", "invalid JSON at line " .. number .. ",")
        if located == err then
          located = "line " .. number .. ": " .. err
        end
        return nil, located
      end
      values[count] = value
    end
  end
  return values, ""
end

--- `values[1]` to `values[#values]` as JSON Lines text: each value's
--- compact JSON on its own line, every line ending in a newline, and
--- "". nil and a message naming the value when one cannot be encoded.
--- `pretty` is ignored, since a value must keep to its line.
function Json.encode_lines(values: {any}, opts?: Json.EncodeOptions): string | nil, string
  local line_opts: Json.EncodeOptions = {}
  if opts ~= nil then
    line_opts = {
      sorted = opts.sorted, max_depth = opts.max_depth,
      nan_as_null = opts.nan_as_null, sparse_as_null = opts.sparse_as_null,
    }
  end
  local lines: {string} = {}
  for i = 1, #values do
    local text, err = Json.encode(values[i], line_opts)
    if text == nil then
      return nil, "value " .. i .. ": " .. err
    end
    lines[i] = text
  end
  if #lines == 0 then
    return "", ""
  end
  return table.concat(lines, "\n") .. "\n", ""
end

--- Marks `t` as a JSON array, so it encodes as `[]` even when empty,
--- and answers it; with no argument, a new empty one. Raises when `t`
--- already has a metatable of its own.
function Json.array(t?: {any}): {any}
  return raw.array(t)
end

--- Whether `v` is a table marked as a JSON array: one `decode` built,
--- or one `Json.array` marked.
function Json.is_array(v: any): boolean
  return raw.is_array(v)
end

return Json
