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
--- `decode(text, { hash_comments = true })` also reads `#` line
--- comments, which neither JSON nor JSON5 has, in either. With `json5`,
--- it reads a text that YAML reads too, written in YAML's flow style:
--- a GitHub workflow, say, with double-quoted strings, keys quoted
--- unless they are identifiers YAML reads as their text (`on`, `no`
--- and `null` it does not), a space after each `:`, and a space before
--- each `#`. build/workflows_test.tl holds the tree's workflows to
--- that subset.
---
---     local text = '{\n  # what GitHub shows\n  name: "ci",\n}'
---     local workflow = assert(Json.decode_object(text, { json5 = true, hash_comments = true }))
---     assert(workflow.name == "ci")
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
--- To explore a document whose shape is not known, `Json.encode(v,
--- { pretty = true })` dumps a value and `Json.describe(v)` summarizes
--- its shape, keys sorted, each array as its length and one merged
--- element shape. `Json.get(v, { "a", 1, "b" })` reaches into it, and
--- `Json.entries` and `Json.items` narrow an object or an array so a
--- caller can `pairs` or `ipairs` it without a cast.
---
--- `Json.quote` and `Json.child_path` spell a key or a path (`$.rows[2]`)
--- in a message of your own, and `Json.parse_path` reads one back.
---
--- Duplicate keys are allowed, and the last one stands. Encoded
--- objects list their keys in byte order unless `sorted = false`, so
--- the same value always encodes to the same text.

--- The raw module behind this one lives under the reserved
--- `cosmic.internal.` namespace -- see cosmic/store.tl for why this
--- indirection exists.
local type raw_json = require("cosmic.internal.json")

local extra: any = select(2, ...)
local raw: raw_json
if type(extra) == "table" then
  raw = extra as raw_json
else
  raw = require("cosmic.internal.json")
end

local Stream = require("cosmic.stream")
local String = require("cosmic.string")

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
    --- How many arrays and objects may nest, 1 to `Json.depth_limit`
    --- (1000; default `Json.default_depth`, 64). A table that contains
    --- itself fails here.
    max_depth: integer
    --- Write NaN and the infinities as `null` rather than failing
    --- (default false).
    nan_as_null: boolean
    --- Write an array's holes as `null` rather than failing (default
    --- false). An array whose highest index is past 10 and past twice
    --- its number of values still fails, as too sparse to mean.
    sparse_as_null: boolean
    --- Write every character past ASCII as a `\u` escape, a surrogate
    --- pair past U+FFFF (default false): for JSON embedded in HTML or
    --- JavaScript, where U+2028 and U+2029 end a line, or read by a
    --- tool that takes only ASCII.
    ascii: boolean
  end

  --- What `decode` may be told. Every field is optional.
  record DecodeOptions
    --- What to put where the text says `null`, so a Lua table can hold
    --- it. `Json.null` is the usual choice: it encodes back as `null`.
    null_value: any
    --- How many arrays and objects may nest, 1 to `Json.depth_limit`
    --- (1000; default `Json.default_depth`, 64).
    max_depth: integer
    --- Read JSON5 rather than RFC 8259 JSON (default false). NaN and
    --- Infinity decode to the float they name.
    json5: boolean
    --- Read a line comment that begins with `#`, as YAML and shells
    --- write one, besides whatever else the text is (default false). It
    --- ends where a `//` comment would.
    hash_comments: boolean
    --- Decode an integer that does not fit in 64 bits, or a number
    --- past a double's range, as its digits in a string rather than
    --- the nearest float (default false): `18446744073709551615` stays
    --- exact as `"18446744073709551615"`. For large unsigned IDs. It
    --- encodes back as a string, not a number.
    big_numbers_as_strings: boolean
    --- Read a lone surrogate escape -- `\ud83d` with no low half after
    --- it, or a low half alone -- as U+FFFD rather than failing
    --- (default false), for text a writer cut in the middle of a
    --- character, as Python's json module and Claude Code transcripts
    --- can hold. A pair still reads as the character it names. Keys
    --- that differ only in their lone surrogates become the same key,
    --- and the last one stands.
    lone_surrogates: boolean
  end

  --- The values of a JSON Lines Reader, one at a time: see `Json.lines`.
  record Lines
    --- The next value, and ""; nil and "" after the last; nil and why
    --- when a line is not JSON, runs past the limit, or the Reader
    --- failed, the same again on every later read.
    read: function(Lines): any | nil, string
    --- An iterator for a `for` loop over the values still to come. It
    --- ends at the last one or at a failure, which `failure` then says.
    each: function(Lines): function(): any
    --- Why the values ended early, or "" when they have not: after an
    --- `each` loop, "" means every value was read.
    failure: function(Lines): string
  end

  --- What `describe` may be told. Every field is optional.
  record DescribeOptions
    --- How many arrays and objects may nest in the summary before the
    --- rest is shown as `...` (default 6). 0 shows only the outermost
    --- value's kind.
    max_depth: integer
  end

  --- The stand-in for JSON `null`: pass it as `null_value` to keep a
  --- document's nulls, and it encodes as `null`. It is a userdata, so
  --- indexing it by mistake raises; `v == Json.null` is the test.
  null: any

  --- How many arrays and objects may nest when `max_depth` is not
  --- given: 64.
  default_depth: integer

  --- The most `max_depth` may be: 1000. Each level of nesting is a
  --- level of recursion in the core, on the C stack.
  depth_limit: integer
