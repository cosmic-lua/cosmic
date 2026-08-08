--- JSON encoding and decoding utilities.
--- Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.
---
--- NULL POLICY (lossy — read before round-tripping):
--- Lua tables cannot hold nil values, so JSON `null` does not survive a
--- decode/encode round-trip:
--- - `{"a":null,"b":1}` decodes with `a` absent and re-encodes as `{"b":1}`.
--- - `[1,null,2]` decodes with a hole at index 2; re-encoding sees a table
---   of length 1 and truncates to `[1]`.
--- - NaN and +/-Inf fail encode() with an error unless `nan_as_null=true`
---   is given, which serializes them as `null` (the v8 behavior).
--- If null-preserving round-trips matter, restructure the data (e.g. encode
--- explicit sentinel values) rather than relying on this module.
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
end

--- Decode a JSON string into a Lua value.
--- Converts JSON strings, numbers, booleans, arrays, and objects into their Lua equivalents.
--- A successful decode of JSON `null` returns `nil, nil` — success the
--- house `if not v then` guard cannot tell from failure — so when the
--- input may be `null`, test the ERROR, not the value. Better, when
--- the top-level shape is known, use decode_object/decode_array: their
--- nil always means failure. JSON `null` becomes Lua nil, so
--- null-valued object keys vanish and arrays containing null decode
--- with holes (see the module-level null policy above).
--- @param str string The JSON string to decode
--- @return any The decoded Lua value (table, string, number, boolean, or nil — and nil for JSON null)
--- @return string? Error message if decoding failed
local function decode(str: string): any, string
  local result, err = cosmo.DecodeJson(str)
  return result, err
end

--- Encode a Lua value as a JSON string.
--- Converts Lua tables, strings, numbers, booleans, and nil into JSON format.
--- NaN and +/-Inf fail with an error unless `nan_as_null=true` is
--- given; nil-valued table entries are absent (see the module-level
--- null policy above).
--- @param value any The Lua value to encode
--- @param opts Options? pretty, sorted, indent, max_depth, nan_as_null
--- @return string | nil The JSON string representation
--- @return string? Error message if encoding failed
local function encode(value: any, opts?: Options): string | nil, string
  local result: string
  local err: string | nil
  if opts then
    -- Build a plain table to avoid a nominal type conflict with
    -- cosmo's EncoderOptions record; the charter spellings map to the
    -- binding's own (maxdepth, nan="null") here.
    result, err = cosmo.EncodeJson(value, {
        pretty = opts.pretty,
        sorted = opts.sorted,
        indent = opts.indent,
        maxdepth = opts.max_depth,
        nan = opts.nan_as_null and "null" or nil,
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

  decode: function(str: string): any, string
  decode_object: function(str: string): {string: any} | nil, string
  decode_array: function(str: string): {any} | nil, string
  encode: function(value: any, opts?: Options): string | nil, string
  array: function(t?: {any}): {any}
end

local M: JsonModule = {
  decode = decode,
  decode_object = decode_object,
  decode_array = decode_array,
  encode = encode,
  array = array,
}

return M
