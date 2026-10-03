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
--- `nil, message` on failure, the message opening `json: `, so test the
--- message, not the value: a document that is just `null` decodes to nil
--- with an empty message.
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
--- { pretty = true })` dumps a value, and [`Json.decode_object`] and
--- [`Json.decode_array`] narrow the outermost value so a caller can `pairs`
--- or `ipairs` it without a cast. [`Json.quote`] spells a key in a message
--- of your own.
---
--- An object that holds a key twice is refused, naming the second
--- one: readers disagree about which of the two stands, so text that
--- means one thing to this reader can mean another to the next. A key
--- is compared as it reads, so `"a"` and `"\u0061"` are the same key.
--- `decode(text, { duplicate_keys = true })` reads such an object, and
--- the last of the key's members stands. Encoded objects list their keys
--- in byte order, so the same value always encodes to the same text.
---
--- A text too large to hold whole, or a stream of values, is read a
--- token at a time by [`Json.reader`], from a [`Stream.Reader`], and a
--- part of it can be decoded whole with the reader's `value`.
---
--- Text can be handled as text, without building a value:
--- [`Json.check`] says whether `decode` would read it, [`Json.format`]
--- writes it again compact or laid out, its members in their order and
--- its numbers as they were written, and [`Json.canonical`] writes the
--- one text RFC 8785 makes of it, for a digest or a signature that two
--- programs must agree on.
---
---     assert(Json.format('{ "b": 1.50, "a": [ ] }') == '{"b":1.50,"a":[]}')
---     assert(Json.canonical('{"b": 1.50, "a": []}') == '{"a":[],"b":1.5}')
---
--- A failure that is not in the text's syntax -- a key twice, nesting
--- past `max_depth` -- also names where it is in the value, by its JSON
--- Pointer, as every message of this module names a place: `json:
--- duplicate key at line 3, column 5 (pointer "/users/1/role")`, an
--- array's index counted from 0. A pointer too long for a message keeps
--- its innermost segments, named `pointer ending "..."`.
---
--- A place in a value has three spellings, each named for what it is.
--- [`Json.Steps`] are Lua's: `{"users", 2, "role"}`, a position counted
--- from 1 or, negative, from the end. A JSON Pointer (RFC 6901),
--- `/users/1/role`, and a JSONPath query (RFC 9535), `$.users[1].role`,
--- count from 0. [`Json.pointer`] and [`Json.path`] write steps as either;
--- [`Json.from_pointer`] and [`Json.from_path`] read them back;
--- [`Json.get`] follows steps; [`Json.query`] reads a JSONPath query
--- that can select many values (`*`, `..`), strictly and in a subset
--- that leaves filters, slices and unions out, and [`Json.select`] runs
--- it.

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

local type Stream = require("cosmic.stream")
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

  --- What [`Json.format`] may be told. Every field is optional, and those
  --- that say how to read the text mean what they mean to `decode`.
  record FormatOptions
    --- Lay the text out as `encode`'s `pretty` does (default false).
    pretty: boolean
    --- How many arrays and objects may nest, as `decode` takes it.
    max_depth: integer
    --- Read JSON5, as `decode` does; what is written is RFC 8259.
    json5: boolean
    --- Read `#` line comments, as `decode` does.
    hash_comments: boolean
    --- Read a lone surrogate escape as U+FFFD, as `decode` does.
    lone_surrogates: boolean
    --- Read an object that holds a key twice rather than refusing it
    --- (default false); each member is written, in its place.
    duplicate_keys: boolean
  end

  --- What [`Json.canonical`] may be told: how to read the text, as
  --- `decode` reads it. Every field is optional. A key twice is always
  --- refused: RFC 8785 has no form for it.
  record CanonicalOptions
    --- How many arrays and objects may nest, as `decode` takes it.
    max_depth: integer
    --- Read JSON5, as `decode` does.
    json5: boolean
    --- Read `#` line comments, as `decode` does.
    hash_comments: boolean
    --- Read a lone surrogate escape as U+FFFD, as `decode` does.
    lone_surrogates: boolean
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
    --- refused as any key twice is unless `duplicate_keys` is given.
    lone_surrogates: boolean
    --- Read an object that holds a key twice, the last of its members
    --- standing, rather than refusing it (default false).
    duplicate_keys: boolean
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
    --- The keys to visit, in order: an object's or a hole's, and a marked
    --- array's integer keys when it has a gap; none for any other array.
    keys: {string | integer}
    --- An array's highest index, 0 for any other layout.
    extent: integer
  end

  --- What a token [`Json.reader`] reads is.
  enum TokenKind
    --- `{`, which opens an object.
    "object"
    --- `}`, which closes one.
    "end_object"
    --- `[`, which opens an array.
    "array"
    --- `]`, which closes one.
    "end_array"
    --- An object's key, its value the key's text.
    "key"
    --- A string, its value the string's text.
    "string"
    --- A number, its value an integer or a float as `decode` reads it.
    "number"
    --- `true` or `false`, its value the boolean.
    "boolean"
    --- `null`, its value nil.
    "null"
  end

  --- One token of a JSON text: see [`Json.reader`].
  record Token
    --- What the token is.
    kind: Json.TokenKind
    --- A key's or a string's text, a number, a boolean; nil for the
    --- rest.
    value: string | number | boolean
  end

  --- What [`Json.reader`] may be told. Every field is optional, and each
  --- means what it means to `decode`.
  record ReaderOptions
    --- How many arrays and objects may be open at once, 1 to
    --- [`Json.depth_limit`] (default [`Json.default_depth`]).
    max_depth: integer
    --- Read an object that holds a key twice rather than refusing it.
    duplicate_keys: boolean
    --- Read a number past 64 bits or a double's range as its digits.
    big_numbers_as_strings: boolean
    --- Read a lone surrogate escape as U+FFFD.
    lone_surrogates: boolean
    --- Read JSON5, as `decode` does: comments, single-quoted strings,
    --- unquoted keys, trailing commas, hex and signed numbers, `Infinity`
    --- and `NaN`, and JSON5's whitespace, whose U+2028 and U+2029 end a
    --- line.
    json5: boolean
    --- Read `#` line comments, as `decode` does, with or without `json5`.
    hash_comments: boolean
    --- What `value` puts where the text says `null`.
    null_value: any
  end

  --- A reader of JSON text a token at a time, from [`Json.reader`]. A
  --- failure, the stream's or the text's, answers again on every later
  --- call.
  interface Reader
    --- The next token, and ""; nil and "" when the stream has ended
    --- with every value whole; nil and a message, naming the line and
    --- column, when the text is not JSON -- and its JSON Pointer, when the fault
    --- is in where the token stands rather than in its own text (a
    --- string's escape, a number's digits, which `decode` reads).
    next: function(Reader): Json.Token | nil, string
    --- The kind of the next token, without reading it, and ""; nil and
    --- "" at the end; nil and a message as `next` fails. It goes by the
    --- token's first byte (and, under `json5`, an `n`'s second, `nan`
    --- being a number): `next` may still refuse the rest of it (`nope`
    --- peeks as "null").
    peek: function(Reader): Json.TokenKind | nil, string
    --- The next whole value -- a scalar, or an array or object with
    --- everything in it -- decoded as `decode` decodes one, and "". The
    --- reader must be where a value goes: not at a key, a closing
    --- bracket or the end, which it refuses. A `null` is nil unless
    --- `null_value` says otherwise, so test the message.
    value: function(Reader): any | nil, string
    --- Where the reader is, as steps: the array or object it is in and
    --- the element or member it read last, each position counted from 1.
    --- [`Json.pointer`] and [`Json.path`] spell them.
    steps: function(Reader): Json.Steps
    --- How many bytes of the stream it has read past.
    offset: function(Reader): integer
  end

  --- A path to one value inside another, as Lua steps: each a member's
  --- name (a string) or an array's position (an integer), counted from
  --- 1 as Lua counts, or from the end when negative, -1 the last, as
  --- `string.sub` counts. `{"users", 3, "name"}` is the third user's
  --- name: JSON Pointer's `/users/2/name` and JSONPath's
  --- `$['users'][2]['name']`, which count from 0.
  type Steps = {string | integer}

  --- What a JSONPath selector selects: see [`Json.Segment`].
  enum SelectorKind
    --- An object's member of one name.
    "name"
    --- An array's element at one index.
    "index"
    --- Every member of an object, every element of an array.
    "wildcard"
  end

  --- One segment of a JSONPath query: one selector, applied to the
  --- values the query has reached or, for a descendant segment (`..`),
  --- to them and to every value beneath them.
  record Segment
    --- Whether it is a descendant segment.
    descendant: boolean
    --- What it selects.
    kind: Json.SelectorKind
    --- The member's name, for a "name" selector.
    name: string
    --- The element's index, for an "index" selector: counted from 0,
    --- or from the end when negative, as JSONPath writes it.
    index: integer
  end

  --- A JSONPath query (RFC 9535), as [`Json.query`] reads one.
  record Query
    --- The query as it was written.
    text: string
    --- Its segments, in order.
    segments: {Json.Segment}
  end

  --- One value a query selected, and where it is.
  record Match
    --- The steps from the queried value to it, each position counted
    --- from 1.
    steps: Json.Steps
    --- The value itself.
    value: any
  end

  --- What [`Json.select`] may be told. Every field is optional.
  record SelectOptions
    --- How deep a descendant segment (`..`) may walk, 1 to
    --- [`Json.depth_limit`] (the default): a table that contains itself
    --- fails here.
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