end

Json.null = raw.null
Json.default_depth = raw.default_depth
Json.depth_limit = raw.depth_limit

--- `raw.decode` of `text` under `opts`; `record`, when given, is the
--- JSON Lines line `text` is, which a failure names.
local function decode_with(text: string, opts: Json.DecodeOptions, record?: integer): any | nil, string
  return raw.decode(text, opts.null_value, opts.max_depth, opts.json5,
    opts.big_numbers_as_strings, opts.lone_surrogates, record, opts.hash_comments)
end

--- The value `text` holds, and "". nil and a message, naming the line
--- and column, when the text is not one JSON value or nests past
--- `max_depth`. The value is `any`: when the text is from outside,
--- narrow it with `is` before trusting its shape, or use
--- `decode_object` or `decode_array`, which check the outermost one.
function Json.decode(text: string, opts?: Json.DecodeOptions): any | nil, string
  if opts == nil then
    return raw.decode(text)
  end
  return decode_with(text, opts)
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
    opts.max_depth, opts.nan_as_null, opts.sparse_as_null, opts.ascii)
end

--- The values of JSON Lines text (NDJSON): one JSON value to a line,
--- in a marked array, and "". A blank line is skipped, and a line may
--- end in `\r\n`. nil and a message naming the line when one is not
--- JSON. `opts` applies to every line; a `null` line leaves a hole
--- unless `null_value` is given. `Json.lines` reads them from a
--- `cosmic.stream` Reader instead, one at a time, in bounded memory.
function Json.decode_lines(text: string, opts?: Json.DecodeOptions): {any} | nil, string
  local values = raw.array()
  local number = 0
  local count = 0
  local line_opts: Json.DecodeOptions = opts or {}
  for line in String.lines(text) do
    number = number + 1
    if line:find("%S") then
      count = count + 1
      -- The record's own number names a failure's line: the decoder
      -- would otherwise count a lone \r (or, in JSON5, U+2028 or
      -- U+2029) inside it as a line end, which no record boundary is.
      local value, err = decode_with(line, line_opts, number)
      if err ~= "" then
        return nil, err
      end
      values[count] = value
    end
  end
  return values, ""
end

