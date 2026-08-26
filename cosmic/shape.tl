--- Validate a decoded value into a declared record.
--- A value that comes out of json.decode, literal.parse, a loaded
--- chunk or Response:json() is `any`: every field read off it costs a
--- cast, and nothing checks that the field is the type the code
--- assumes. `into` walks the value against a Spec built from the
--- combinators below and hands it back typed, so the check happens
--- once and the reads are ordinary typed reads.
---
--- The target type comes from the CALLER's annotation, not from the
--- Spec. Three shapes infer it and one does not:
---
---   -- a function declared `T | nil, string`, returning it directly
---   return shape.into(raw, SPEC)
---   -- a local with its error
---   local m, err: Meta | nil, string = shape.into(raw, SPEC)
---   -- in tests
---   local m: Meta = check.must(shape.into(raw, SPEC))
---   -- and the one that FAILS, with "cannot infer declaration type":
---   local m = check.must(shape.into(raw, SPEC))
---
--- Example usage:
---   local shape = require("cosmic.shape")
---   local RELEASE <const> = shape.record({
---     tag_name = shape.string,
---     draft = shape.optional(shape.boolean),
---   })
---   local rel, err: Release | nil, string = shape.into(decoded, RELEASE)
---
--- Semantics, frozen here so they never re-open:
--- extra keys a Spec does not name are IGNORED, so a payload that
--- grows a field does not start failing; a missing key and a JSON
--- `null` are the same thing (both are nil) and `optional` is what
--- admits either; validation is recursive and total over what the
--- Spec names; nothing is coerced (`number` refuses `"1"`); errors are
--- plain strings carrying the first mismatch and its dotted path.
--- `into` returns the SAME table it was given, not a copy —
--- `integer` normalizes a whole-valued float to an integer in place,
--- which is the only write it makes.

--- One node of a shape description. Opaque to callers: build it with
--- the combinators and pass it to `into`, never construct it directly.
local record Spec
  --- Which validator this node is: one of the primitive names
  --- ("string", "number", "integer", "boolean", "any") or a container
  --- name ("list", "map", "integer_map", "record").
  kind: string
  --- The element Spec, for "list", "map" and "integer_map".
  of: Spec
  --- The declared fields, for "record".
  fields: {string: Spec}
  --- Whether nil satisfies this node.
  optional: boolean
end

--- Render a path for an error message. The root has no name of its
--- own, so it reads as "value".
--- @param path string The accumulated path, "" at the root
--- @return string The path as it appears in an error message
local function named(path: string): string
  if path == "" then
    return "value"
  end
  return path
end

--- Extend a path with a record field name.
--- @param path string The parent's path
--- @param key string The field name
--- @return string The child's path
local function field_path(path: string, key: string): string
  if path == "" then
    return key
  end
  return path .. "." .. key
end

--- Extend a path with a list index.
--- @param path string The parent's path
--- @param i integer The 1-based index
--- @return string The child's path
local function index_path(path: string, i: integer): string
  return path .. "[" .. tostring(i) .. "]"
end

--- The mismatch message for a value that is the wrong type.
--- @param path string The value's path
--- @param want string What the Spec asked for
--- @param got any The value that was found
--- @return string The error message
local function mismatch(path: string, want: string, got: any): string
  return named(path) .. ": expected " .. want .. ", got " .. type(got)
end

--- Count a table's keys, and whether they are exactly 1..n.
--- A decoded JSON array and a decoded JSON object are both tables, so
--- this is what tells "list" from "map" at runtime.
--- @param t {any:any} The table to measure
--- @return integer The number of keys
--- @return boolean Whether the keys are exactly the integers 1..count
local function count_keys(t: {any: any}): integer, boolean
  local n = 0
  local dense = true
  for k in pairs(t) do
    n = n + 1
    if not (k is integer) or k < 1 then
      dense = false
    end
  end
  if dense then
    for i = 1, n do
      if t[i] == nil then
        dense = false
      end
    end
  end
  return n, dense
end