--- What a failure of this module answers, nil and `why` under the
--- module's name.
local function refuse(why: string): nil, string
  return nil, "json: " .. why
end

--- `raw.decode` of `text` under `opts`; `record`, when given, is the
--- JSON Lines line `text` is, which a failure names.
local function decode_with(text: string, opts: Json.DecodeOptions, record?: integer,
                           null_value?: any): any | nil, string
  if null_value == nil then null_value = opts.null_value end
  local value, err = raw.decode(text, null_value, opts.max_depth, opts.json5,
    opts.big_numbers_as_strings, opts.lone_surrogates, record, opts.hash_comments,
    opts.duplicate_keys)
  if err ~= "" then return refuse(err) end
  return value, ""
end

--- Parses JSON text into the value it holds, and "". nil and a message,
--- naming the line and column, when the text is not one JSON value,
--- holds an object with a key twice, or nests past `max_depth`. The
--- value is `any`: when the text is from outside, narrow it with `is`
--- before trusting its shape, or use [`decode_object`] or
--- [`decode_array`], which check the outermost one.
function Json.decode(text: string, opts?: Json.DecodeOptions): any | nil, string
  if opts == nil then
    local value, err = raw.decode(text)
    if err ~= "" then return refuse(err) end
    return value, ""
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
  return refuse("expected a JSON object, got " .. kind(value))
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
  return refuse("expected a JSON array, got " .. kind(value))
end

--- Serializes `value` as JSON text, and "". nil and a message when it
--- holds a function, userdata other than [`Json.null`], NaN or an infinity,
--- a string that is not UTF-8, a table whose keys are neither all strings
--- nor all integers from 1 up, an array with a hole, or nesting past
--- `max_depth`. The message says where, by its JSON Pointer: `json:
--- cannot encode a function at pointer "/users/2/name"`, an array's
--- index counted from 0. nil encodes as `null`.
function Json.encode(value: any, opts?: Json.EncodeOptions): string | nil, string
  local text: string
  local err: string
  if opts == nil then
    text, err = raw.encode(value)
  else
    text, err = raw.encode(value, opts.pretty, opts.max_depth)
  end
  if text == nil then return refuse(err) end
  return text, ""
end

--- true and "" when `decode(text, opts)` would read the text; else
--- false and the message it would fail with. It builds no value, so it
--- costs a fraction of a decode. `null_value` changes nothing here.
function Json.check(text: string, opts?: Json.DecodeOptions): boolean, string
  local o: Json.DecodeOptions = opts or {}
  local ok, err = raw.check(text, o.max_depth, o.json5, o.lone_surrogates, o.hash_comments,
    o.duplicate_keys, o.big_numbers_as_strings)
  if not ok then return false, "json: " .. err end
  return true, ""
end

--- The JSON value `text` holds, written again as RFC 8259 text, and "":
--- with no space, or laid out as `encode`'s `pretty` lays a value out.
--- What `decode` would refuse is refused, with its message. Nothing
--- else changes: members keep their order, strings their characters
--- (escaped only where JSON must escape them) and numbers their text,
--- `1.50` and thirty digits too -- but for JSON5's own forms, written as
--- RFC 8259 writes the same number: `+1` as `1`, `.5` as `0.5`, `5.` as
--- `5.0`, `0x1F` as `31`.
--- nil and a message, naming where, for NaN or an infinity, which JSON
--- has no text for.
function Json.format(text: string, opts?: Json.FormatOptions): string | nil, string
  local o: Json.FormatOptions = opts or {}
  local out, err = raw.format(text, o.max_depth, o.json5, o.lone_surrogates, o.hash_comments,
    o.duplicate_keys, o.pretty, false)
  if out == nil then return refuse(err) end
  return out, ""
end

