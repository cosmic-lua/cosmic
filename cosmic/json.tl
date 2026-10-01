--- JSON text to Lua values and back.
---
--- Reading is RFC 8259 and nothing else: no comments, no trailing
--- commas, no NaN, and a string must be UTF-8 with no lone surrogate.
--- A failure names the line and column where the text stopped being
--- JSON. The reader is yyjson.
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
--- each `#`.
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
--- a hole. `decode(text, { null_value = Json.null })` puts [`Json.null`]
--- where the text says `null`, and [`Json.null`] encodes as `null`, so
--- the round trip is whole. An array with a hole is an error to encode,
--- never a silent truncation.
---
--- A decoded array carries a mark ([`Json.is_array`]), so an empty `[]`
--- encodes back as `[]` and not `{}`; [`Json.array`] marks a table you
--- build. An unmarked table is an object when every key is a string, an
--- array when every key is an integer from 1 up, and an error when its
--- keys mix the two or are anything else ([`Json.layout`] says which).
---
--- To explore a document whose shape is not known, `Json.encode(v,
--- { pretty = true })` dumps a value and `Json.get(v, { "a", 1, "b" })`
--- reaches into it; [`Json.entries`] and [`Json.items`] narrow an object
--- or an array so a caller can `pairs` or `ipairs` it without a cast.
--- [`Json.quote`] spells a key in a message of your own.
---
--- Duplicate keys are allowed, and the last one stands. Encoded
--- objects list their keys in byte order, so the same value always
--- encodes to the same text.

-- The raw module behind this one lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why this
-- indirection exists.
local type raw_json = require("cosmic.internal.json")

local extra: any = select(2, ...)
local raw: raw_json
if type(extra) == "table" then
  raw = extra as raw_json
else
  raw = require("cosmic.internal.json")
end

local String = require("cosmic.string")

local record Json
  --- What `encode` may be told. Every field is optional.
  record EncodeOptions
    --- Lay the text out over lines, one member or element to a line,
    --- indented by two spaces (default false).
    pretty: boolean
    --- How many arrays and objects may nest, 1 to [`Json.depth_limit`]
    --- (1000; default [`Json.default_depth`], 64). A table that contains
    --- itself fails here.
    max_depth: integer
  end

  --- What `decode` may be told. Every field is optional.
  record DecodeOptions
    --- What to put where the text says `null`, so a Lua table can hold
    --- it. [`Json.null`] is the usual choice: it encodes back as `null`.
    null_value: any
    --- How many arrays and objects may nest, 1 to [`Json.depth_limit`]
    --- (1000; default [`Json.default_depth`], 64).
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

  --- How a Lua table encodes: see [`Json.layout`].
  enum TableLayout
    "array"
    "object"
    "hole"
    "mixed"
  end

  --- What a walk over a table visits: see [`Json.members`].
  record Members
    --- How the table encodes: see [`Json.layout`].
    layout: Json.TableLayout
    --- The keys to visit, in order: an object's or a hole's, none for an
    --- array.
    keys: {string | integer}
    --- An array's highest index, 0 for any other layout.
    extent: integer
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
local function decode_with(text: string, opts: Json.DecodeOptions, record?: integer,
                           null_value?: any): any | nil, string
  if null_value == nil then null_value = opts.null_value end
  return raw.decode(text, null_value, opts.max_depth, opts.json5,
    opts.big_numbers_as_strings, opts.lone_surrogates, record, opts.hash_comments)
end

--- Parses JSON text into the value it holds, and "". nil and a message,
--- naming the line and column, when the text is not one JSON value or
--- nests past `max_depth`. The value is `any`: when the text is from
--- outside, narrow it with `is` before trusting its shape, or use
--- [`decode_object`] or [`decode_array`], which check the outermost one.
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

