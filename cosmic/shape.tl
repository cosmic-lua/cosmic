--- Checks a decoded value against a declared shape, and hands it back as
--- a typed record. What `cosmic.json` decodes, or a loaded chunk returns,
--- is `any`, and reading a field from it costs a cast that nothing checks.
--- `into` walks the value against a `Spec` built from the functions
--- below, once, and answers a new value holding what the spec names and
--- nothing else, so every read after it is an ordinary typed read.
---
---     local record Server
---       host: string
---       port: integer
---     end
---     local SERVER <const> = Shape.record({
---       host = Shape.string,
---       port = Shape.integer,
---     })
---     local server, err: Server | nil, string = Shape.into(decoded, SERVER)
---
--- The result's type comes from the caller's annotation, not from the
--- spec, and nothing checks that the two agree: a field the record has
--- and the spec lacks is simply never set. Teal infers the type in a
--- declaration with its error, as above, in a `return` from a function
--- declared `T | nil, string`, and in `local s: Server = must(...)`. A
--- bare `local s = must(Shape.into(...))` fails to compile with "cannot
--- infer declaration type".
---
--- The rules, fixed here:
---
--- - The answer is a copy. A record keeps only the fields its spec
---   names, so a key the payload grew is dropped rather than refused, and
---   the value handed in is never written to.
--- - JSON is the decoder in mind. A missing key and `Json.null`, which
---   `Json.decode(text, { null_value = Json.null })` puts where the text
---   says `null`, are the same thing: `optional` admits either and
---   answers nil. A list answers a JSON array (`Json.is_array`), so an
---   empty one encodes as `[]`, and a map or record refuses one.
--- - Nothing is converted, with one exception: `integer` takes a float
---   with no fraction, like the `8080.0` another language's encoder
---   writes, and answers the integer. `number` refuses `"1"`.
--- - A failure names the first value that does not fit, by its path
---   from the root as `cosmic.json` names one, `$.rows[2].id`, with list
---   indices counted from 1: `$.rows[2].id: expected string, got
---   integer`. A record's fields are checked in byte order, so the same
---   value always reports the same failure.
--- - `into` never raises on a value, whatever it holds. A spec that was
---   not built by these functions is a programming error, and raises.

local Json = require("cosmic.json")

local record Shape
  --- One node of a shape. Build it with the functions and values of
  --- this module; its fields are how `into` reads it, not an interface.
  record Spec
    --- Which check this node is: "string", "number", "integer",
    --- "boolean", "any", "list", "map", "record", "one_of" or "either".
    kind: string
    --- Whether a missing value satisfies it.
    optional: boolean
    --- The element's spec, for "list" and "map".
    of: Spec
    --- The fields' specs, for "record".
    fields: {string: Spec}
    --- The fields' names in byte order, for "record".
    names: {string}
    --- The values admitted, for "one_of".
    values: {string | number | boolean}
    --- The specs tried in turn, for "either".
    choices: {Spec}
  end

  --- Any string.
  string: Spec
  --- Any number, integer or float.
  number: Spec
  --- An integer, or a float with no fractional part that fits in one,
  --- which reads back as that integer.
  integer: Spec
  --- true or false.
  boolean: Spec
  --- Anything but a missing value, unchecked and not copied.
  any: Spec
end

local type Spec = Shape.Spec

-- TODO: a spec that tells `null` from a missing key (`nullable`), for a
-- payload where the two mean different things, as a PATCH body's do.
-- TODO: `big_integer`, taking the string of digits that
-- `big_numbers_as_strings` decodes an integer past 64 bits to.

local KINDS <const>: {string: boolean} = {
  ["string"] = true, ["number"] = true, ["integer"] = true,
  ["boolean"] = true, ["any"] = true, ["list"] = true, ["map"] = true,
  ["record"] = true, ["one_of"] = true, ["either"] = true,
}

local function leaf(kind: string): Spec
  return { kind = kind, optional = false }
end

Shape.string = leaf("string")
Shape.number = leaf("number")
Shape.integer = leaf("integer")
Shape.boolean = leaf("boolean")
Shape.any = leaf("any")
-- TODO: checks on a value past its type -- a range, a pattern, a
-- length -- as `Shape.check(spec, fn)` or a few named ones, when a caller
-- needs one.

--- Raises unless `spec` is one these functions built: a spec is part of
--- the program, so a wrong one is the caller's bug, not the data's.
local function need_spec(spec: any, what: string)
  if not (spec is table) or not KINDS[(spec as Spec).kind] then
    error(("shape: %s is not a Spec"):format(what), 3)
  end
end

