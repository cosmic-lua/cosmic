--- JSON encoding and decoding utilities.
--- Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.
---
--- NULL POLICY: Lua tables cannot hold nil values, so by default JSON
--- `null` decodes to nil and a null-valued object key simply vanishes —
--- `{"a":null,"b":1}` re-encodes as `{"b":1}`. That is the one lossy
--- case left, and both escape hatches are opt-in:
--- - `decode(s, {null_value = json.null})` substitutes a sentinel for
---   every `null`, so keys and array slots survive; `json.null`
---   re-encodes as `null`, closing the round trip.
--- - an array with holes is an ERROR on encode, never a silent
---   truncation; `sparse_as_null = true` encodes each hole as `null`,
---   which round-trips `[1,null,2]` losslessly with no sentinel at all.
--- - NaN and +/-Inf fail encode() with an error unless `nan_as_null=true`
---   is given, which serializes them as `null` (the v8 behavior).
---
--- Decoded arrays carry a shared marker metatable so an empty `[]`
--- re-encodes as `[]` instead of `{}`; use array() to mark empty tables
--- you build yourself.
local cosmo = require("cosmo")

--- Options accepted by encode(). All fields are optional.
local record Options
  --- Format across multiple lines for readability (default false).
  pretty: boolean
  --- Sort object keys for deterministic output (default true). Setting
  --- sorted=false can speed up serialization when ordering is irrelevant.
  sorted: boolean
  --- Indentation string used when pretty is true (default " ").
  indent: string
  --- Maximum serializer recursion depth (default 64, max 32767).
  max_depth: integer
  --- Encode NaN and +/-Inf as `null` (the v8 behavior) instead of
  --- failing with nil, error (default false).
  nan_as_null: boolean
  --- Encode array holes as `null` instead of failing with nil, error
  --- (default false). With it, an array that decoded from JSON
  --- containing `null` re-encodes losslessly.
  sparse_as_null: boolean
end

--- Options accepted by decode(). All fields are optional.
local record DecodeOptions
  --- A value to stand in for JSON `null`, so nulls survive the decode
  --- as something a Lua table can hold. Pass `json.null` to make the
  --- round trip lossless: it re-encodes as `null`. Without it, `null`
  --- decodes to nil (null-valued keys vanish, arrays get holes).
  null_value: any
end

--- Decode a JSON string into a Lua value.
--- Converts JSON strings, numbers, booleans, arrays, and objects into their Lua equivalents.
--- A successful decode of JSON `null` returns `nil, nil` — success the
--- house `if not v then` guard cannot tell from failure — so when the
--- input may be `null`, test the ERROR, not the value. Better, when
--- the top-level shape is known, use decode_object/decode_array: their
--- nil always means failure. JSON `null` becomes Lua nil by default, so
--- null-valued object keys vanish and arrays containing null decode
--- with holes; `opts.null_value` (typically `json.null`) substitutes a
--- sentinel instead, which also makes the value non-nil and so tells
--- success from failure by itself.
--- @param str string The JSON string to decode
--- @param opts DecodeOptions? null_value: stand-in for JSON null
--- @return any The decoded Lua value (table, string, number, boolean, or nil — and nil for JSON null)
--- @return string? Error message if decoding failed
local function decode(str: string, opts?: DecodeOptions): any, string
  if opts and opts.null_value ~= nil then
    return cosmo.DecodeJson(str, {nullval = opts.null_value})
  end
  local result, err = cosmo.DecodeJson(str)
  return result, err
end