--- The values of JSON Lines read from `reader` a line at a time, as
--- `decode_lines` reads them from text: a blank line is skipped, a line
--- may end in `\r\n`, and a line that is not JSON is named by its
--- number, as there. A `null` line
--- reads as `Json.null`, or as `opts.null_value` when that is given, so
--- a value is never taken for the end. A line longer than `max` bytes
--- (1 MiB by default) fails, as `Stream.lines` says, and a `max` that
--- is no integer of at least 1 raises. `reader` is not closed.
---
---     local lines = Json.lines(reader)
---     for event in lines:each() do handle(event) end
---     assert(lines:failure() == "", lines:failure())
function Json.lines(reader: Stream.Reader, opts?: Json.DecodeOptions, max?: integer): Json.Lines
  if max ~= nil and (math.type(max) ~= "integer" or max < 1) then
    error("json: a line limit must be an integer of at least 1", 2)
  end
  local text = Stream.lines(reader, max)
  local given: Json.DecodeOptions = opts or {}
  local line_opts: Json.DecodeOptions = {
    null_value = given.null_value, max_depth = given.max_depth, json5 = given.json5,
    hash_comments = given.hash_comments,
    big_numbers_as_strings = given.big_numbers_as_strings,
    lone_surrogates = given.lone_surrogates,
  }
  if line_opts.null_value == nil then line_opts.null_value = Json.null end
  local number = 0
  local failed = ""
  local lines: Json.Lines = {}
  lines.read = function(_self: Json.Lines): any | nil, string
    if failed ~= "" then return nil, failed end
    while true do
      local line, trouble = text:read()
      if line == nil then
        if trouble ~= "" then failed = trouble end
        return nil, trouble
      end
      number = number + 1
      if line:find("%S") then
        local value, err = decode_with(line, line_opts, number)
        if err ~= "" then
          failed = err
          return nil, failed
        end
        return value, ""
      end
    end
  end
  lines.each = function(self: Json.Lines): function(): any
    return function(): any
      local value, _ = self:read()
      return value
    end
  end
  lines.failure = function(_self: Json.Lines): string
    return failed
  end
  return lines
end

--- `opts` for one line of JSON Lines: raises when `pretty` is true,
--- since a value must keep to its line.
local function line_encode_options(opts: Json.EncodeOptions | nil): Json.EncodeOptions
  if opts == nil then return {} end
  if opts.pretty then
    error("pretty cannot apply to JSON Lines: each value keeps to its line", 3)
  end
  return {
    sorted = opts.sorted, max_depth = opts.max_depth,
    nan_as_null = opts.nan_as_null, sparse_as_null = opts.sparse_as_null,
    ascii = opts.ascii,
  }
end

--- Writes `value` to `writer` as one line of JSON Lines: its compact
--- JSON and a newline, and true and "". False and why when the value
--- cannot be encoded, nothing written then, or the write fails. Raises
--- when `pretty` is true, as `encode_lines` does.
function Json.write_line(writer: Stream.Writer, value: any, opts?: Json.EncodeOptions): boolean, string
  local text, err = Json.encode(value, line_encode_options(opts))
  if text == nil then return false, err end
  return writer:write(text .. "\n")
end

--- `values[1]` to `values[#values]` as JSON Lines text: each value's
--- compact JSON on its own line, every line ending in a newline, and
--- "". nil and a message naming the value when one cannot be encoded.
--- Raises when `pretty` is true, since a value must keep to its line.
function Json.encode_lines(values: {any}, opts?: Json.EncodeOptions): string | nil, string
  local line_opts = line_encode_options(opts)
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

--- Whether the unmarked table `t` is an object, an array, or neither,
--- by the rules `encode` applies: an empty one is an object, one whose
--- keys are all strings an object, one whose keys are all integers from
--- 1 up an array, "hole" for integer keys from 1 up with a gap, and
--- anything else "mixed". A marked array is one without a scan.
local function table_kind(t: {any:any}): string
  if raw.is_array(t) then
    return "array"
  end
  local strings, integers, count = 0, 0, 0
  for key in pairs(t) do
    local k: any = key
    count = count + 1
    if k is string then
      strings = strings + 1
    elseif k is integer and k >= 1 then
      integers = integers + 1
    else
      return "mixed"
    end
  end
  if strings > 0 and integers > 0 then
    return "mixed"
  end
  if integers > 0 and integers == count and integers == rawlen(t) then
    return "array"
  end
  if integers > 0 then
    return "hole"
  end
  return "object"
end

--- What `v` is, for a message: `kind`, with a table of neither shape
--- named for what is wrong with it.
local function shape_kind(v: any): string
  if v is {any:any} then
    local k = table_kind(v)
    if k == "mixed" then
      return "table with mixed keys"
    elseif k == "hole" then
      return "array with a hole"
    end
    return k
  end
  return kind(v)
end