--- The JSON value `text` holds in the canonical form of RFC 8785 (the
--- JSON Canonicalization Scheme), and "": no space, members sorted by
--- their keys' UTF-16 code units, strings escaped only where JSON must,
--- and every number the double it reads as, written as ECMAScript
--- writes one -- so `1.0`, `1` and `1e0` are all `1`. Two texts of one
--- value give the same bytes, for a digest or a signature. An integer
--- past 2^53 becomes the double nearest it, as the scheme says: keep an
--- identifier that large in a string. nil and a message when `decode`
--- would refuse the text, it holds a key twice, or a number is NaN or
--- an infinity, or past a double's range.
---
---     local text = '{"b": [1.0, 2e2], "a": "\\u00e9"}'
---     assert(Json.canonical(text) == '{"a":"\u{e9}","b":[1,200]}')
function Json.canonical(text: string, opts?: Json.CanonicalOptions): string | nil, string
  local o: Json.CanonicalOptions = opts or {}
  local out, err = raw.format(text, o.max_depth, o.json5, o.lone_surrogates, o.hash_comments,
    false, false, true)
  if out == nil then return refuse(err) end
  return out, ""
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
--- `gaps` asks for a marked array's integer keys when it has a gap.
local function classify(t: {any:any}, members: boolean, gaps: boolean): Json.TableLayout, {string | integer}, integer
  if raw.is_array(t) then
    local extent = 0
    local keys: {string | integer} = {}
    if members and gaps then
      local count = 0
      for key in pairs(t) do
        local k: any = key
        if not (k is integer and k >= 1) then return "mixed", {}, 0 end
        count = count + 1
        if k > extent then extent = k end
      end
      if count ~= extent then
        for key in pairs(t) do
          local k: any = key
          if k is integer then keys[#keys + 1] = k end
        end
        table.sort(keys)
      end
    elseif members then
      for key in pairs(t) do
        local k: any = key
        if not (k is integer and k >= 1) then return "mixed", {}, 0 end
        if k > extent then extent = k end
      end
    end
    return "array", keys, extent
  end
  local keys: {string | integer} = {}
  local strings, numbers, top = 0, 0, 0
  for key in pairs(t) do
    local k: any = key
    if k is string then
      strings = strings + 1
      if members then keys[strings + numbers] = k end
    elseif k is integer and k >= 1 then
      numbers = numbers + 1
      if k > top then top = k end
      if members then keys[strings + numbers] = k end
    else
      return "mixed", {}, 0
    end
  end
  if strings > 0 and numbers > 0 then return "mixed", {}, 0 end
  -- `rawlen` is only some border, so as many keys as it says are the
  -- integers 1 to it only when none lies past it.
  if numbers > 0 and numbers == rawlen(t) and top == numbers then return "array", {}, numbers end
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
  local layout = classify(t, false, false)
  return layout
end

--- `t`'s [`Json.layout`] with what a walk over it visits. The keys are
--- an object's string keys, or a hole's integer keys, sorted, so the
--- elements around a gap keep their indexes; an array has none, unless
--- `gaps` is true and it is a marked one with a gap, which then lists
--- its integer keys, so a walk need not count up to an extent a stray
--- index set. The extent is an array's highest index, where `rawlen` is
--- only a border of a decoded array that dropped a `null`; 0 for any
--- other layout. Unlike [`Json.layout`], it scans a marked array, to
--- find that extent and to answer "mixed" for one that holds a key
--- other than a positive integer.
function Json.members(t: {any:any}, gaps?: boolean): Json.Members
  local layout, keys, extent = classify(t, true, gaps == true)
  return { layout = layout, keys = keys, extent = extent }
end

--- The escape `quote` writes for the one character `c` it escapes.
local function escape(c: string): string
  if c == '"' or c == "\\" then return "\\" .. c end
  return ("\\u%04x"):format(c:byte())
end

--- `s` as a JSON string literal, for a message: `"` and `\\` escaped and
--- every control character a `\u` escape, so a key or a value reads in
--- a message as it did in the text. It is for messages and is not a
--- JSON encoder: it answers for any bytes, UTF-8 or not, where `encode`
--- refuses what is not UTF-8. Use [`Json.encode`] to write JSON.
function Json.quote(s: string): string
  return '"' .. s:gsub('[%c"\\]', escape) .. '"'
end

-- ---- paths ---------------------------------------------------------

--- A JSON Pointer's segment for the member `name`: `~` written `~0` and
--- `/` written `~1`.
local function pointer_segment(name: string): string
  return (name:gsub("~", "~0"):gsub("/", "~1"))
end

--- Where `pointer` is, for a message: `pointer "/users/2"`.
--- Where `pointer` is, for a message, as the core's messages name a
--- place: `pointer "/users/2"`; when it runs past 199 bytes, as many of
--- its innermost segments as fit, `pointer ending "..."`, the innermost
--- alone cut to its first 40 bytes or fewer and `...` when even it does
--- not fit.
local function at_pointer(pointer: string): string
  if #pointer < 200 then return "pointer " .. Json.quote(pointer) end
  local segments: {string} = {}
  for segment in pointer:gmatch("/[^/]*") do segments[#segments + 1] = segment end
  local kept = segments[#segments]
  if #kept >= 200 then
    kept = kept:sub(1, 41)
    while utf8.len(kept) == nil or kept:sub(-1) == "~" do kept = kept:sub(1, -2) end
    return "pointer ending " .. Json.quote(kept .. "...")
  end
  for i = #segments - 1, 1, -1 do
    if #kept + #segments[i] >= 200 then break end
    kept = segments[i] .. kept
  end
  return "pointer ending " .. Json.quote(kept)
end

--- Why step `i` of a path is none, or nil when it is one: a name that
--- is UTF-8, or an integer.
local function bad_step(i: integer, step: any): string
  if step is string then
    if utf8.len(step) == nil then return ("step %d is a name that is not UTF-8"):format(i) end
    return nil
  end
  if math.type(step) ~= "integer" then
    return ("step %d is %s, neither a name nor an integer"):format(i, tostring(step))
  end
  if step == 0 then
    return ("step %d is 0: positions count from 1, or from -1 at the end"):format(i)
  end
  return nil
end

--- `v` as a table, or nil when it is none.
local function table_of(v: any): {any: any}
  if v is {any: any} then return v end
  return nil
end

--- The JSON Pointer for steps that all count from 1, as a match's do.
local function pointer_of(steps: Json.Steps): string
  local parts: {string} = {}
  for i, step in ipairs(steps) do
    if step is string then
      parts[i] = "/" .. pointer_segment(step)
    else
      parts[i] = "/" .. tostring(step - 1)
    end
  end
  return table.concat(parts)
end

--- The highest position of the array `t`, holes and all.
local function last_position(t: {any: any}): integer
  local m = Json.members(t, true)
  local last = m.keys[#m.keys]
  if m.layout == "hole" and last is integer then return last end
  return m.extent
end

--- Whether `t` holds an array's elements, as `encode` would write it:
--- one marked, or keyed 1 up with or without gaps; "mixed" when it is
--- neither an array nor an object.
local function container(t: {any: any}): string
  local layout = Json.layout(t)
  if layout == "hole" then return "array" end
  return layout
end

--- `steps` as a JSON Pointer (RFC 6901), and "": `/users/2/name`, each
--- position counted from 0. nil and a message for a step a pointer
--- cannot say, one counted from the end, or for one that is no step: 0,
--- a number that is no integer, or a name that is not UTF-8.
---
---     assert(Json.pointer({ "users", 3, "a/b" }) == "/users/2/a~1b")
function Json.pointer(steps: Json.Steps): string | nil, string
  local parts: {string} = {}
  for i, step in ipairs(steps) do
    local bad = bad_step(i, step)
    if bad ~= nil then return refuse(bad) end
    if step is string then
      parts[i] = "/" .. pointer_segment(step)
    elseif step >= 1 then
      parts[i] = "/" .. tostring(step - 1)
    else
      return refuse(("step %d is %d, from the end, which a JSON Pointer cannot say"):format(i, step))
    end
  end
  return table.concat(parts), ""
end

--- The steps the JSON Pointer `text` (RFC 6901) takes through `value`,
--- and "". A pointer does not say whether `/2` is a member named "2" or
--- an array's third element, so it is read against the value: a
--- segment into an array is an index, `0` or a number with no leading
--- zero, and one into an object is a member's name. nil and a message
--- when the text is no pointer -- not empty and not starting with `/`,
--- or holding a `~` that is not `~0` or `~1` -- or names no value in
--- `value`, `-` (past the last element) included.
---
---     local doc = assert(Json.decode('{"users": [{"name": "ada"}]}'))
---     local steps = assert(Json.from_pointer(doc, "/users/0/name"))
---     assert(steps[1] == "users" and steps[2] == 1 and Json.get(doc, steps) == "ada")
function Json.from_pointer(value: any, text: string): Json.Steps | nil, string
  local steps: Json.Steps = {}
  if text == "" then return steps, "" end
  if text:sub(1, 1) ~= "/" then
    return refuse(at_pointer(text) .. ": a JSON Pointer is empty or starts with `/`")
  end
  local at = value
  local start = 2
  while true do
    local stop = text:find("/", start, true) or #text + 1
    local segment = text:sub(start, stop - 1)
    local tilde = segment:find("~[^01]") or (segment:sub(-1) == "~" and #segment or nil)
    if tilde ~= nil then
      return refuse(("%s: the `~` at byte %d is neither `~0` nor `~1`"):format(at_pointer(text), start + tilde - 1))
    end
    local name = segment:gsub("~1", "/"):gsub("~0", "~")
    local reached = text:sub(1, stop - 1)
    local before = text:sub(1, start - 2)
    local t = table_of(at)
    if t == nil then
      return refuse(("no value at %s: the value at %s is %s"):format(at_pointer(reached), at_pointer(before), kind(at)))
    end
    local shape = container(t)
    if shape == "array" then
      if name == "-" then
        return refuse(("no value at %s: `-` names the place past the last element"):format(at_pointer(reached)))
      end
      if not (name == "0" or name:match("^[1-9]%d*$")) or #name > 15 then
        return refuse(("no value at %s: the value at %s is an array, and %s is no index"):
            format(at_pointer(reached), at_pointer(before), Json.quote(name)))
      end
      local index = math.tointeger(tonumber(name)) + 1
      steps[#steps + 1] = index
      at = t[index]
    elseif shape == "object" then
      steps[#steps + 1] = name
      at = t[name]
    else
      return refuse(("no value at %s: the value at %s is a table with mixed keys"):
          format(at_pointer(reached), at_pointer(before)))
    end
    if at == nil then return refuse("no value at " .. at_pointer(reached)) end
    if stop > #text then return steps, "" end
    start = stop + 1
  end
end

--- The value `steps` reach in `value`, and "". A negative position
--- counts from the end. nil and a message naming, by its JSON Pointer,
--- the first step that reaches nothing: a member or element not there,
--- or a step into a value that is not an array or object, or a name
--- into an array, or a position into an object. A member read as nil
--- (a JSON `null` decoded without `null_value`) is not there.
function Json.get(value: any, steps: Json.Steps): any | nil, string
  local at = value
  local reached = ""
  for i, step in ipairs(steps) do
    local bad = bad_step(i, step)
    if bad ~= nil then return refuse(bad) end
    local t = table_of(at)
    if t == nil then
      return refuse(("the value at %s is %s, not an array or object"):format(at_pointer(reached), kind(at)))
    end
    local shape = container(t)
    if step is string then
      if shape ~= "object" then
        return refuse(("the value at %s is %s, not an object"):format(at_pointer(reached),
          shape == "array" and "an array" or "a table with mixed keys"))
      end
      reached = reached .. "/" .. pointer_segment(step)
      at = t[step]
    else
      if shape ~= "array" then
        return refuse(("the value at %s is %s, not an array"):format(at_pointer(reached),
          shape == "object" and "an object" or "a table with mixed keys"))
      end
      local position = step
      if position < 0 then position = last_position(t) + 1 + position end
      if position < 1 then
        return refuse(("no element %d from the end at %s"):format(-step, at_pointer(reached)))
      end
      reached = reached .. "/" .. tostring(position - 1)
      at = t[position]
    end
    if at == nil then return refuse("no value at " .. at_pointer(reached)) end
  end
  return at, ""
end

--- The control characters a normalized path writes by a short escape.
local SHORT_ESCAPES <const>: {string: string} = {
  ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

--- `name` in a normalized path's single quotes (RFC 9535, 2.7): `'` and
--- `\` escaped, and each control character as JSON escapes it, by its
--- short escape where it has one.
local function normal_name(name: string): string
  return "'" .. name:gsub("[%c'\\]", function(c: string): string
    if c == "'" or c == "\\" then return "\\" .. c end
    local short = SHORT_ESCAPES[c]
    if short ~= nil then return short end
    if c:byte() == 127 then return c end
    return ("\\u%04x"):format(c:byte())
  end) .. "'"
end

--- `steps` as a JSONPath query (RFC 9535), and "": the normalized path
--- `$['users'][2]['name']`, each position counted from 0, a member's
--- name always in single quotes. A step counted from the end is written
--- `[-1]`, which a query reads as the same element but no normalized
--- path holds. nil and a message for a step that is no step: 0, a
--- number that is no integer, or a name that is not UTF-8.
---
---     assert(Json.path({ "users", 3, "it's" }) == "$['users'][2]['it\\'s']")
function Json.path(steps: Json.Steps): string | nil, string
  local parts: {string} = { "$" }
  for i, step in ipairs(steps) do
    local bad = bad_step(i, step)
    if bad ~= nil then return refuse(bad) end
    if step is string then
      parts[#parts + 1] = "[" .. normal_name(step) .. "]"
    elseif step >= 1 then
      parts[#parts + 1] = "[" .. tostring(step - 1) .. "]"
    else
      parts[#parts + 1] = "[" .. tostring(step) .. "]"
    end
  end
  return table.concat(parts), ""
end

--- Why a JSONPath query cannot be read, at byte `at` of it.
local function query_why(at: integer, why: string): string
  return ("json: JSONPath byte %d: %s"):format(at, why)
end

--- A failure to read a JSONPath query at byte `at` of it.
local function query_error(at: integer, why: string): nil, string
  return nil, query_why(at, why)
end

--- What a piece of a JSONPath query reads as, and the byte after it.
local record Piece
  segment: Json.Segment
  name: string
  after: integer
end

--- What each escape a JSONPath string may hold (but `\u` and its
--- quote) stands for.
local STRING_ESCAPES <const>: {string: string} = {
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ["/"] = "/", ["\\"] = "\\",
}

--- The largest index RFC 9535 reads: I-JSON's integers, 2^53 - 1.
local MAX_INDEX <const> = (1 << 53) - 1

--- Whether byte `b` may start a member name written without quotes.
local function name_first(b: integer): boolean
  return b ~= nil and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b >= 128)
end

--- The string literal at byte `at` of `text`, quoted by the byte there,
--- as a piece's name, and ""; or nil and why.
local function query_string(text: string, at: integer): Piece | nil, string
  local quote = text:sub(at, at)
  local out: {string} = {}
  local i = at + 1
  while true do
    local b = text:byte(i)
    if b == nil then return query_error(at, "a string the query ends inside") end
    local c = text:sub(i, i)
    if c == quote then return { name = table.concat(out), after = i + 1 }, "" end
    if b < 32 then
      return query_error(i, "a control character in a string, which must be escaped")
    elseif c == "\\" then
      local e = text:sub(i + 1, i + 1)
      local simple = STRING_ESCAPES[e]
      if simple ~= nil then
        out[#out + 1] = simple
        i = i + 2
      elseif e == quote then
        out[#out + 1] = quote
        i = i + 2
      elseif e == "u" then
        local hex = text:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then
          return query_error(i, "`\\u` takes four hexadecimal digits")
        end
        local unit = math.tointeger(tonumber(hex, 16))
        i = i + 6
        if unit >= 0xDC00 and unit <= 0xDFFF then
          return query_error(i - 6, "a low surrogate with no high one before it")
        end
        if unit >= 0xD800 and unit <= 0xDBFF then
          local low = text:match("^\\u(%x%x%x%x)", i)
          local low_unit = low ~= nil and math.tointeger(tonumber(low, 16)) or 0
          if low_unit < 0xDC00 or low_unit > 0xDFFF then
            return query_error(i - 6, "a high surrogate with no low one after it")
          end
          unit = 0x10000 + ((unit - 0xD800) << 10) + (low_unit - 0xDC00)
          i = i + 6
        end
        out[#out + 1] = utf8.char(unit)
      else
        return query_error(i, "`\\" .. e .. "` is no escape a JSONPath string has")
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

--- Passes blank space (RFC 9535's `S`) from byte `at`.
local function blank(text: string, at: integer): integer
  local _, last = text:find("^[ \t\n\r]*", at)
  return last + 1
end

--- The selector of the bracketed selection at byte `at` (`[`), as a
--- piece's segment, and ""; or nil and why.
local function bracketed(text: string, at: integer, descendant: boolean): Piece | nil, string
  local i = blank(text, at + 1)
  local c = text:sub(i, i)
  local seg: Json.Segment = { descendant = descendant }
  if c == "'" or c == '"' then
    local piece, why = query_string(text, i)
    if piece == nil then return nil, why end
    seg.kind, seg.name, i = "name", piece.name, piece.after
  elseif c == "*" then
    seg.kind, i = "wildcard", i + 1
  elseif c == "-" or c:match("^%d$") then
    local digits = text:match("^%-?%d+", i)
    if digits == nil or not (digits:match("^0$") or digits:match("^%-?[1-9]%d*$")) then
      return query_error(i, "an index is 0, or has no leading zero and is not -0")
    end
    local index = #digits <= 17 and math.tointeger(tonumber(digits)) or nil
    if index == nil or index > MAX_INDEX or index < -MAX_INDEX then
      return query_error(i, "an index past 2^53 - 1")
    end
    seg.kind, seg.index, i = "index", index, i + #digits
  elseif c == ":" then
    return query_error(i, "slices (`start:end:step`) are not in the subset cosmic reads")
  elseif c == "?" then
    return query_error(i, "filters (`?`) are not in the subset cosmic reads")
  elseif c == "" then
    return query_error(i, "the query ends inside `[`")
  else
    return query_error(i, "a selector is a name in quotes, an index or `*`")
  end
  i = blank(text, i)
  c = text:sub(i, i)
  if c == ":" then
    return query_error(i, "slices (`start:end:step`) are not in the subset cosmic reads")
  end
  if c == "," then return query_error(i, "unions (`[a, b]`) are not in the subset cosmic reads") end
  if c ~= "]" then return query_error(i, "expected `]`") end
  return { segment = seg, after = i + 1 }, ""
end

--- The member name written without quotes at byte `at`, and the byte
--- after it.
local function shorthand(text: string, at: integer): string, integer
  local i = at
  while true do
    local b = text:byte(i)
    if b == nil or not (name_first(b) or (b >= 48 and b <= 57)) then break end
    i = i + 1
  end
  return text:sub(at, i - 1), i
end

--- Reads the JSONPath query `text` (RFC 9535) in the subset cosmic
--- reads: the root `$`, then segments, each a member's name (`.name`,
--- `['name']` or `["name"]`), an element's index (`[2]`, or `[-1]` from
--- the end), or `*` (`.*` or `[*]`) for every member or element, and
--- any of them after `..` for the same at every depth below. Each is
--- read exactly as the RFC's grammar reads it, blank space and string
--- escapes included. Filters (`?`), slices (`1:3`), unions (`[0, 1]`)
--- and functions are refused, naming what was meant, rather than read
--- as anything else. nil and a message naming the byte where it stops being one.
---
---     local q = assert(Json.query("$.users[*]['name']"))
---     assert(#q.segments == 3 and q.segments[2].kind == "wildcard")
function Json.query(text: string): Json.Query | nil, string
  local valid, bad = utf8.len(text)
  if valid == nil then return query_error(bad, "a byte that is not UTF-8") end
  if text:sub(1, 1) ~= "$" then return query_error(1, "a query starts with `$`") end
  local segments: {Json.Segment} = {}
  local at = 2
  while at <= #text do
    local before = at
    at = blank(text, at)
    if at > #text then return query_error(before, "blank space after the last segment") end
    local descendant = text:sub(at, at + 1) == ".."
    local seg: Json.Segment
    local after: integer
    if descendant or text:sub(at, at) == "." then
      local i = at + (descendant and 2 or 1)
      local c = text:sub(i, i)
      if c == "[" and descendant then
        local piece, why = bracketed(text, i, true)
        if piece == nil then return nil, why end
        seg, after = piece.segment, piece.after
      elseif c == "*" then
        seg, after = { descendant = descendant, kind = "wildcard" }, i + 1
      elseif name_first(text:byte(i)) then
        local name, next_at = shorthand(text, i)
        seg, after = { descendant = descendant, kind = "name", name = name }, next_at
      else
        return query_error(i, descendant and "after `..` comes a name, `*` or `[`" or
            "after `.` comes a name or `*`")
      end
    elseif text:sub(at, at) == "[" then
      local piece, why = bracketed(text, at, false)
      if piece == nil then return nil, why end
      seg, after = piece.segment, piece.after
    else
      return query_error(at, "a segment starts with `.`, `..` or `[`")
    end
    segments[#segments + 1] = seg
    at = after
  end
  return { text = text, segments = segments }, ""
end

--- The steps the JSONPath query `text` names, and "": a singular query,
--- `$` and names and indices alone, as [`Json.query`] reads one, each
--- index counted from 1 (or from the end, when negative). nil and a
--- message when it is no query or can select more than one value
--- (`*`, `..`): [`Json.select`] reads those.
---
---     local steps = assert(Json.from_path("$.users[0]['a key']"))
---     assert(steps[1] == "users" and steps[2] == 1 and steps[3] == "a key")
function Json.from_path(text: string): Json.Steps | nil, string
  local q, err = Json.query(text)
  if q == nil then return nil, err end
  local steps: Json.Steps = {}
  for i, seg in ipairs(q.segments) do
    if seg.descendant or seg.kind == "wildcard" then
      return refuse(("JSONPath %s selects many values (segment %d): read it with Json.query"):
          format(Json.quote(text), i))
    end
    if seg.kind == "name" then
      steps[i] = seg.name
    else
      steps[i] = seg.index >= 0 and seg.index + 1 or seg.index
    end
  end
  return steps, ""
end

--- The children of the table `t`, in order, each with its step: an
--- array's elements by position, an object's members by name in byte
--- order; nil and why for a table with mixed keys.
local function children(t: {any: any}): {Json.Match} | nil, string
  local m = Json.members(t, true)
  local out: {Json.Match} = {}
  if m.layout == "array" or m.layout == "hole" then
    if #m.keys > 0 then
      for _, k in ipairs(m.keys) do out[#out + 1] = { steps = { k }, value = t[k] } end
    else
      for i = 1, m.extent do
        if t[i] ~= nil then out[#out + 1] = { steps = { i }, value = t[i] } end
      end
    end
  elseif m.layout == "object" then
    for _, k in ipairs(m.keys) do out[#out + 1] = { steps = { k }, value = t[k] } end
  else
    return nil, "a table with mixed keys"
  end
  return out, ""
end

--- `steps` and one step more, a new list.
local function extended(steps: Json.Steps, step: string | integer): Json.Steps
  local out: Json.Steps = table.move(steps, 1, #steps, 1, {})
  out[#out + 1] = step
  return out
end

--- Appends to `out` what `seg`'s selector selects in `node`.
local function apply(seg: Json.Segment, node: Json.Match, out: {Json.Match}): boolean, string
  local t = table_of(node.value)
  if t == nil then return true, "" end
  local shape = container(t)
  if shape == "mixed" then
    return false, "json: the value at " .. at_pointer(pointer_of(node.steps)) .. " is a table with mixed keys"
  end
  if seg.kind == "name" then
    if shape == "object" and t[seg.name] ~= nil then
      out[#out + 1] = { steps = extended(node.steps, seg.name), value = t[seg.name] }
    end
  elseif seg.kind == "index" then
    if shape == "array" then
      local position = seg.index + 1
      if seg.index < 0 then position = last_position(t) + 1 + seg.index end
      if position >= 1 and t[position] ~= nil then
        out[#out + 1] = { steps = extended(node.steps, position), value = t[position] }
      end
    end
  else
    local kids, mixed = children(t)
    if kids == nil then return false, "json: " .. mixed end
    for _, kid in ipairs(kids) do
      out[#out + 1] = { steps = extended(node.steps, kid.steps[1]), value = kid.value }
    end
  end
  return true, ""
end

--- Applies `seg` to `node` and to every value beneath it, the node
--- before its children and an array's in order, as RFC 9535 visits
--- them; `depth` counts the levels walked, up to `limit`.
local function descend(seg: Json.Segment, node: Json.Match, out: {Json.Match}, depth: integer,
                       limit: integer): boolean, string
  local ok, why = apply(seg, node, out)
  if not ok then return false, why end
  local t = table_of(node.value)
  if t == nil then return true, "" end
  if depth >= limit then
    return false, "json: a value nests deeper than " .. String.counted(limit, "level") ..
      " at " .. at_pointer(pointer_of(node.steps)) .. " (does it contain itself?)"
  end
  local kids, mixed = children(t)
  if kids == nil then
    return false, "json: the value at " .. at_pointer(pointer_of(node.steps)) .. " is " .. mixed
  end
  for _, kid in ipairs(kids) do
    ok, why = descend(seg, { steps = extended(node.steps, kid.steps[1]), value = kid.value }, out,
      depth + 1, limit)
    if not ok then return false, why end
  end
  return true, ""
end

--- The values `query` selects in `value`, in the order RFC 9535 gives
--- them, each with its steps, and "": a member or element a name or an
--- index does not find selects nothing, and an object's members are
--- taken in byte order of their names, as `encode` writes them. nil and
--- a message for a table with mixed keys on the way, or a descendant
--- segment walking past `max_depth`.
---
---     local doc = assert(Json.decode('{"a": {"id": 1}, "b": [{"id": 2}]}'))
---     local found = assert(Json.select(doc, assert(Json.query("$..id"))))
---     assert(#found == 2 and found[1].value == 1 and found[2].value == 2)
---     assert(Json.pointer(found[2].steps) == "/b/0/id")
function Json.select(value: any, query: Json.Query, opts?: Json.SelectOptions): {Json.Match} | nil, string
  local limit = (opts or {}).max_depth or Json.depth_limit
  if math.type(limit) ~= "integer" or limit < 1 or limit > Json.depth_limit then
    error(("json: max_depth must be an integer from 1 to %d"):format(Json.depth_limit), 2)
  end
  local nodes: {Json.Match} = { { steps = {}, value = value } }
  for _, seg in ipairs(query.segments) do
    local out: {Json.Match} = {}
    for _, node in ipairs(nodes) do
      local ok, why: boolean, string
      if seg.descendant then
        ok, why = descend(seg, node, out, 0, limit)
      else
        ok, why = apply(seg, node, out)
      end
      if not ok then return nil, why end
    end
    nodes = out
  end
  return nodes, ""
end

-- ---- reading a token at a time ------------------------------------

--- An array or object the reader is inside.
local record Frame
  object: boolean
  --- What it takes next: "first" just after it opened (a value, or a
  --- key, or its close), "key" after an object's `,`, "colon" after a
  --- key, "value" where a value must come, "after" once one has.
  state: string
  --- An array's elements, or an object's members, begun so far.
  count: integer
  --- An object's last key.
  key: string
  --- An object's keys, unless duplicate keys are read.
  seen: {string: boolean}
end

local record TokenReader is Json.Reader
  source: Stream.Reader
  max_depth: integer
  duplicate_keys: boolean
  big: boolean
  lone: boolean
  json5: boolean
  hash: boolean
  null_value: any
  --- The bytes read and not yet passed, from `at`; `before` is how many
  --- the stream gave ahead of `buf`.
  buf: string
  at: integer
  before: integer
  ended: boolean
  failed: string
  --- The line the reader is on, and the offset its first byte has.
  line: integer
  line_start: integer
  --- Whether the last byte passed was a \r, which a \n after it joins.
  cr: boolean
  --- How much of a U+2028 or U+2029 (E2 80 A8 or A9) the bytes passed
  --- last ended with: 1 after E2, 2 after E2 80, else 0. Under `json5`
  --- a chunk may end inside one.
  lsep: integer
  frames: {Frame}
  next: function(TokenReader): Json.Token | nil, string
  peek: function(TokenReader): Json.TokenKind | nil, string
  value: function(TokenReader): any | nil, string
  steps: function(TokenReader): Json.Steps
  offset: function(TokenReader): integer
end

local token_reader_mt: metatable<TokenReader> = { __index = TokenReader }

function TokenReader:steps(): Json.Steps
  local steps: Json.Steps = {}
  for _, f in ipairs(self.frames) do
    if f.object then
      if f.key ~= nil then steps[#steps + 1] = f.key end
    elseif f.count > 0 then
      steps[#steps + 1] = f.count
    end
  end
  return steps
end

--- Where the reader is, for a message, as every message of this module
--- names a place.
local function here(self: TokenReader): string
  return at_pointer(pointer_of(self:steps()))
end

function TokenReader:offset(): integer
  return self.before + self.at - 1
end

--- Ends the reading with `why`, which every later call answers too; the
--- offset stays where it stopped.
local function stop(self: TokenReader, why: string): nil, string
  self.failed = why
  self.before = self.before + self.at - 1
  self.buf, self.at = "", 1
  return nil, why
end

--- Fails at byte `at` of `buf` with `what`, naming the line, the column
--- and where the reader is.
local function fail_at(self: TokenReader, at: integer, what: string): nil, string
  return stop(self, ("json: %s at line %d, column %d (%s)"):format(what, self.line,
    self.before + at - self.line_start, here(self)))
end

--- Fails at `column` of the line the reader is on, as [`fail_at`] does.
local function placed(self: TokenReader, column: integer, what: string): nil, string
  return stop(self, ("json: %s at line %d, column %d (%s)"):format(what, self.line, column, here(self)))
end

--- Moves the line count past `text`, which starts at `offset`. A line
--- ends at \n, \r or \r\n, and under `json5` at U+2028 and U+2029 too,
--- as `decode` counts them; `text` may begin or end inside one of those.
local function pass_lines(self: TokenReader, text: string, offset: integer)
  local n = #text
  local i = 1
  while self.lsep > 0 and i <= n do
    local b = text:byte(i)
    if self.lsep == 1 and b == 0x80 then
      self.lsep = 2
      i = i + 1
    elseif self.lsep == 2 and (b == 0xA8 or b == 0xA9) then
      self.lsep = 0
      self.line = self.line + 1
      self.line_start = offset + i
      i = i + 1
    else
      self.lsep = 0
    end
  end
  local pattern = self.json5 and "[\r\n\226]" or "[\r\n]"
  local from = i
  while true do
    local j = text:find(pattern, from)
    if j == nil then break end
    local b = text:byte(j)
    if b == 226 then
      if j + 2 <= n then
        local b2, b3 = text:byte(j + 1, j + 2)
        if b2 == 0x80 and (b3 == 0xA8 or b3 == 0xA9) then
          self.line = self.line + 1
          self.line_start = offset + j + 2
          from = j + 3
        else
          from = j + 1
        end
      else
        if j == n then
          self.lsep = 1
        elseif text:byte(j + 1) == 0x80 then
          self.lsep = 2
        end
        break
      end
    else
      local joined = b == 10 and (j > 1 and text:byte(j - 1) == 13 or j == 1 and self.cr)
      if not joined then self.line = self.line + 1 end
      self.line_start = offset + j
      from = j + 1
    end
  end
  if n > 0 then self.cr = text:byte(n) == 13 end
end

--- Passes `n` bytes that end no line: a \n after them starts one of
--- its own, whatever came before them.
local function pass(self: TokenReader, n: integer)
  self.at = self.at + n
  self.cr = false
  self.lsep = 0
end

--- Reads another chunk onto the bytes not yet passed. false and why
--- when the stream failed; true at its end too, `ended` then set. A
--- caller reading a token keeps what it has read of it and passes it
--- first, so only the bytes after `at` are copied.
local function fill(self: TokenReader): boolean, string
  if self.ended then return true, "" end
  local chunk, trouble = self.source:read()
  if chunk == nil then
    if trouble ~= "" then
      local _, why = stop(self, "json: " .. trouble)
      return false, why
    end
    self.ended = true
    return true, ""
  end
  self.before = self.before + self.at - 1
  self.buf = self.buf:sub(self.at) .. chunk
  self.at = 1
  return true, ""
end

--- The length of the whitespace JSON5 adds to JSON's, other than the
--- ASCII ones, at byte `i` of `s`: the same set `decode` reads; 0 when
--- none starts there.
local function ext_space_len(s: string, i: integer): integer
  local a, b, c = s:byte(i, i + 2)
  if a == 0xC2 then return b == 0xA0 and 2 or 0 end
  if a == 0xE2 then
    if b == 0x80 and c ~= nil and ((c >= 0x80 and c <= 0x8A) or c == 0xA8 or c == 0xA9 or c == 0xAF) then
      return 3
    end
    return (b == 0x81 and c == 0x9F) and 3 or 0
  end
  if a == 0xE1 then return (b == 0x9A and c == 0x80) and 3 or 0 end
  if a == 0xE3 then return (b == 0x80 and c == 0x80) and 3 or 0 end
  if a == 0xEF then return (b == 0xBB and c == 0xBF) and 3 or 0 end
  return 0
end

--- Passes the comment at `self.at` -- `//` or `#` to the end of the
--- line, `/*` to `*/` -- reading across chunks, its lines counted, and
--- adds its bytes to `parts` when given. A line comment stops before
--- the line end, which is whitespace; a block comment has its `*/`.
--- Bytes it must see more of to end -- a `*` that may begin `*/`, an
--- E2 or E2 80 that may begin U+2028 -- stay unpassed until the next
--- chunk. false and why when the stream failed or a block comment is
--- unterminated.
local function pass_comment(self: TokenReader, parts?: {string}): boolean, string
  --- Passes `n` bytes of the comment.
  local function take(n: integer)
    if n <= 0 then return end
    local text = self.buf:sub(self.at, self.at + n - 1)
    pass_lines(self, text, self.before + self.at - 1)
    self.at = self.at + n
    if parts ~= nil then parts[#parts + 1] = text end
  end
  local block = self.buf:byte(self.at) == 47 and self.buf:byte(self.at + 1) == 42
  take(self.buf:byte(self.at) == 47 and 2 or 1)
  while true do
    local buf, at = self.buf, self.at
    local last = #buf
    local hold = 0
    if block then
      local i = buf:find("*/", at, true)
      if i ~= nil then
        take(i + 2 - at)
        return true, ""
      end
      if not self.ended and last >= at and buf:byte(last) == 42 then hold = 1 end
    else
      local i = buf:find("[\r\n]", at)
      if self.json5 then
        local k = buf:find("\226\128[\168\169]", at)
        if k ~= nil and (i == nil or k < i) then i = k end
      end
      if i ~= nil then
        take(i - at)
        return true, ""
      end
      if self.json5 and not self.ended and last >= at then
        if buf:byte(last) == 0xE2 then
          hold = 1
        elseif last > at and buf:byte(last - 1) == 0xE2 and buf:byte(last) == 0x80 then
          hold = 2
        end
      end
    end
    take(last + 1 - at - hold)
    if self.ended then
      if block then
        local _, why = fail_at(self, self.at, "the text ends inside a comment")
        return false, why
      end
      return true, ""
    end
    local ok, why = fill(self)
    if not ok then return false, why end
  end
end

--- Passes whitespace and, as `json5` and `hash_comments` allow, comments,
--- reading as it must. false and why when the stream failed.
local function skip_space(self: TokenReader): boolean, string
  local plain = self.json5 and "^[ \t\r\n\v\f]*" or "^[ \t\r\n]*"
  while true do
    local _, last = self.buf:find(plain, self.at)
    if last >= self.at then
      pass_lines(self, self.buf:sub(self.at, last), self.before + self.at - 1)
      self.at = last + 1
    end
    local c = self.buf:byte(self.at)
    -- How many bytes tell whether `c` starts whitespace or a comment.
    local need = 1
    if c ~= nil and self.json5 then
      if c == 47 or c == 0xC2 then
        need = 2
      elseif c == 0xE1 or c == 0xE2 or c == 0xE3 or c == 0xEF then
        need = 3
      end
    end
    if #self.buf - self.at + 1 < need and not self.ended then
      local ok, why = fill(self)
      if not ok then return false, why end
    elseif c == nil then
      return true, ""
    elseif self.json5 and c >= 0x80 then
      local n = ext_space_len(self.buf, self.at)
      if n == 0 then return true, "" end
      pass_lines(self, self.buf:sub(self.at, self.at + n - 1), self.before + self.at - 1)
      self.at = self.at + n
    elseif (self.json5 and c == 47 and (self.buf:byte(self.at + 1) == 47 or self.buf:byte(self.at + 1) == 42)) or
        (self.hash and c == 35) then
      local ok, why = pass_comment(self)
      if not ok then return false, why end
    else
      return true, ""
    end
  end
end

--- The byte the reader is at, after whitespace and the `,` or `:` its
--- place takes, or nil at the end of the stream; or nil and why.
local function arrive(self: TokenReader): integer | nil, string
  if self.failed ~= "" then return nil, self.failed end
  local ok, why = skip_space(self)
  if not ok then return nil, why end
  local f = self.frames[#self.frames]
  if f ~= nil and (f.state == "after" or f.state == "colon") then
    local c = self.buf:byte(self.at)
    local close = f.object and 125 or 93
    if f.state == "colon" then
      if c ~= 58 then
        return fail_at(self, self.at, c == nil and "the text ends before a key's `:`" or
            "expected `:` after a key")
      end
      f.state = "value"
    elseif c == 44 then
      f.state = f.object and "key" or "value"
    elseif c == close then
      return c, ""
    else
      local closer = f.object and "`}`" or "`]`"
      return fail_at(self, self.at, c == nil and "the text ends inside an " ..
          (f.object and "object" or "array") or "expected `,` or " .. closer)
    end
    pass(self, 1)
    ok, why = skip_space(self)
    if not ok then return nil, why end
  end
  local c = self.buf:byte(self.at)
  if c == nil and #self.frames > 0 then
    return fail_at(self, self.at, "the text ends inside an " ..
        (self.frames[#self.frames].object and "object" or "array"))
  end
  return c, ""
end

--- Whether byte `c` can start an identifier, which JSON5 lets a key be:
--- a letter, `_`, `$`, a `\` that begins an escape, or a byte of a
--- character past ASCII.
local function starts_identifier(c: integer): boolean
  return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or c == 36 or c == 92 or c >= 128
end

--- The kind of token byte `c` starts where `f` is (nil at the top), or
--- nil when no token starts so. Under `json5`, `n` starting `nan` is a
--- number, which the byte after it, at `self.at + 1`, tells.
local function kind_of(self: TokenReader, c: integer, f: Frame): Json.TokenKind
  if c == 123 then return "object" end
  if c == 91 then return "array" end
  if c == 125 then return "end_object" end
  if c == 93 then return "end_array" end
  if f ~= nil and f.object and (f.state == "first" or f.state == "key") then
    if c == 34 or (self.json5 and (c == 39 or starts_identifier(c))) then return "key" end
  end
  if c == 34 or (self.json5 and c == 39) then return "string" end
  if c == 45 or (c >= 48 and c <= 57) then return "number" end
  if self.json5 and (c == 43 or c == 46 or c == 73 or c == 78 or c == 105) then return "number" end
  if c == 116 or c == 102 then return "boolean" end
  if c == 110 then
    local after = self.buf:byte(self.at + 1)
    if self.json5 and (after == 97 or after == 65) then return "number" end
    return "null"
  end
  return nil
end

--- Why a token of `token`'s kind, or one no byte starts (nil), cannot
--- come where `f` is; nil when it can. `json5` lets a close follow a
--- `,`.
local function misplaced(token: Json.TokenKind, f: Frame, json5: boolean): string
  if f == nil then
    if token == nil then return "a byte no JSON token starts with" end
    if token == "end_object" or token == "end_array" then return "a close with nothing open" end
    return nil
  end
  if token == "end_object" or token == "end_array" then
    if (token == "end_object") ~= f.object then return "a close that does not match its open" end
    if f.state == "value" and f.object then return "expected a value" end
    if f.state ~= "first" and f.state ~= "after" and
        not (json5 and (f.state == "key" or f.state == "value")) then
      return "a trailing `,`"
    end
    return nil
  end
  if f.object and (f.state == "first" or f.state == "key") then
    if token ~= "key" then return "expected a key" end
    return nil
  end
  if token == nil then return "expected a value" end
  return nil
end

--- The token at `self.at` made of the bytes `class` matches, read
--- across chunks and passed.
local function token_text(self: TokenReader, class: string): string | nil, string
  local parts: {string} = {}
  local pattern = "^" .. class .. "*"
  while true do
    local _, last = self.buf:find(pattern, self.at)
    parts[#parts + 1] = self.buf:sub(self.at, last)
    pass(self, last + 1 - self.at)
    if self.at <= #self.buf or self.ended then return table.concat(parts), "" end
    local ok, why = fill(self)
    if not ok then return nil, why end
  end
end

--- The string token at `self.at`, quotes and all, read across chunks and
--- passed; a failure is placed at `column`, where it starts.
local function string_text(self: TokenReader, column: integer): string | nil, string
  local parts: {string} = {}
  local start = self.at
  local from = self.at + 1
  local quote = self.buf:byte(self.at)
  local pattern = quote == 34 and '["\\]' or "['\\]"
  while true do
    local i = self.buf:find(pattern, from)
    if i ~= nil and self.buf:byte(i) == quote then
      parts[#parts + 1] = self.buf:sub(start, i)
      pass(self, i + 1 - self.at)
      return table.concat(parts), ""
    end
    if i ~= nil and i < #self.buf then
      from = i + 2
    else
      if self.ended then
        self.at = #self.buf + 1
        return placed(self, column, "a string the text ends inside")
      end
      -- What is read so far is kept, but a `\` the chunk ends with,
      -- which waits for the byte it escapes.
      local kept = i ~= nil and i - 1 or #self.buf
      parts[#parts + 1] = self.buf:sub(start, kept)
      self.at = kept + 1
      local ok, why = fill(self)
      if not ok then return nil, why end
      start, from = self.at, self.at
    end
  end
end

--- One scalar token's text, starting at `column`, read as `decode`
--- reads it; a failure is placed where the token is. It names no path:
--- only a key twice or nesting does, which a scalar cannot hold.
local function scalar(self: TokenReader, text: string, column: integer): any | nil, string
  local value, err = raw.decode(text, nil, nil, self.json5, self.big, self.lone, nil, false, false,
    self.line, column)
  if err ~= "" then return stop(self, "json: " .. err) end
  return value, ""
end

--- The unquoted key at `self.at`, which JSON5 allows: the bytes of an
--- identifier, to the first that is not one, read across chunks and
--- passed.
local function key_text(self: TokenReader): string | nil, string
  local parts: {string} = {}
  while true do
    local _, last = self.buf:find("^[%w_$\\]*", self.at)
    if last >= self.at then
      parts[#parts + 1] = self.buf:sub(self.at, last)
      pass(self, last + 1 - self.at)
    end
    local c = self.buf:byte(self.at)
    if c == nil then
      if self.ended then return table.concat(parts), "" end
      local ok, why = fill(self)
      if not ok then return nil, why end
    elseif c >= 0x80 then
      -- Whitespace ends a key, and may be some bytes long.
      local need = c == 0xC2 and 2 or (c == 0xE1 or c == 0xE2 or c == 0xE3 or c == 0xEF) and 3 or 1
      if #self.buf - self.at + 1 < need and not self.ended then
        local ok, why = fill(self)
        if not ok then return nil, why end
      elseif ext_space_len(self.buf, self.at) > 0 then
        return table.concat(parts), ""
      else
        parts[#parts + 1] = self.buf:sub(self.at, self.at)
        pass(self, 1)
      end
    else
      return table.concat(parts), ""
    end
  end
end

--- The unquoted key `text`, which starts at `column`, as `decode` reads
--- it: as the one key of an object, whose `{` moves every column
--- one on, so a failure is placed back.
-- TODO: read the key with a binding of its own, once `raw.decode` can
-- decode an identifier by itself: this wraps it in an object and moves
-- the column back in the message.
local function key_value(self: TokenReader, text: string, column: integer): any | nil, string
  local value, err = raw.decode("{" .. text .. ":0}", nil, nil, true, false, self.lone, nil, false,
    false, self.line, column)
  if err ~= "" then
    local back = err:gsub("(column )(%d+)", function(label: string, n: string): string
      return label .. tostring(tonumber(n) - 1)
    end, 1)
    return stop(self, "json: " .. back)
  end
  if value is {string: integer} then
    for key in pairs(value) do return key, "" end
  end
  return stop(self, "json: an object with no key")
end

--- `v` as a token's value: a string, a number or a boolean, or nil.
local function leaf(v: any): string | number | boolean
  if v is string then return v end
  if v is number then return v end
  if v is boolean then return v end
  return nil
end

--- Opens an array or object, refusing one past the depth limit.
local function open(self: TokenReader, object: boolean): boolean, string
  if #self.frames >= self.max_depth then
    local _, why = fail_at(self, self.at, "JSON nests deeper than " .. String.counted(self.max_depth, "level"))
    return false, why
  end
  self.frames[#self.frames + 1] = { object = object, state = "first", count = 0,
    seen = (object and not self.duplicate_keys) and {} or nil }
  pass(self, 1)
  return true, ""
end

--- Whether byte `b`, after a number or a word, ends it: whitespace, `,`,
--- a close, or where a comment or JSON5's whitespace may begin.
local function ends_token(self: TokenReader, b: integer): boolean
  if b == 32 or b == 9 or b == 10 or b == 13 or b == 44 or b == 93 or b == 125 then return true end
  if self.json5 and (b == 11 or b == 12 or b == 47 or b >= 128) then return true end
  return self.hash and b == 35
end

--- Marks a value begun where the reader is.
local function begin_value(self: TokenReader)
  local f = self.frames[#self.frames]
  if f == nil then return end
  if not f.object then f.count = f.count + 1 end
  f.state = "after"
end

function TokenReader:peek(): Json.TokenKind | nil, string
  local c, why = arrive(self)
  if c == nil then return nil, why end
  local f = self.frames[#self.frames]
  if self.json5 and c == 110 and self.at == #self.buf and not self.ended then
    -- `n` is `null` or `nan`: the byte after it says which.
    local ok, trouble = fill(self)
    if not ok then return nil, trouble end
  end
  local token = kind_of(self, c, f)
  local wrong = misplaced(token, f, self.json5)
  if wrong ~= nil then return fail_at(self, self.at, wrong) end
  if token == nil then return fail_at(self, self.at, "a byte no JSON token starts with") end
  return token, ""
end

function TokenReader:next(): Json.Token | nil, string
  local token, why = self:peek()
  if token == nil then return nil, why end
  local f = self.frames[#self.frames]
  -- Reading the token may read more of the stream, which moves `at`:
  -- where it starts is kept as its column.
  local column = self.before + self.at - self.line_start
  if token == "object" or token == "array" then
    begin_value(self)
    local ok, trouble = open(self, token == "object")
    if not ok then return nil, trouble end
    return { kind = token }, ""
  end
  if token == "end_object" or token == "end_array" then
    self.frames[#self.frames] = nil
    pass(self, 1)
    return { kind = token }, ""
  end
  local start = self.before + self.at - 1
  if token == "key" then
    local bare = self.buf:byte(self.at) ~= 34 and self.buf:byte(self.at) ~= 39
    local text: string
    local trouble: string
    if bare then
      text, trouble = key_text(self)
    else
      text, trouble = string_text(self, column)
    end
    if text == nil then return nil, trouble end
    local key: any
    local err: string
    if bare then
      key, err = key_value(self, text, column)
    else
      key, err = scalar(self, text, column)
    end
    if err ~= "" then return nil, err end
    if not (key is string) then return placed(self, column, "a key that is not a string") end
    f.key = key
    if f.seen ~= nil then
      if f.seen[f.key] then return placed(self, column, "duplicate key") end
      f.seen[f.key] = true
    end
    if self.json5 then pass_lines(self, text, start) end
    f.count = f.count + 1
    f.state = "colon"
    return { kind = "key", value = f.key }, ""
  end
  begin_value(self)
  local text: string
  local trouble: string
  if token == "string" then
    text, trouble = string_text(self, column)
  else
    local class = "%a"
    if token == "number" then class = self.json5 and "[%w+%-.]" or "[-+.%deE]" end
    text, trouble = token_text(self, class)
    if text ~= nil then
      -- A number or a word runs to the next byte that is not one of
      -- its own; the byte must end it, so `1true` is no two values.
      local after = self.buf:byte(self.at)
      if after ~= nil and not ends_token(self, after) then
        return fail_at(self, self.at, "expected whitespace, `,` or a close after a " ..
            (token == "number" and "number" or "word"))
      end
    end
  end
  if text == nil then return nil, trouble end
  local value: any
  if token == "boolean" or token == "null" then
    if text ~= "true" and text ~= "false" and text ~= "null" then
      return placed(self, column, "a word JSON has no literal for")
    end
    token = text == "null" and "null" or "boolean"
    value = text == "true"
    if token == "null" then value = nil end
  else
    local err: string
    value, err = scalar(self, text, column)
    if err ~= "" then return nil, err end
    if token == "string" and self.json5 then pass_lines(self, text, start) end
  end
  return { kind = token, value = leaf(value) }, ""
end

--- The text of the array or object at `self.at`, through its close,
--- read across chunks; the reader is past it after, its lines counted.
local function container_text(self: TokenReader): string | nil, string
  local parts: {string} = {}
  local start = self.at
  local from = self.at
  local open_count = 0
  --- Keeps the bytes from `start` up to `last`, counting their lines.
  local function keep(last: integer)
    local piece = self.buf:sub(start, last)
    pass_lines(self, piece, self.before + start - 1)
    parts[#parts + 1] = piece
  end
  local special = "[%[%]{}\"" .. (self.json5 and "'/" or "") .. (self.hash and "#" or "") .. "]"
  while true do
    local i = self.buf:find(special, from)
    if i == nil then
      keep(#self.buf)
      self.at = #self.buf + 1
      if self.ended then
        return fail_at(self, self.at, "the text ends inside an array or object")
      end
      local ok, why = fill(self)
      if not ok then return nil, why end
      start, from = self.at, self.at
    else
      local c = self.buf:byte(i)
      if c == 47 and i == #self.buf and not self.ended then
        -- Whether the `/` begins a comment waits on the byte after it.
        keep(i - 1)
        self.at = i
        local ok, why = fill(self)
        if not ok then return nil, why end
        start, from = self.at, self.at
      elseif (c == 47 and (self.buf:byte(i + 1) == 47 or self.buf:byte(i + 1) == 42)) or c == 35 then
        -- A comment's own brackets and quotes are none of the count.
        keep(i - 1)
        self.at = i
        local ok, why = pass_comment(self, parts)
        if not ok then return nil, why end
        start, from = self.at, self.at
      elseif c == 47 then
        from = i + 1
      elseif c == 34 or c == 39 then
        -- A string's own brackets are none of the count. Reading it
        -- passes it, so the bytes before it are kept first.
        keep(i - 1)
        self.at = i
        local offset = self.before + i - 1
        local text, why = string_text(self, offset - self.line_start + 1)
        if text == nil then return nil, why end
        pass_lines(self, text, offset)
        parts[#parts + 1] = text
        start, from = self.at, self.at
      elseif c == 91 or c == 123 then
        open_count = open_count + 1
        from = i + 1
      else
        open_count = open_count - 1
        from = i + 1
        if open_count == 0 then
          keep(i)
          self.at = i + 1
          return table.concat(parts), ""
        end
      end
    end
  end
end

function TokenReader:value(): any | nil, string
  local token, why = self:peek()
  if token == nil then
    if why ~= "" then return nil, why end
    return stop(self, "json: no value: the stream has ended")
  end
  if token == "key" or token == "end_object" or token == "end_array" then
    return fail_at(self, self.at, "expected a value")
  end
  if token ~= "object" and token ~= "array" then
    local read, trouble = self:next()
    if read == nil then return nil, trouble end
    if token == "null" then return self.null_value, "" end
    return read.value, ""
  end
  begin_value(self)
  if #self.frames >= self.max_depth then
    return fail_at(self, self.at, "JSON nests deeper than " .. String.counted(self.max_depth, "level"))
  end
  local path = pointer_of(self:steps())
  local line, column = self.line, self.before + self.at - self.line_start
  local text, trouble = container_text(self)
  if text == nil then return nil, trouble end
  local value, err = raw.decode(text, self.null_value, self.max_depth, self.json5,
    self.big, self.lone, nil, self.hash, self.duplicate_keys, line, column, path, #self.frames)
  if err ~= "" then return stop(self, "json: " .. err) end
  return value, ""
end

--- A reader of the JSON text `source` gives, a token at a time, holding
--- the token it is reading -- or, for `value`, the one value -- and,
--- unless `duplicate_keys`, the keys of each object it is inside, to
--- refuse one twice. The text may hold any number of values one after
--- another, as a log of them does; a number or a literal must be ended
--- by whitespace, a `,` or a close, so `1true` is refused rather than
--- read as two. `next` answers nil and "" once it has read past the last whole
--- one. A failure of `source` fails the reader; a `source` that raises
--- raises through it. It reads RFC 8259 JSON, or JSON5 under `json5`,
--- with `#` line comments under `hash_comments`, and refuses what
--- `decode` refuses under the same options: a key twice in an object
--- (unless `duplicate_keys`), nesting past `max_depth`. Under `json5` a
--- comment, JSON5's whitespace and a trailing `,` come where `decode`
--- reads them, and a token is what `decode` reads of its text: `'a'`,
--- `\x41`, `0x1F`, `+.5` and `-Infinity` are as they are in a decoded
--- text, and an unquoted key is a "key". A line is counted as `decode`
--- counts it under the options: a U+2028 or U+2029 ends one only in
--- JSON5. A failure names
--- the line, the column and, by its JSON Pointer, the place where the
--- text stopped being JSON.
---
---     local Stream = require("cosmic.stream")
---     local r = Json.reader(Stream.from_string('{"rows": [{"id": 1}, {"id": 2}]}'))
---     assert(r:next().kind == "object" and r:next().value == "rows")
---     assert(r:next().kind == "array")
---     local ids: {integer} = {}
---     while r:peek() == "object" do
---       local row = r:value() as {string: integer}
---       ids[#ids + 1] = row.id
---     end
---     assert(#ids == 2 and r:next().kind == "end_array")
function Json.reader(source: Stream.Reader, opts?: Json.ReaderOptions): Json.Reader
  local o: Json.ReaderOptions = opts or {}
  local depth = o.max_depth or Json.default_depth
  if math.type(depth) ~= "integer" or depth < 1 or depth > Json.depth_limit then
    error(("json: max_depth must be an integer from 1 to %d"):format(Json.depth_limit), 2)
  end
  local r: TokenReader = setmetatable({ source = source, max_depth = depth,
    duplicate_keys = o.duplicate_keys == true, big = o.big_numbers_as_strings == true,
    lone = o.lone_surrogates == true, json5 = o.json5 == true, hash = o.hash_comments == true,
    null_value = o.null_value, buf = "", at = 1, before = 0, ended = false, failed = "",
    line = 1, line_start = 0, cr = false, lsep = 0, frames = {} }, token_reader_mt)
  return r
end

return Json
