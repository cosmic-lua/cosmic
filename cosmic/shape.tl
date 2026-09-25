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
---   value always reports the same failure. `into_all` names every one,
---   for a config file whose author wants all their mistakes at once.
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

  --- One value that did not fit, as `into_all` lists it.
  record Failure
    --- The value's path from the root, `$.rows[2].id`.
    path: string
    --- The whole message `into` would answer for it, path first:
    --- `$.rows[2].id: expected string, got integer`.
    message: string
  end
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
  local kind: any = nil
  if spec is {any: any} then kind = spec["kind"] end
  if not (kind is string) or not KINDS[kind] then
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

--- What did not fit, and where: the path of the value that did not is
--- kept apart from the message so that `walk_either` can tell a
--- failure at a value from one inside it.
local type Miss = Shape.Failure

--- A new miss at `path`, listed in `all` when the walk is collecting
--- every one: each is made once, where it happens, and a container
--- only hands a child's on.
local function miss(path: string, what: string, all?: {Miss}): Miss
  local m: Miss = { path = path, message = path .. ": " .. what }
  if all ~= nil then all[#all + 1] = m end
  return m
end

local function mismatch(path: string, spec: Spec, v: any, all?: {Miss}): Miss
  return miss(path, ("expected %s, got %s"):format(wanted(spec), kind_of(v)), all)
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

--- `v` checked against `spec` at `path`. `all` is nil to stop at the
--- first miss, or the list collecting every one.
local walk: function(v: any, spec: Spec, path: string, all?: {Miss}): any, Miss

local function walk_either(v: any, spec: Spec, path: string, all: {Miss}): any, Miss
  local deepest: Miss = nil
  local deepest_all: {Miss} = nil
  for _, c in ipairs(spec.choices) do
    -- Each choice collects into a list of its own: only the one kept
    -- below reaches the caller's.
    local mine: {Miss} = nil
    if all ~= nil then mine = {} end
    local out, failed = walk(v, c, path, mine)
    if failed == nil then return out, nil end
    -- A choice that got past this value's own type and failed inside
    -- it says more than "expected A or B": keep the first such one.
    if deepest == nil and failed.path ~= path then
      deepest, deepest_all = failed, mine
    end
  end
  if deepest ~= nil then
    if all ~= nil then
      for _, m in ipairs(deepest_all) do all[#all + 1] = m end
    end
    return nil, deepest
  end
  return nil, mismatch(path, spec, v, all)
end

--- `t`'s keys for a map, when collecting every miss: its string keys in
--- byte order, and a miss listed for each key that is not a string,
--- those first, ordered by what they say. The first such miss, or nil.
local function map_keys(t: {any: any}, path: string, all: {Miss}): {string}, Miss
  local keys: {string} = {}
  local bad: {string} = {}
  for k in next, t do
    if k is string then
      keys[#keys + 1] = k
    else
      bad[#bad + 1] = ("expected map, got the %s key %s"):format(kind_of(k), shown(k))
    end
  end
  table.sort(keys)
  table.sort(bad)
  local first: Miss = nil
  for _, what in ipairs(bad) do
    local m = miss(path, what, all)
    if first == nil then first = m end
  end
  return keys, first
end

--- `v` checked against `spec`: the copy to answer and nil, or nil and
--- what did not fit -- the first thing, when `all` collects the rest.
walk = function(v: any, spec: Spec, path: string, all?: {Miss}): any, Miss
  if v == nil or rawequal(v, Json.null) then
    if spec.optional then return nil, nil end
    return nil, mismatch(path, spec, nil, all)
  end
  local kind = spec.kind
  if kind == "string" then
    if v is string then return v, nil end
  elseif kind == "number" then
    if v is number then return v, nil end
  elseif kind == "integer" then
    if v is integer then return v, nil end
    if v is number then
      local i = math.tointeger(v)
      if i ~= nil then return i, nil end
      return nil, miss(path, ("expected integer, got %s"):format(shown(v)), all)
    end
  elseif kind == "boolean" then
    if v is boolean then return v, nil end
  elseif kind == "any" then
    return v, nil
  elseif kind == "one_of" then
    for _, want in ipairs(spec.values) do
      if v == want then return v, nil end
    end
    if v is string or v is number or v is boolean then
      return nil, miss(path, ("expected %s, got %s"):format(wanted(spec), shown(v)), all)
    end
  elseif kind == "either" then
    return walk_either(v, spec, path, all)
  elseif v is {any: any} then
    local t = v
    if kind ~= "list" and Json.is_array(t) then
      return nil, mismatch(path, spec, t, all)
    end
    -- Collecting every miss, a container goes on past a child's, and
    -- answers the first.
    local first: Miss = nil
    if kind == "record" then
      local out: {string: any} = {}
      for _, name in ipairs(spec.names) do
        local got, failed = walk(rawget(t, name), spec.fields[name], field_path(path, name), all)
        if failed ~= nil then
          if all == nil then return nil, failed end
          first = first or failed
        end
        out[name] = got
      end
      if first ~= nil then return nil, first end
      return out, nil
    elseif kind == "list" then
      local keys, bad = indices(t)
      if keys == nil then
        return nil, miss(path, ("expected list, got the %s key %s"):format(kind_of(bad), shown(bad)), all)
      end
      -- A hole is a missing element: the first one fails a list whose
      -- elements are not optional, as a missing field fails a record.
      if all == nil and not spec.of.optional and #keys > 0 and keys[#keys] ~= #keys then
        local i = 1
        while keys[i] == i do i = i + 1 end
        return nil, mismatch(("%s[%d]"):format(path, i), spec.of, nil)
      end
      local out: {any} = {}
      local after = 0
      for _, i in ipairs(keys) do
        -- Collecting, each run of holes is one miss, at its first
        -- index, so a sparse list cannot answer a miss per index.
        if all ~= nil and not spec.of.optional and i > after + 1 then
          local hole = mismatch(("%s[%d]"):format(path, after + 1), spec.of, nil, all)
          first = first or hole
        end
        after = i
        local got, failed = walk(rawget(t, i), spec.of, ("%s[%d]"):format(path, i), all)
        if failed ~= nil then
          if all == nil then return nil, failed end
          first = first or failed
        end
        out[i] = got
      end
      if first ~= nil then return nil, first end
      return Json.array(out), nil
    elseif kind == "map" then
      local out: {string: any} = {}
      if all ~= nil then
        local keys: {string}
        keys, first = map_keys(t, path, all)
        for _, k in ipairs(keys) do
          local got, failed = walk(rawget(t, k), spec.of, field_path(path, k), all)
          first = first or failed
          out[k] = got
        end
        if first ~= nil then return nil, first end
        return out, nil
      end
      for k, e in next, t do
        if not (k is string) then
          return nil, miss(path, ("expected map, got the %s key %s"):format(kind_of(k), shown(k)))
        end
        local got, failed = walk(e, spec.of, field_path(path, k))
        if failed ~= nil then return nil, failed end
        out[k] = got
      end
      return out, nil
    end
  end
  if not KINDS[kind] then
    error(("shape: a Spec of unknown kind %q"):format(tostring(kind)), 0)
  end
  return nil, mismatch(path, spec, v, all)
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
-- TODO: `decode_into(text, spec, opts)`, decoding JSON and checking it in
-- one call, if the tree's call sites all turn out to pair the two.
function Shape.into<T>(value: any, spec: Spec): T | nil, string
  need_spec(spec, "into's shape")
  local out, failed = walk(value, spec, "$")
  if failed ~= nil then return nil, failed.message end
  -- cast: the one from `any`, which walk has just built to `spec`
  return out as T, ""
end

--- `into`, naming every value that does not fit rather than the first,
--- for a config file whose author wants all their mistakes at once: the
--- new value and an empty list, or nil and each failure in the order
--- the walk meets it -- a record's fields in byte order, a list's
--- elements by index, a map's keys in byte order after any key that is
--- not a string. A value that fails where it stands is not looked
--- inside, so a record that is a string is one failure, not one per
--- field; a run of missing list elements is one, at its first index;
--- and an `either` answers the failures of the first choice that got
--- inside the value, or one for the union. Raises only when `spec` is
--- not a Spec.
--- @param value any The decoded value
--- @param spec Spec The shape it must have
--- @return T The value, typed
--- @return {Failure} Every value that did not fit; empty when it fits
function Shape.into_all<T>(value: any, spec: Spec): T | nil, {Shape.Failure}
  need_spec(spec, "into_all's shape")
  local all: {Miss} = {}
  local out, failed = walk(value, spec, "$", all)
  if failed ~= nil then return nil, all end
  -- cast: the one from `any`, which walk has just built to `spec`
  return out as T, all
end

return Shape