--- Serializes `value` as JSON text, and "". nil and a message when it
--- holds a function, userdata other than [`Json.null`], NaN or an infinity,
--- a string that is not UTF-8, a table whose keys are neither all strings
--- nor all integers from 1 up, an array with a hole, or nesting past
--- `max_depth`. The message says where, as a path from the value:
--- `cannot encode a function at $.users[3].name`, with array indices
--- counted from 1 as Lua counts them. nil encodes as `null`.
function Json.encode(value: any, opts?: Json.EncodeOptions): string | nil, string
  if opts == nil then
    return raw.encode(value)
  end
  return raw.encode(value, opts.pretty, nil, nil, opts.max_depth)
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

--- Marks `t` as a JSON array, so it encodes as `[]` even when empty,
--- and answers it; with no argument, a new empty one. Raises when `t`
--- already has a metatable of its own.
function Json.array(t?: {any}): {any}
  return raw.array(t)
end

--- Whether `v` is a table marked as a JSON array: one `decode` built,
--- or one [`Json.array`] marked.
function Json.is_array(v: any): boolean
  return raw.is_array(v)
end

--- Classifies `t` as [`Json.layout`] says and, when `members` is true,
--- lists them as [`Json.members`] says; else the keys are empty and the
--- extent 0, and a marked array is classified with no scan of it.
local function classify(t: {any:any}, members: boolean): Json.TableLayout, {string | integer}, integer
  if raw.is_array(t) then
    local extent = 0
    if members then
      for key in pairs(t) do
        local k: any = key
        if k is integer and k > extent then extent = k end
      end
    end
    return "array", {}, extent
  end
  local keys: {string | integer} = {}
  local strings, numbers = 0, 0
  for key in pairs(t) do
    local k: any = key
    if k is string then
      strings = strings + 1
      if members then keys[strings + numbers] = k end
    elseif k is integer and k >= 1 then
      numbers = numbers + 1
      if members then keys[strings + numbers] = k end
    else
      return "mixed", {}, 0
    end
  end
  if strings > 0 and numbers > 0 then return "mixed", {}, 0 end
  if numbers > 0 and numbers == rawlen(t) then return "array", {}, numbers end
  if members then table.sort(keys) end
  return numbers > 0 and "hole" or "object", keys, 0
end

--- How the table `t` encodes, by the rules `encode` applies: "array"
--- for a marked array ([`Json.is_array`]) and for one whose keys are
--- exactly the integers 1 to its length, "object" for string keys alone
--- (an empty table too), "hole" for integer keys from 1 up with a gap,
--- and "mixed" for anything else. A marked array is classified with no
--- scan of it.
---
---     assert(Json.layout({ 1, 2 }) == "array")
---     assert(Json.layout({ a = 1 }) == "object")
---     assert(Json.layout({ [1] = 1, [3] = 3 }) == "hole")
---     assert(Json.layout({ 1, a = 2 }) == "mixed")
function Json.layout(t: {any:any}): Json.TableLayout
  local layout = classify(t, false)
  return layout
end

--- `t`'s [`Json.layout`] with what a walk over it visits. The keys are
--- an object's string keys, or a hole's integer keys, sorted, so the
--- elements around a gap keep their indexes; an array has none. The
--- extent is an array's highest index, where `rawlen` is only a border
--- of a decoded array that dropped a `null`; 0 for any other layout.
--- Unlike [`Json.layout`], it scans a marked array to find that extent.
function Json.members(t: {any:any}): Json.Members
  local layout, keys, extent = classify(t, true)
  return { layout = layout, keys = keys, extent = extent }
end

--- What `v` is, for a message: `kind`, with a table of neither shape
--- named for what is wrong with it.
local function shape_kind(v: any): string
  if v is {any:any} then
    local k = Json.layout(v)
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
--- refuses what is not UTF-8. Use [`Json.encode`] to write JSON.
function Json.quote(s: string): string
  return '"' .. s:gsub('[%c"\\]', function(c: string): string
    if c == '"' or c == "\\" then return "\\" .. c end
    return ("\\u%04x"):format(c:byte())
  end) .. '"'