--- Encode a Lua value as a JSON string.
--- Converts Lua tables, strings, numbers, booleans, and nil into JSON format.
--- NaN and +/-Inf fail with an error unless `nan_as_null=true` is
--- given, and an array with holes fails unless `sparse_as_null=true`
--- is; nil-valued table entries are absent (see the module-level null
--- policy above).
--- @param value any The Lua value to encode
--- @param opts Options? pretty, sorted, indent, max_depth, nan_as_null, sparse_as_null
--- @return string | nil The JSON string representation
--- @return string? Error message if encoding failed
local function encode(value: any, opts?: Options): string | nil, string
  local result: string
  local err: string | nil
  if opts then
    -- Build a plain table to avoid a nominal type conflict with
    -- cosmo's EncoderOptions record; the charter spellings map to the
    -- binding's own (maxdepth, nan="null", sparsenull) here.
    result, err = cosmo.EncodeJson(value, {
        pretty = opts.pretty,
        sorted = opts.sorted,
        indent = opts.indent,
        maxdepth = opts.max_depth,
        nan = opts.nan_as_null and "null" or nil,
        sparsenull = opts.sparse_as_null,
      })
  else
    result, err = cosmo.EncodeJson(value)
  end
  return result, err
end

-- The shared marker metatable decode() applies to every array it
-- decodes (and array() applies on demand); objects carry no metatable,
-- so the marker is what tells the two apart after a decode.
-- typed any: metatable<T>s for different T are not comparable
local array_marker: any = getmetatable(cosmo.jsonarray({}))

--- Describe a decoded value's JSON kind, for wrong-shape error messages.
local function decoded_kind(v: any): string
  if v == nil then
    return "null"
  end
  local t = type(v)
  if t ~= "table" then
    return t
  end
  if getmetatable(v) == array_marker then
    return "array"
  end
  return "object"
end

--- Decode a JSON object into a `{string: any}` map.
--- Fails when the input is invalid JSON OR valid JSON whose top-level
--- value is not an object, so the wrong-shape case is a real error
--- instead of a downstream indexing surprise. Nested values are `any`;
--- narrow uncertain shapes with `is`. Use decode() for the genuinely
--- dynamic case.
--- @param str string The JSON string to decode
--- @return {string: any} | nil The decoded object
--- @return string? Error message if decoding failed or the value is not an object
local function decode_object(str: string): {string: any} | nil, string
  local result, err = cosmo.DecodeJson(str)
  if err then
    return nil, err
  end
  if result is {string: any} then
    if getmetatable(result) ~= array_marker then
      return result
    end
  end
  return nil, "expected a JSON object, got " .. decoded_kind(result)
end

--- Decode a JSON array into a `{any}` list.
--- Fails when the input is invalid JSON OR valid JSON whose top-level
--- value is not an array. Elements are `any`; narrow uncertain shapes
--- with `is`. Use decode() for the genuinely dynamic case.
--- @param str string The JSON string to decode
--- @return {any} | nil The decoded array
--- @return string? Error message if decoding failed or the value is not an array
local function decode_array(str: string): {any} | nil, string
  local result, err = cosmo.DecodeJson(str)
  if err then
    return nil, err
  end
  if result is {any} then
    if getmetatable(result) == array_marker then
      return result
    end
  end
  return nil, "expected a JSON array, got " .. decoded_kind(result)
end

--- Mark a table as a JSON array so encode() serializes it as `[]` even
--- when it is empty (an unmarked empty table encodes as `{}`). decode()
--- applies the same marker to every array it decodes, which is how an
--- empty `[]` round-trips. Passing no argument creates and returns a
--- fresh marked table.
--- @param t {any}? The table to mark; a new empty table is created when omitted
--- @return {any} The same table (or the new one), marked as an array
local function array(t?: {any}): {any}
  return cosmo.jsonarray(t)
end

local record JsonModule
  type Options = Options
  type DecodeOptions = DecodeOptions

  --- The null sentinel: pass it as decode's `null_value` to keep JSON
  --- nulls, and it encodes back as `null`. An empty marked table, so
  --- `v == json.null` is the test.
  null: any

  decode: function(str: string, opts?: DecodeOptions): any, string
  decode_object: function(str: string): {string: any} | nil, string
  decode_array: function(str: string): {any} | nil, string
  encode: function(value: any, opts?: Options): string | nil, string
  array: function(t?: {any}): {any}
end

local M: JsonModule = {
  null = cosmo.null,
  decode = decode,
  decode_object = decode_object,
  decode_array = decode_array,
  encode = encode,
  array = array,
}

return M