--- `s` as a JSON string literal, for a message: `"` and `\\` escaped and
--- every control character a `\u` escape, so a key or a value reads in
--- a message as it did in the text. It is for messages and is not a
--- JSON encoder: it answers for any bytes, UTF-8 or not, where `encode`
--- refuses what is not UTF-8. Use `Json.encode` to write JSON.
function Json.quote(s: string): string
  return '"' .. s:gsub('[%c"\\]', function(c: string): string
    if c == '"' or c == "\\" then return "\\" .. c end
    return ("\\u%04x"):format(c:byte())
  end) .. '"'
end

--- The path of `step` under `path`, as `encode` writes where it failed:
--- `.name` for a key that is a word, `["a key"]` (quoted as `Json.quote`
--- does) for one that is not, and `[3]` for an array index, counted from
--- 1. `path` is `"$"` for the document itself, so
--- `Json.child_path(Json.child_path("$", "rows"), 2)` is `$.rows[2]`.
function Json.child_path(path: string, step: string | integer): string
  if step is string then
    if step:match("^[%a_][%w_]*$") then
      return path .. "." .. step
    end
    return path .. "[" .. Json.quote(step) .. "]"
  end
  return path .. "[" .. step .. "]"
end

--- Four hex digits' value; the caller has matched them.
local function hex_value(digits: string): integer
  local value = tonumber(digits, 16)
  if value is integer then return value end
  error("json: not hex digits: " .. digits)
end