end

--- The path of `step` under `path`, as `encode` writes where it failed:
--- `.name` for a key that is a word, `["a key"]` (quoted as [`Json.quote`]
--- does) for one that is not, and `[3]` for an array index, counted from
--- 1. `path` is `"$"` for the document itself, so
--- `child_path(child_path("$", "rows"), 2)` is `$.rows[2]`.
local function child_path(path: string, step: string | integer): string
  -- TODO: build.json_query spells paths too; this copy goes once `get`
  -- moves there with cosmic/dataset.tl (PR 3 of
  -- doc/plans/stdlib-simplification.md), which cosmic/ cannot follow.
  if step is string then
    if step:match("^[%a_][%w_]*$") then
      return path .. "." .. step
    end
    return path .. "[" .. Json.quote(step) .. "]"
  end
  return path .. "[" .. step .. "]"
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
      if not (here is {any:any}) or Json.layout(here) ~= "array" then
        return { err = at .. ": expected an array to look up " .. child_path("", step_value)
          .. ", got " .. shape_kind(here), at = at }
      end
      local size = rawlen(here)
      if step_value > size and raw.is_array(here) then
        -- A decoded array with holes: `rawlen` is any border of it.
        size = Json.members(here).extent
      end
      if step_value < 1 or step_value > size then
        return { err = at .. ": index " .. step_value .. " out of range, the array has " .. size, at = at }
      end
      here = here[step_value]
    elseif step_value is string then
      local found: any
      if here is {any:any} and rawlen(here) == 0 and not raw.is_array(here) then
        found = here[step_value]
      elseif not (here is {any:any}) or Json.layout(here) ~= "object" then
        return { err = at .. ": expected an object to look up " .. Json.quote(step_value)
          .. ", got " .. shape_kind(here), at = at }
      else
        found = here[step_value]
      end
      if found == nil then
        if here is {any:any} and Json.layout(here) ~= "object" then
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
    at = child_path(at, step)
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
--- `$.users[5]: index out of range, the array has 3`. [`Json.null`] is a
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
  -- TODO: move to build/json_query.tl once cosmic/dataset.tl, this
  -- function's caller, moves to build/ (PR 3 of
  -- doc/plans/stdlib-simplification.md); cosmic/ cannot require build/.
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
--- [`Json.array`] mark or decoded `[]` made an array is an object, as
--- `encode` writes it.
function Json.entries(value: any, path?: {string | integer}): {string:any} | nil, string
  -- TODO: move to build/json_query.tl once cosmic/dataset.tl, this
  -- function's caller, moves to build/ (PR 3 of
  -- doc/plans/stdlib-simplification.md); cosmic/ cannot require build/.
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
  if here is {string:any} and Json.layout(here) == "object" then
    return here, ""
  end
  return nil, at .. "expected a JSON object, got " .. shape_kind(here)
end

--- The array `value` is, or the one at `path` under it as `get` finds
--- it, as a list to loop over with `ipairs`, and "". nil and a message
--- when it is anything else, naming the path when one is given. A
--- table counts as an array when it carries the mark ([`Json.is_array`])
--- or has integer keys from 1 up and no others; an unmarked empty
--- table is an object, so it fails here, as `encode` writes it `{}`.
---
---     for _, row in ipairs((assert(Json.items(doc, { "rows" })))) do
---       print(row)
---     end
function Json.items(value: any, path?: {string | integer}): {any} | nil, string
  -- TODO: move to build/json_query.tl once cosmic/dataset.tl, this
  -- function's caller, moves to build/ (PR 3 of
  -- doc/plans/stdlib-simplification.md); cosmic/ cannot require build/.
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
  if here is {any} and Json.layout(here) == "array" then
    return here, ""
  end
  return nil, at .. "expected a JSON array, got " .. shape_kind(here)
end

return Json