--- A list whose every element has shape `of`: a table whose every key
--- is a positive integer, the empty table included. An index missing
--- below the highest is a missing element, which only an optional `of`
--- admits, so `[1, null, 3]` fits `list(optional(integer))` and comes
--- back with a hole, and fails `list(integer)` at `$[2]`. The answer is
--- marked a JSON array, so an empty one still encodes as `[]`.
--- @param of Spec Each element's shape
--- @return Spec The list's shape
function Shape.list(of: Spec): Spec
  need_spec(of, "list's element")
  return { kind = "list", optional = false, of = of }
end

--- A table whose every key is a string and every value has shape `of`,
--- the empty table included.
--- @param of Spec Each value's shape
--- @return Spec The map's shape
function Shape.map(of: Spec): Spec
  need_spec(of, "map's value")
  return { kind = "map", optional = false, of = of }
end

--- A table with the named fields, each of its own shape. Keys it does
--- not name are ignored, and left out of the answer.
-- TODO: a strict record, refusing a key it does not name, for a config
-- file where a misspelled key should fail rather than vanish.
-- TODO: `Shape.lazy(function(): Spec)`, so a spec can name itself for a
-- tree-shaped payload; `need_spec` would then check it on first use.
--- @param fields {string: Spec} Each field's shape, by its name
--- @return Spec The record's shape
function Shape.record(fields: {string: Spec}): Spec
  local own: {string: Spec} = {}
  local names: {string} = {}
  for name, spec in pairs(fields) do
    need_spec(spec, ("record's field %q"):format(name))
    own[name] = spec
    names[#names + 1] = name
  end
  table.sort(names)
  return { kind = "record", optional = false, fields = own, names = names }
end

--- The shape `of`, which a missing value, or `Json.null`, also
--- satisfies; either reads back as nil.
--- @param of Spec The shape a present value must have
--- @return Spec The optional shape
function Shape.optional(of: Spec): Spec
  need_spec(of, "optional's shape")
  return {
    kind = of.kind, optional = true, of = of.of, fields = of.fields,
    names = of.names, values = of.values, choices = of.choices,
  }
end

--- Exactly one of `values`, compared with `==`: the members of an
--- enumeration, such as `Shape.one_of("debug", "info", "warn")`.
--- Raises when given none.
--- @param ... string | number | boolean The values admitted
--- @return Spec The enumeration's shape
function Shape.one_of(...: string | number | boolean): Spec
  local values: {string | number | boolean} = { ... }
  if #values == 0 or #values ~= select("#", ...) then
    error("shape: one_of needs at least one value, and no nil", 2)
  end
  return { kind = "one_of", optional = false, values = values }
end

--- The first of `...` that the value satisfies, tried in order: a
--- value that is a string or a list of them is
--- `Shape.either(Shape.string, Shape.list(Shape.string))`. Raises when
--- given none.
--- @param ... Spec The shapes tried
--- @return Spec The union's shape
function Shape.either(...: Spec): Spec
  local choices: {Spec} = { ... }
  if #choices == 0 or #choices ~= select("#", ...) then
    error("shape: either needs at least one shape, and no nil", 2)
  end
  for i, c in ipairs(choices) do
    need_spec(c, ("either's choice %d"):format(i))
  end
  return { kind = "either", optional = false, choices = choices }
end

--- `s` as a JSON string, so a key or a value in a message reads the
--- same as it did in the text.
local function quoted(s: string): string
  return '"' .. s:gsub('[%c"\\]', function(c: string): string
    if c == '"' or c == "\\" then return "\\" .. c end
    return ("\\u%04x"):format(c:byte())
  end) .. '"'
end

--- The path of `key` under `path`: `.name` for a key that is a word,
--- `["a key"]` for one that is not.
local function field_path(path: string, key: string): string
  if key:match("^[%a_][%w_]*$") then
    return path .. "." .. key
  end
  return path .. "[" .. quoted(key) .. "]"
end

--- What a value is, for a message: the Lua type, with integer and float
--- told apart, and JSON's null and arrays by their JSON names.
local function kind_of(v: any): string
  if v == nil then return "nothing" end
  if rawequal(v, Json.null) then return "null" end
  if v is number then return math.type(v) end
  if Json.is_array(v) then return "array" end
  return type(v)
end

--- A value, spelled out for a message about which one it was.
local function shown(v: any): string
  if v is string then
    if #v > 40 then return quoted(v:sub(1, 40)) .. "..." end
    return quoted(v)
  end
  return tostring(v)
end

--- What `spec` asks for, for a message.
local function wanted(spec: Spec): string
  if spec.kind == "one_of" then
    local parts: {string} = {}
    for i, v in ipairs(spec.values) do parts[i] = shown(v) end
    return "one of " .. table.concat(parts, ", ")
  elseif spec.kind == "either" then
    local parts: {string} = {}
    for i, c in ipairs(spec.choices) do parts[i] = wanted(c) end
    return table.concat(parts, " or ")
  end
  return spec.kind
end

local function mismatch(path: string, spec: Spec, v: any): string
  return ("%s: expected %s, got %s"):format(path, wanted(spec), kind_of(v))
end

--- `t`'s keys in ascending order when every one is a positive
--- integer, or nil and the first key that is not.
local function indices(t: {any: any}): {integer}, any
  local keys: {integer} = {}
  for k in next, t do
    if not (k is integer) or k < 1 then return nil, k end
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys, nil
end

local walk: function(v: any, spec: Spec, path: string): any, string

local function walk_either(v: any, spec: Spec, path: string): any, string
  local deepest = ""
  for _, c in ipairs(spec.choices) do
    local out, err = walk(v, c, path)
    if err == "" then return out, "" end
    -- A choice that got past this value's own type and failed inside
    -- it says more than "expected A or B": keep the first such one.
    if deepest == "" and err:sub(1, #path + 1) ~= path .. ":" then
      deepest = err
    end
  end
  if deepest ~= "" then return nil, deepest end
  return nil, mismatch(path, spec, v)
end

--- `v` checked against `spec`: the copy to answer and "", or nil and
--- what did not fit.
walk = function(v: any, spec: Spec, path: string): any, string
  if v == nil or rawequal(v, Json.null) then
    if spec.optional then return nil, "" end
    return nil, mismatch(path, spec, nil)
  end
  local kind = spec.kind
  if kind == "string" then
    if v is string then return v, "" end
  elseif kind == "number" then
    if v is number then return v, "" end
  elseif kind == "integer" then
    if v is integer then return v, "" end
    if v is number then
      local i = math.tointeger(v)
      if i ~= nil then return i, "" end
      return nil, ("%s: expected integer, got %s"):format(path, shown(v))
    end
  elseif kind == "boolean" then
    if v is boolean then return v, "" end
  elseif kind == "any" then
    return v, ""
  elseif kind == "one_of" then
    for _, want in ipairs(spec.values) do
      if v == want then return v, "" end
    end
    if v is string or v is number or v is boolean then
      return nil, ("%s: expected %s, got %s"):format(path, wanted(spec), shown(v))
    end
  elseif kind == "either" then
    return walk_either(v, spec, path)
  elseif v is table then
    local t = v as {any: any}
    if kind ~= "list" and Json.is_array(t) then
      return nil, mismatch(path, spec, t)
    end
    if kind == "record" then
      local out: {string: any} = {}
      for _, name in ipairs(spec.names) do
        local got, err = walk(rawget(t, name), spec.fields[name], field_path(path, name))
        if err ~= "" then return nil, err end
        out[name] = got
      end
      return out, ""
    elseif kind == "list" then
      local keys, bad = indices(t)
      if keys == nil then
        return nil, ("%s: expected list, got the %s key %s"):format(path, kind_of(bad), shown(bad))
      end
      -- A hole is a missing element: the first one fails a list whose
      -- elements are not optional, as a missing field fails a record.
      if not spec.of.optional and #keys > 0 and keys[#keys] ~= #keys then
        local i = 1
        while keys[i] == i do i = i + 1 end
        return nil, mismatch(("%s[%d]"):format(path, i), spec.of, nil)
      end
      local out: {any} = {}
      for _, i in ipairs(keys) do
        local got, err = walk(rawget(t, i), spec.of, ("%s[%d]"):format(path, i))
        if err ~= "" then return nil, err end
        out[i] = got
      end
      return Json.array(out), ""
    elseif kind == "map" then
      local out: {string: any} = {}
      for k, e in next, t do
        if not (k is string) then
          return nil, ("%s: expected map, got the %s key %s"):format(path, kind_of(k), shown(k))
        end
        local got, err = walk(e, spec.of, field_path(path, k))
        if err ~= "" then return nil, err end
        out[k] = got
      end
      return out, ""
    end
  end
  if not KINDS[kind] then
    error(("shape: a Spec of unknown kind %q"):format(tostring(kind)), 0)
  end
  return nil, mismatch(path, spec, v)
end

--- `value` checked against `spec`, as a new value holding what the spec
--- names, and "". nil and the first thing that did not fit, named by
--- its path, when it does not. The answer's type is the caller's
--- annotation; see the module's comment for where Teal infers it.
--- Raises only when `spec` is not a Spec.
--- @param value any The decoded value
--- @param spec Spec The shape it must have
--- @return T The value, typed
--- @return string "" or what did not fit
-- TODO: an option answering every value that does not fit, not only the
-- first, for a config file whose author wants all their mistakes at once.
-- TODO: `decode_into(text, spec, opts)`, decoding JSON and checking it in
-- one call, if the tree's call sites all turn out to pair the two.
function Shape.into<T>(value: any, spec: Spec): T | nil, string
  need_spec(spec, "into's shape")
  local out, err = walk(value, spec, "$")
  if err ~= "" then return nil, err end
  -- cast: the one from `any`, which walk has just built to `spec`
  return out as T, ""
end

return Shape