--- Validate `parent[key]` against `spec`, writing back the normalized
--- value when `integer` converts a whole-valued float.
--- Recursive: containers walk their members through this same
--- function, which is what makes normalization uniform and lets the
--- top-level value be validated through a one-element holder.
--- @param parent {any:any} The table holding the value
--- @param key any The key the value sits under
--- @param spec Spec The shape the value must have
--- @param path string The value's path, "" at the root
--- @return string | nil The first mismatch, nil when the value is valid
local function walk(parent: {any: any}, key: any, spec: Spec, path: string): string | nil
  local v = parent[key]
  if v == nil then
    if spec.optional then
      return nil
    end
    return named(path) .. ": missing"
  end
  local kind = spec.kind
  if kind == "any" then
    return nil
  elseif kind == "string" or kind == "boolean" or kind == "number" then
    -- The three primitives Lua's own type() names, so one branch
    -- decides all of them; nothing is indexed, so no narrowing is
    -- needed to answer the question.
    if type(v) == kind then
      return nil
    end
    return mismatch(path, kind, v)
  elseif kind == "integer" then
    if v is number then
      local whole = math.tointeger(v)
      if whole == nil then
        return named(path) .. ": expected integer, got a fractional number"
      end
      parent[key] = whole
      return nil
    end
    return mismatch(path, "integer", v)
  elseif kind == "list" then
    if not (v is {any: any}) then
      return mismatch(path, "list", v)
    end
    local n, dense = count_keys(v)
    if not dense then
      return named(path) .. ": expected list, got a table with non-list keys"
    end
    for i = 1, n do
      local err = walk(v, i, spec.of, index_path(path, i))
      if err then
        return err
      end
    end
    return nil
  elseif kind == "map" then
    if not (v is {any: any}) then
      return mismatch(path, "map", v)
    end
    for k in pairs(v) do
      if not (k is string) then
        return named(path) .. ": expected map, got a non-string key"
      end
      local err = walk(v, k, spec.of, field_path(path, k))
      if err then
        return err
      end
    end
    return nil
  elseif kind == "integer_map" then
    if not (v is {any: any}) then
      return mismatch(path, "integer_map", v)
    end
    for k in pairs(v) do
      if not (k is integer) then
        return named(path) .. ": expected integer_map, got a non-integer key"
      end
      local err = walk(v, k, spec.of, index_path(path, k))
      if err then
        return err
      end
    end
    return nil
  elseif kind == "record" then
    if not (v is {any: any}) then
      return mismatch(path, "object", v)
    end
    for k, fs in pairs(spec.fields) do
      local err = walk(v, k, fs, field_path(path, k))
      if err then
        return err
      end
    end
    return nil
  end
  return named(path) .. ": unknown spec kind " .. kind
end

--- A primitive Spec node.
--- @param kind string The primitive's name
--- @return Spec The node
local function primitive(kind: string): Spec
  return {kind = kind}
end

--- A list whose every element has shape `of`.
--- @param of Spec The element shape
--- @return Spec The node
local function list(of: Spec): Spec
  return {kind = "list", of = of}
end

--- A table with string keys whose every value has shape `of`.
--- @param of Spec The value shape
--- @return Spec The node
local function map(of: Spec): Spec
  return {kind = "map", of = of}
end

--- A table with integer keys whose every value has shape `of`.
--- The keys need not be dense, which is the whole difference from
--- `list`: `{[3] = 7, [9] = 1}` is an integer_map and not a list.
--- JSON has no integer keys, so a value of this shape reaches `into`
--- only from a Lua-valued source — a loaded chunk, or `literal` once it
--- reads integer bracket keys.
--- @param of Spec The value shape
--- @return Spec The node
local function integer_map(of: Spec): Spec
  return {kind = "integer_map", of = of}
end

--- An object with the declared fields. Keys the fields table does not
--- name are ignored.
--- @param fields {string:Spec} The declared fields
--- @return Spec The node
local function record(fields: {string: Spec}): Spec
  return {kind = "record", fields = fields}
end

--- The same shape as `of`, satisfied by nil as well.
--- @param of Spec The shape to make optional
--- @return Spec The node
local function optional(of: Spec): Spec
  return {kind = of.kind, of = of.of, fields = of.fields, optional = true}
end

--- Validate `value` against `spec` and return it typed.
--- The returned table is the same table, not a copy. `T` comes from
--- the caller's annotation — see the module doc comment for the three
--- call shapes that infer it and the one that does not.
--- @param value any The decoded value to validate
--- @param spec Spec The shape it must have
--- @return T | nil The value, typed, when it validates
--- @return string The first mismatch, with its path, when it does not
local function into<T>(value: any, spec: Spec): T | nil, string
  local holder: {any: any} = {value}
  local err = walk(holder, 1, spec, "")
  if err then
    return nil, err
  end
  -- cast: the sole cast; walk has checked every field the Spec names
  return holder[1] as T
end

local record ShapeModule
  type Spec = Spec

  --- Any non-nil value; wrap in optional to admit nil.
  any: Spec
  --- A string.
  string: Spec
  --- A number, integer or float.
  number: Spec
  --- A number with no fractional part, normalized in place.
  integer: Spec
  --- A boolean.
  boolean: Spec

  list: function(of: Spec): Spec
  map: function(of: Spec): Spec
  integer_map: function(of: Spec): Spec
  record: function(fields: {string: Spec}): Spec
  optional: function(of: Spec): Spec
  into: function<T>(value: any, spec: Spec): (T | nil, string)
end

local M: ShapeModule = {
  any = primitive("any"),
  string = primitive("string"),
  number = primitive("number"),
  integer = primitive("integer"),
  boolean = primitive("boolean"),
  list = list,
  map = map,
  integer_map = integer_map,
  record = record,
  optional = optional,
  into = into,
}

return M