--- The steps of a path written as `child_path` spells one, for a
--- caller that takes a path as text (`cosmic json`): the steps for
--- `Json.get`, and "", or nil and a message naming the column where
--- the text stopped being a path. `$` is the document and may start
--- the text; then each step is `.name` (a key, up to the next `.` or
--- `[`), `[3]` (an array index, counted from 1 as `get` counts) or
--- `["a key"]` (a key in a JSON string, with JSON's escapes). Without
--- a leading `$`, the first step may drop its dot: `a.b` is `$.a.b`.
--- Whitespace is part of a key: `.a b` is the key `a b`.
--- `parse_path(Json.child_path(...))` gives back the steps that built
--- it, for any keys and integers. A path that is empty, or ends in a
--- `.`, or has an unclosed `[`, or an index that does not fit an
--- integer, or a lone surrogate escape, is refused; it never raises.
--- `*` (as `.*` or `[*]`) and `..` are refused too, by name, and not
--- read as keys: they are kept for wildcards and recursive descent, so
--- a key named `*` is `["*"]`.
---
---     local steps = assert(Json.parse_path('$.rows[2]["a key"]'))
---     assert(steps[1] == "rows" and steps[2] == 2 and steps[3] == "a key")
function Json.parse_path(text: string): {string | integer} | nil, string
  local steps: {string | integer} = {}
  local size = #text
  local function refuse(at: integer, what: string): nil, string
    return nil, "path column " .. at .. ": " .. what
  end
  if size == 0 then
    return nil, "path is empty; `$` is the whole document"
  end
  local at = 1
  local rooted = text:sub(1, 1) == "$"
  if rooted then at = 2 end
  local first = true
  while at <= size do
    local c = text:sub(at, at)
    if c == "." or (first and not rooted and c ~= "[") then
      local from = c == "." and at + 1 or at
      local stop = text:find("[.%[]", from) or size + 1
      if stop == from then
        if c == "." and text:sub(from, from) == "." then
          -- TODO: read `..` once the wildcard and flatten change (the
          -- next) implements recursive descent; refused until then.
          return refuse(at, "`..` (recursive descent) is not supported yet")
        end
        return refuse(from, "expected a key" .. (c == "." and " after `.`" or ""))
      end
      local name = text:sub(from, stop - 1)
      if name == "*" then
        -- TODO: read `*` once the wildcard and flatten change (the next)
        -- implements wildcards; refused until then.
        return refuse(at, "`*` (a wildcard) is not supported yet; " ..
          'a key named * is `["*"]`')
      end
      steps[#steps + 1] = name
      at = stop
    elseif c == "[" then
      if text:sub(at + 1, at + 1) == '"' then
        local parts: {string} = {}
        local here = at + 2
        while true do
          local stop = text:find('["\\]', here)
          if stop == nil then
            return refuse(at, "unclosed [")
          end
          parts[#parts + 1] = text:sub(here, stop - 1)
          if text:sub(stop, stop) == '"' then
            here = stop + 1
            break
          end
          local esc = text:sub(stop + 1, stop + 1)
          local plain: string | nil
          if esc == '"' or esc == "\\" or esc == "/" then
            plain = esc
          elseif esc == "b" then
            plain = "\b"
          elseif esc == "f" then
            plain = "\f"
          elseif esc == "n" then
            plain = "\n"
          elseif esc == "r" then
            plain = "\r"
          elseif esc == "t" then
            plain = "\t"
          end
          if plain ~= nil then
            parts[#parts + 1] = plain
            here = stop + 2
          elseif esc == "u" then
            local hex = text:match("^%x%x%x%x", stop + 2)
            if hex == nil then
              return refuse(stop, "expected four hex digits after \\u")
            end
            local code = hex_value(hex)
            here = stop + 6
            if code >= 0xD800 and code <= 0xDBFF then
              local low = text:match("^\\u([dD][c-fC-F]%x%x)", here)
              if low == nil then
                return refuse(stop, "a lone surrogate escape")
              end
              code = 0x10000 + ((code - 0xD800) << 10) + (hex_value(low) - 0xDC00)
              here = here + 6
            elseif code >= 0xDC00 and code <= 0xDFFF then
              return refuse(stop, "a lone surrogate escape")
            end
            parts[#parts + 1] = utf8.char(code)
          else
            return refuse(stop, "no such escape: \\" .. esc)
          end
        end
        if text:sub(here, here) ~= "]" then
          return refuse(here, "expected `]` after the key")
        end
        steps[#steps + 1] = table.concat(parts)
        at = here + 1
      else
        local digits = text:match("^(%-?%d+)%]", at + 1)
        if text:sub(at + 1, at + 2) == "*]" then
          -- TODO: read `[*]` once the wildcard and flatten change (the
          -- next) implements wildcards; refused until then.
          return refuse(at, "`[*]` (a wildcard) is not supported yet; " ..
            'a key named * is `["*"]`')
        end
        if digits == nil then
          return refuse(at, "expected an integer or a quoted key inside [ ]")
        end
        local number = tonumber(digits)
        if not (number is integer) then
          return refuse(at, "index " .. digits .. " does not fit an integer")
        end
        steps[#steps + 1] = number
        at = at + #digits + 2
      end
    else
      return refuse(at, "expected `.` or `[`, got " .. Json.quote(c))
    end
    first = false
  end
  return steps, ""
end

--- Where `descend` got to: the value, the message ("" on success) and
--- the path reached.
local record Reached
  value: any
  err: string
  at: string
end

--- `get`'s walk, shared with `entries` and `items`. A failure names the
--- value at fault, and `at` is the path of the value reached. A string
--- step on an unmarked table with no array part is indexed directly, so
--- a lookup in a large decoded object is not a scan of it; the scan
--- that names what is wrong runs only for a failure.
local function descend(value: any, path: {string | integer}): Reached
  local steps = 0
  local loose: any = path
  if loose is {any:any} then
    for _ in pairs(loose) do steps = steps + 1 end
  end
  if steps ~= rawlen(path) then
    error("json: a path must be a sequence, with no nil hole in it", 3)
  end
  local at = "$"
  local here = value
  for _, step in ipairs(path) do
    local step_value: any = step
    if step_value is integer then
      if not (here is {any:any}) or table_kind(here) ~= "array" then
        return { err = at .. ": expected an array to look up " .. Json.child_path("", step_value)
          .. ", got " .. shape_kind(here), at = at }
      end
      if step_value < 1 or step_value > rawlen(here) then
        return { err = at .. ": index " .. step_value .. " out of range, the array has " .. rawlen(here), at = at }
      end
      here = here[step_value]
    elseif step_value is string then
      local found: any
      if here is {any:any} and rawlen(here) == 0 and not raw.is_array(here) then
        found = here[step_value]
      elseif not (here is {any:any}) or table_kind(here) ~= "object" then
        return { err = at .. ": expected an object to look up " .. Json.quote(step_value)
          .. ", got " .. shape_kind(here), at = at }
      else
        found = here[step_value]
      end
      if found == nil then
        if here is {any:any} and table_kind(here) ~= "object" then
          return { err = at .. ": expected an object to look up " .. Json.quote(step_value)
            .. ", got " .. shape_kind(here), at = at }
        end
        return { err = at .. ": no key " .. Json.quote(step_value), at = at }
      end
      here = found
    else
      local what = math.type(step_value) or type(step_value)
      error("json: a path step must be a string or an integer, got " .. what, 3)
    end
    at = Json.child_path(at, step)
  end
  return { value = here, err = "", at = at }
end

--- The value at `path` under `value`, and "". A string step is an
--- object's key and an integer step an array's index, counted from 1
--- as Lua counts and as `encode`'s messages do:
--- `{ "users", 3, "name" }` is `$.users[3].name`. An empty path is
--- `value` itself. nil and a message naming the path reached, in that
--- style, when a key is missing, a step meets a value that is not an
--- object or array as the step needs (by the rules `entries` and
--- `items` apply), or an index is out of range:
--- `$.users[5]: index out of range, the array has 3`. `Json.null` is a
--- value like any other at the end of the path, and reaching through
--- it is an error: `$.a: expected an object, got null`. A key whose
--- value decoded to nil (a `null` without `null_value`) is missing, as
--- an array's hole is nil with an empty message; decode with
--- `null_value = Json.null` to tell them from an absent key. A path with
--- a nil hole in it raises. Test the
--- message, not the value: a leaf of `false` or `nil` answers
--- `false, ""` or `nil, ""`. A step that is neither a string nor an
--- integer (a float such as `1.0` too) raises.
---
---     local doc = assert(Json.decode('{"rows": [{"id": "a"}]}'))
---     local id, err = Json.get(doc, { "rows", 1, "id" })
---     assert(err == "" and id == "a")
function Json.get(value: any, path: {string | integer}): any | nil, string
  local reached = descend(value, path)
  if reached.err ~= "" then
    return nil, reached.err
  end
  return reached.value, ""
end

--- The object `value` is, or the one at `path` under it as `get` finds
--- it, as a map to loop over with `pairs`, and "". nil and a message
--- when it is anything else, naming the path when one is given
--- (`$.a: expected a JSON object, got array`). An empty table that no
--- `Json.array` mark or decoded `[]` made an array is an object, as
--- `encode` writes it.
function Json.entries(value: any, path?: {string | integer}): {string:any} | nil, string
  local at = ""
  local here = value
  if path ~= nil then
    local reached = descend(value, path)
    if reached.err ~= "" then
      return nil, reached.err
    end
    here = reached.value
    at = reached.at .. ": "
  end
  if here is {string:any} and table_kind(here) == "object" then
    return here, ""
  end
  return nil, at .. "expected a JSON object, got " .. shape_kind(here)
end

--- The array `value` is, or the one at `path` under it as `get` finds
--- it, as a list to loop over with `ipairs`, and "". nil and a message
--- when it is anything else, naming the path when one is given. A
--- table counts as an array when it carries the mark (`Json.is_array`)
--- or has integer keys from 1 up and no others; an unmarked empty
--- table is an object, so it fails here, as `encode` writes it `{}`.
---
---     for _, row in ipairs((assert(Json.items(doc, { "rows" })))) do
---       print(row)
---     end
function Json.items(value: any, path?: {string | integer}): {any} | nil, string
  local at = ""
  local here = value
  if path ~= nil then
    local reached = descend(value, path)
    if reached.err ~= "" then
      return nil, reached.err
    end
    here = reached.value
    at = reached.at .. ": "
  end
  if here is {any} and table_kind(here) == "array" then
    return here, ""
  end
  return nil, at .. "expected a JSON array, got " .. shape_kind(here)
end

--- What the values seen at one place look like, merged.
local record Node
  scalars: {string:boolean}
  objects: integer
  fields: {string:Node}
  seen: {string:integer}
  arrays: integer
  shortest: integer
  longest: integer
  elements: Node
  cut: boolean
end

local function new_node(): Node
  return { scalars = {}, objects = 0, fields = {}, seen = {}, arrays = 0, shortest = 0, longest = 0, cut = false }
end

--- Folds `v` into `node`, `depth` containers below the top and no
--- deeper than `limit`: each value is visited once, so a long array costs
--- its length, not a summary apiece.
local function absorb(node: Node, v: any, depth: integer, limit: integer)
  if v == nil or rawequal(v, raw.null) then
    node.scalars["null"] = true
    return
  end
  if type(v) == "number" then
    node.scalars["number"] = true
    return
  end
  if not (v is {any:any}) then
    node.scalars[type(v)] = true
    return
  end
  local k = table_kind(v)
  if k == "mixed" then
    node.scalars["table"] = true
  elseif k == "array" then
    local n = rawlen(v)
    if node.arrays == 0 or n < node.shortest then node.shortest = n end
    if node.arrays == 0 or n > node.longest then node.longest = n end
    node.arrays = node.arrays + 1
    if depth >= limit then
      node.cut = true
      return
    end
    if n > 0 and node.elements == nil then node.elements = new_node() end
    for i = 1, n do
      absorb(node.elements, v[i], depth + 1, limit)
    end
  else
    node.objects = node.objects + 1
    if depth >= limit then
      node.cut = true
      return
    end
    for key, member in pairs(v) do
      local name: any = key
      if not (name is string) then goto continue end
      local field = node.fields[name]
      if field == nil then
        field = new_node()
        node.fields[name] = field
      end
      node.seen[name] = (node.seen[name] or 0) + 1
      absorb(field, member, depth + 1, limit)
      ::continue::
    end
  end
end

local function sorted_keys<T>(t: {string:T}): {string}
  local keys: {string} = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function render(node: Node): string
  local parts: {string} = sorted_keys(node.scalars)
  if node.objects > 0 then
    if node.cut then
      parts[#parts + 1] = "{...}"
    else
      local members: {string} = {}
      for _, name in ipairs(sorted_keys(node.fields)) do
        local optional = node.seen[name] < node.objects and "?" or ""
        members[#members + 1] = (name:match("^[%a_][%w_]*$") and name or Json.quote(name)) .. optional .. ": " .. render(node.fields[name])
      end
      parts[#parts + 1] = "{" .. table.concat(members, ", ") .. "}"
    end
  end
  if node.arrays > 0 then
    local size = tostring(node.shortest)
    if node.longest ~= node.shortest then size = size .. ".." .. node.longest end
    if node.cut then
      parts[#parts + 1] = "[" .. size .. " x ...]"
    elseif node.elements == nil then
      parts[#parts + 1] = "[" .. size .. "]"
    else
      parts[#parts + 1] = "[" .. size .. " x " .. render(node.elements) .. "]"
    end
  end
  return table.concat(parts, "|")
end

--- A compact summary of `value`'s shape, for exploring a document whose
--- shape is not known: `{plans: [3 x {...}], today: {id: string}}`.
--- Object keys are sorted, and a key some of the objects merged at one
--- place lack is `key?`. An array is `[length x element]`, with every
--- element folded into one shape (`number|string` for a mix, the
--- length as `min..max` when merged arrays differ, `[0]` when empty),
--- so a long array costs no more to read than a short one. Scalars are
--- `string`, `number` (integer or float), `boolean` and `null`
--- (`Json.null`, or a hole). Past `max_depth` nesting a container is
--- `{...}` or `[n x ...]`, and `max_depth` is bounded by the stack, as
--- the walk recurses once per level. Beyond `string`, `number`, `boolean`
--- and `null`, a Lua value that is no JSON prints as its type,
--- `function` or `userdata`, and a table of mixed keys as `table`. The
--- same value always gives the same text.
--- An array with holes (a decoded `null` without `null_value`) has no
--- reliable length: decode with `null_value = Json.null` to describe one.
--- Raises when `max_depth` is not an integer of at least 0.
---
---     print(Json.describe(assert(Json.decode('{"ids": [1, 2], "ok": true}'))))
---     -- {ids: [2 x number], ok: boolean}
function Json.describe(value: any, opts?: Json.DescribeOptions): string
  local limit = 6
  if opts ~= nil and opts.max_depth ~= nil then
    local given: any = opts.max_depth
    if not (given is integer) or given < 0 then
      error("json: max_depth must be an integer of at least 0", 2)
    end
    limit = given
  end
  local node = new_node()
  absorb(node, value, 0, limit)
  return render(node)
end

return Json
