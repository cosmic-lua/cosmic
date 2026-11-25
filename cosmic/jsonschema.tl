--- JSON Schema (draft 2020-12) checked against a [`Json.Value`]: [`JsonSchema.compile`] reads a schema once, and
--- the [`JsonSchema.Schema`] it returns says whether a value is one the schema allows, and where it is not.
---
---     local Json = require("cosmic.json")
---     local JsonSchema = require("cosmic.jsonschema")
---
---     local schema = assert(JsonSchema.compile(assert(Json.decode(
---       '{"type":"object","properties":{"n":{"type":"integer","minimum":0}},"required":["n"]}'))))
---     assert(schema:check({ n = 2 }))
---     local ok, why = schema:check({ n = -1 })
---     print(ok, why.path, why.message) -- false  /n  -1 is less than the minimum, 0
---
--- A schema holds only the keywords this module asserts, so a value it allows is one the schema allows:
--- `type`, `enum`, `const`; `properties`, `required`, `additionalProperties`, `patternProperties` (refused, see
--- below), `propertyNames`, `minProperties`, `maxProperties`, `dependentRequired`; `items`, `prefixItems`,
--- `minItems`, `maxItems`, `uniqueItems`, `contains`, `minContains`, `maxContains`; `minLength`, `maxLength`;
--- `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`; `allOf`, `anyOf`, `oneOf`, `not`,
--- `if`, `then`, `else`; and `$ref` to the schema's root (`#`) or to one of its `$defs` (`#/$defs/name`), or of
--- `definitions`, the older name for them (`#/definitions/name`).
--- `true` and `false` are schemas too. Words for a reader are let through and assert nothing: `$schema`, `$id`
--- (at the root only), `$comment`, `title`, `description`, `default`, `examples`, `deprecated`, `readOnly`, `writeOnly`,
--- `format` (an annotation in 2020-12), `contentMediaType`, `contentEncoding`, and any keyword that starts with
--- `x-`. Any other keyword is refused, `pattern` and `patternProperties` among them: an ECMAScript regular
--- expression is not a Lua pattern, and a check that read one as the other would allow what the schema refuses.
--- So is a `$ref` anywhere else, or to a `$defs` the schema lacks, and `$anchor`.
---
--- A failure's `path` is the JSON Pointer of the value that broke the schema ("" for the whole value, "/n" above),
--- and its message says what is wrong and which keyword says so. A value nested past 64 levels, or a `$ref` that
--- leads back to itself without reading into the value, fails rather than recurse for good; so does a check past
--- 200000 steps, the most a schema whose `anyOf` or `$ref` branch on each other is given. A schema of more than
--- 10000 parts is refused.
---
--- A value is checked as it is in Lua: a JSON `null` is a value only where it was decoded with `null_value =
--- Json.null`. Decoded without it, a member that is `null` is absent, and is checked so, as the code that reads the
--- value then sees it.
--- @public

local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local String = require("cosmic.string")

local record JsonSchema
  --- A compiled schema: [`JsonSchema.compile`]'s result.
  interface Schema
    --- True where `value` is one the schema allows; false and the first place it is not, the JSON Pointer of the
    --- value in the failure's `path`.
    check: function(Schema, value: Json.Value): (true) | (false, Failure)
  end
end

--- How deep a value, or a chain of `$ref`, is followed.
local MAX_DEPTH <const> = 64

--- The most steps one check takes (a schema visited at a place, or two values compared), so a schema whose
--- `anyOf` or `$ref` branch on each other ends rather than run for an exponential time.
local MAX_STEPS <const> = 200000

--- The most schemas one compile reads.
local MAX_NODES <const> = 10000

--- The keywords read for a reader, which assert nothing.
local ANNOTATIONS <const>: {string: boolean} = {
  ["$schema"] = true, ["$comment"] = true, ["$defs"] = true,
  definitions = true, title = true, description = true, default = true, examples = true, deprecated = true,
  readOnly = true, writeOnly = true, format = true, contentMediaType = true, contentEncoding = true,
}

--- The names `type` takes.
local TYPES <const>: {string: boolean} = {
  null = true, boolean = true, object = true, array = true, number = true, integer = true, string = true,
}

--- One schema, compiled: a `true` or `false`, or the keywords of an object.
local record Node
  --- For `true` and `false`: what every value is.
  mut always?: boolean
  mut types?: {string: boolean}
  mut type_text?: string
  mut enum?: {Json.Value}
  mut const?: Json.Value
  mut has_const: boolean
  mut properties?: {string: Node}
  mut required?: {string}
  mut additional?: Node
  mut property_names?: Node
  mut min_properties?: integer
  mut max_properties?: integer
  mut dependent_required?: {string: {string}}
  mut items?: Node
  mut prefix_items?: {Node}
  mut min_items?: integer
  mut max_items?: integer
  mut unique_items: boolean
  mut contains?: Node
  mut min_contains?: integer
  mut max_contains?: integer
  mut min_length?: integer
  mut max_length?: integer
  mut minimum?: number
  mut maximum?: number
  mut exclusive_minimum?: number
  mut exclusive_maximum?: number
  mut multiple_of?: number
  mut all_of?: {Node}
  mut any_of?: {Node}
  mut one_of?: {Node}
  mut negated?: Node
  mut if_node?: Node
  mut then_node?: Node
  mut else_node?: Node
  --- The `$defs` name a `$ref` names ("" for the root), resolved as the check reads it.
  mut ref?: string
end

--- What a compile is building: the definitions a `$ref` may name.
local record Build
  defs: {string: Json.Value}
  compiled: mut {string: Node}
  mut root?: Node
  --- The schemas read so far.
  mut nodes: integer
  --- The steps the check now running has taken.
  mut steps: integer
end

--- The kind of JSON value `v` is: "null", "boolean", "number" (or "integer" for a whole one), "string", "array" or
--- "object".
local function kind_of(v: Json.Value): string
  if v is string then return "string" end
  if v is boolean then return "boolean" end
  if v is number then
    if math.type(v) == "integer" or (v == math.floor(v) and v > -2 ^ 63 and v < 2 ^ 63) then
      return "integer"
    end
    return "number"
  end
  if rawequal(v, Json.null) then return "null" end
  if Json.array_of(v) ~= nil then return "array" end
  return "object"
end

--- `name` escaped as a JSON Pointer's token.
local function token(name: string): string
  return (name:gsub("~", "~0"):gsub("/", "~1"))
end

local function fail(path: string, message: string): Failure
  return Failure.new(message, path)
end

--- The functions that call each other, on a record, as the checker asks of recursion.
local record S
end

--- Whether `a` and `b` are the same JSON value: numbers by value, arrays by order, objects by their members.
function S.equal(build: Build, a: Json.Value, b: Json.Value, depth: integer): boolean
  build.steps = build.steps + 1
  if depth > MAX_DEPTH then return false end
  local ka, kb = kind_of(a), kind_of(b)
  local numeric = (ka == "integer" or ka == "number") and (kb == "integer" or kb == "number")
  if numeric then return a == b end
  if ka ~= kb then return false end
  if ka == "array" then
    local xs, ys = assert(Json.array_of(a)), assert(Json.array_of(b))
    if #xs ~= #ys then return false end
    for i, v in ipairs(xs) do
      local w = ys[i]
      if w == nil or not S.equal(build, v, w, depth + 1) then return false end
    end
    return true
  elseif ka == "object" then
    local xs, ys = assert(Json.object_of(a)), assert(Json.object_of(b))
    for k, v in pairs(xs) do
      local w = ys[k]
      if w == nil or not S.equal(build, v, w, depth + 1) then return false end
    end
    for k in pairs(ys) do
      if xs[k] == nil then return false end
    end
    return true
  end
  return rawequal(a, b) or a == b
end

--- `value` as a whole number of at least 0, for the keyword `name`, or nil and why.
local function count_of(value: Json.Value, name: string, at: string): (integer) | (nil, Failure)
  if value is number then
    local n = math.tointeger(value)
    if n ~= nil and n >= 0 then return n end
  end
  return nil, fail(at, name .. " must be a whole number of at least 0")
end

local function number_of(value: Json.Value, name: string, at: string): (number) | (nil, Failure)
  if value is number then return value end
  return nil, fail(at, name .. " must be a number")
end

--- The schemas of a list, for the keyword `name`.
function S.list(build: Build, value: Json.Value, name: string, at: string, depth: integer): ({Node}) | (nil, Failure)
  local listed = Json.array_of(value)
  if listed == nil then return nil, fail(at, name .. " must be an array of schemas") end
  local out: mut {Node} = {}
  for i, each in ipairs(listed) do
    local node, why = S.compile(build, each, at .. "/" .. tostring(i - 1), depth + 1)
    if node == nil then return nil, why end
    out[#out + 1] = node
  end
  if #out == 0 then return nil, fail(at, name .. " must hold at least one schema") end
  return out
end

--- The keyword `key` of `o`, read into `node`; nil, or a failure.
function S.keyword(build: Build, node: Node, o: {string: Json.Value}, key: string, value: Json.Value, at: string,
                   depth: integer): Failure?
  local here = at .. "/" .. token(key)
  local function sub(): (Node) | (nil, Failure)
    return S.compile(build, value, here, depth + 1)
  end
  if ANNOTATIONS[key] == true or key:sub(1, 2) == "x-" then
    return nil
  elseif key == "$id" then
    -- A nested $id moves the base a $ref is read against, which this checker does not follow.
    if at ~= "" then
      return fail(here, "$id is let through only at the schema's root, not in one of its parts")
    end
    return nil
  elseif key == "type" then
    local names: mut {string} = {}
    if value is string then
      names[1] = value
    elseif Json.array_of(value) ~= nil then
      for _, v in ipairs(assert(Json.array_of(value))) do
        if not v is string then return fail(here, "type must be a name or an array of names") end
        names[#names + 1] = v
      end
    else
      return fail(here, "type must be a name or an array of names")
    end
    local types: mut {string: boolean} = {}
    for _, name in ipairs(names) do
      if TYPES[name] ~= true then return fail(here, Json.quote(name) .. " is not a type") end
      types[name] = true
    end
    node.types, node.type_text = types, table.concat(names, " or ")
  elseif key == "enum" then
    local listed = Json.array_of(value)
    if listed == nil then return fail(here, "enum must be an array") end
    node.enum = listed
  elseif key == "const" then
    node.const, node.has_const = value, true
  elseif key == "properties" then
    local members = Json.object_of(value)
    if members == nil then return fail(here, "properties must be an object of schemas") end
    local props: mut {string: Node} = {}
    for name, each in pairs(members) do
      local n, why = S.compile(build, each, here .. "/" .. token(name), depth + 1)
      if n == nil then return why end
      props[name] = n
    end
    node.properties = props
  elseif key == "required" or key == "dependentRequired" then
    local function names_of(v: Json.Value, at_: string): ({string}) | (nil, Failure)
      local listed = Json.array_of(v)
      if listed == nil then return nil, fail(at_, key .. " must list names") end
      local out: mut {string} = {}
      for _, n in ipairs(listed) do
        if not n is string then return nil, fail(at_, key .. " must list names") end
        out[#out + 1] = n
      end
      return out
    end
    if key == "required" then
      local names, why = names_of(value, here)
      if names == nil then return why end
      node.required = names
    else
      local members = Json.object_of(value)
      if members == nil then return fail(here, "dependentRequired must be an object") end
      local deps: mut {string: {string}} = {}
      for name, each in pairs(members) do
        local names, why = names_of(each, here .. "/" .. token(name))
        if names == nil then return why end
        deps[name] = names
      end
      node.dependent_required = deps
    end
  elseif key == "additionalProperties" or key == "propertyNames" or key == "items" or key == "contains" or
      key == "not" or key == "if" or key == "then" or key == "else" then
    local n, why = sub()
    if n == nil then return why end
    if key == "additionalProperties" then
      node.additional = n
    elseif key == "propertyNames" then
      node.property_names = n
    elseif key == "items" then
      node.items = n
    elseif key == "contains" then
      node.contains = n
    elseif key == "not" then
      node.negated = n
    elseif key == "if" then
      node.if_node = n
    elseif key == "then" then
      node.then_node = n
    else
      node.else_node = n
    end
  elseif key == "prefixItems" or key == "allOf" or key == "anyOf" or key == "oneOf" then
    local list, why = S.list(build, value, key, here, depth)
    if list == nil then return why end
    if key == "prefixItems" then
      node.prefix_items = list
    elseif key == "allOf" then
      node.all_of = list
    elseif key == "anyOf" then
      node.any_of = list
    else
      node.one_of = list
    end
  elseif key == "minProperties" or key == "maxProperties" or key == "minItems" or key == "maxItems" or
      key == "minContains" or key == "maxContains" or key == "minLength" or key == "maxLength" then
    local n, why = count_of(value, key, here)
    if n == nil then return why end
    if key == "minProperties" then
      node.min_properties = n
    elseif key == "maxProperties" then
      node.max_properties = n
    elseif key == "minItems" then
      node.min_items = n
    elseif key == "maxItems" then
      node.max_items = n
    elseif key == "minContains" then
      node.min_contains = n
    elseif key == "maxContains" then
      node.max_contains = n
    elseif key == "minLength" then
      node.min_length = n
    else
      node.max_length = n
    end
  elseif key == "minimum" or key == "maximum" or key == "exclusiveMinimum" or key == "exclusiveMaximum" or
      key == "multipleOf" then
    local n, why = number_of(value, key, here)
    if n == nil then return why end
    if key == "minimum" then
      node.minimum = n
    elseif key == "maximum" then
      node.maximum = n
    elseif key == "exclusiveMinimum" then
      node.exclusive_minimum = n
    elseif key == "exclusiveMaximum" then
      node.exclusive_maximum = n
    else
      if n <= 0 then return fail(here, "multipleOf must be above 0") end
      node.multiple_of = n
    end
  elseif key == "uniqueItems" then
    if not value is boolean then return fail(here, "uniqueItems must be true or false") end
    node.unique_items = value
  elseif key == "$ref" then
    if not value is string then return fail(here, "$ref must be a string") end
    local name: string?
    if value == "#" then
      name = ""
    else
      local escaped = value:match("^#/%$defs/([^/]+)$") or value:match("^#/definitions/([^/]+)$")
      if escaped ~= nil then name = (escaped:gsub("~1", "/"):gsub("~0", "~")) end
    end
    if name == nil then
      return fail(here, "$ref " .. Json.quote(value) .. " is not # or #/$defs/<name>: only a schema's own " ..
          "definitions are followed")
    end
    if name ~= "" and build.defs[name] == nil then
      return fail(here, "$ref " .. Json.quote(value) .. " names a definition the schema does not hold")
    end
    node.ref = name
  else
    return fail(here, "the keyword " .. Json.quote(key) .. " is not one this checker asserts, so a value it " ..
        "allowed could be one the schema refuses")
  end
  local _ = o
  return nil
end

--- `value` compiled as the schema at `at`, or nil and why.
function S.compile(build: Build, value: Json.Value, at: string, depth: integer): (Node) | (nil, Failure)
  if depth > MAX_DEPTH then return nil, fail(at, "the schema is nested past 64 levels") end
  build.nodes = build.nodes + 1
  if build.nodes > MAX_NODES then
    return nil, fail(at, "the schema holds more than " .. String.counted(MAX_NODES, "schema"))
  end
  if value is boolean then return { always = value, has_const = false, unique_items = false } end
  local members = if kind_of(value) == "object" then Json.object_of(value) else nil end
  if members == nil then return nil, fail(at, "a schema must be an object, true or false") end
  local node: Node = { has_const = false, unique_items = false }
  local keys: mut {string} = {}
  for k in pairs(members) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local member = members[k]
    assert(member ~= nil)
    local why = S.keyword(build, node, members, k, member, at, depth)
    if why ~= nil then return nil, why end
  end
  return node
end

--- The node a `$ref` names, compiled once.
local function resolved(build: Build, name: string): Node
  if name == "" then return assert(build.root) end
  local done = build.compiled[name]
  if done ~= nil then return done end
  local def = build.defs[name]
  assert(def ~= nil)
  local node = assert(S.compile(build, def, "/$defs/" .. token(name), 1))
  build.compiled[name] = node
  return node
end

--- Whether `v` is a multiple of `m`: exact for whole numbers, and for the rest within the rounding of the
--- quotient, so 0.3 is a multiple of 0.1 while 1e-10 is not one of 1; a quotient past 2^53 has no exact whole part
--- to test, and is not one.
local function multiple(v: number, m: number): boolean
  local vi, mi = math.tointeger(v), math.tointeger(m)
  if vi ~= nil and mi ~= nil then return vi % mi == 0 end
  local q = v / m
  if q ~= q or math.abs(q) >= 2 ^ 53 then return false end
  local whole = math.floor(q + 0.5)
  return math.abs(q - whole) <= math.max(math.abs(q), 1) * 1e-12 and (whole ~= 0 or v == 0)
end

--- The failure of a check past [`MAX_STEPS`].
local function too_long(path: string): Failure
  return fail(path, "the check took more than " .. String.counted(MAX_STEPS, "step") ..
      ": the schema's anyOf, oneOf or $ref branch on each other past what is checked")
end

--- Whether `v` is nested no more than [`MAX_DEPTH`] levels, its members counted as steps of `build`.
local function shallow(build: Build, v: Json.Value, depth: integer): boolean
  if depth > MAX_DEPTH then return false end
  build.steps = build.steps + 1
  local items = Json.array_of(v)
  if items ~= nil then
    for _, each in ipairs(items) do
      if not shallow(build, each, depth + 1) then return false end
    end
    return true
  end
  local members = if kind_of(v) == "object" then Json.object_of(v) else nil end
  if members ~= nil then
    for _, each in pairs(members) do
      if not shallow(build, each, depth + 1) then return false end
    end
  end
  return true
end

--- `v` as the schema prints it in a message.
local function shown(v: Json.Value): string
  local text, _ = Json.encode(v)
  if text == nil then return "the value" end
  if #text > 40 then return text:sub(1, 37) .. "..." end
  return text
end

--- Checks `v`, at `path`, against `node`; `depth` counts the levels and the `$ref` followed.
function S.check(build: Build, node: Node, v: Json.Value, path: string, depth: integer): Failure?
  if depth > MAX_DEPTH then
    return fail(path, "the value is nested past 64 levels, or a $ref leads back to itself")
  end
  build.steps = build.steps + 1
  if build.steps > MAX_STEPS then return too_long(path) end
  local always = node.always
  if always ~= nil then
    if always then return nil end
    return fail(path, "no value is allowed here (the schema is false)")
  end
  local ref = node.ref
  if ref ~= nil then
    local why = S.check(build, resolved(build, ref), v, path, depth + 1)
    if why ~= nil then return why end
  end
  local kind = kind_of(v)
  local types = node.types
  if types ~= nil and types[kind] ~= true and not (kind == "integer" and types["number"] == true) then
    return fail(path, shown(v) .. " is not " .. (node.type_text or "of the type") .. " (type)")
  end
  local enum = node.enum
  if enum ~= nil then
    local found = false
    for _, e in ipairs(enum) do
      if S.equal(build, v, e, 0) then
        found = true
        break
      end
    end
    if not found then return fail(path, shown(v) .. " is not one of the values enum allows") end
  end
  local const = node.const
  if node.has_const and const ~= nil and not S.equal(build, v, const, 0) then
    return fail(path, shown(v) .. " is not " .. shown(const) .. " (const)")
  end
  if v is string then
    local length = utf8.len(v) or #v
    local least, most = node.min_length, node.max_length
    if least ~= nil and length < least then
      return fail(path, "the string is shorter than " .. tostring(least) .. " (minLength)")
    end
    if most ~= nil and length > most then
      return fail(path, "the string is longer than " .. tostring(most) .. " (maxLength)")
    end
  elseif v is number then
    local lo, hi, xlo, xhi, m = node.minimum, node.maximum, node.exclusive_minimum, node.exclusive_maximum,
      node.multiple_of
    if lo ~= nil and v < lo then
      return fail(path, shown(v) .. " is less than the minimum, " .. shown(lo))
    end
    if hi ~= nil and v > hi then
      return fail(path, shown(v) .. " is more than the maximum, " .. shown(hi))
    end
    if xlo ~= nil and v <= xlo then
      return fail(path, shown(v) .. " is not above " .. shown(xlo) .. " (exclusiveMinimum)")
    end
    if xhi ~= nil and v >= xhi then
      return fail(path, shown(v) .. " is not below " .. shown(xhi) .. " (exclusiveMaximum)")
    end
    if m ~= nil and not multiple(v, m) then
      return fail(path, shown(v) .. " is not a multiple of " .. shown(m))
    end
  elseif kind == "array" then
    local why = S.array(build, node, assert(Json.array_of(v)), path, depth)
    if why ~= nil then return why end
  elseif kind == "object" then
    local why = S.object(build, node, assert(Json.object_of(v)), path, depth)
    if why ~= nil then return why end
  end
  return S.combined(build, node, v, path, depth)
end

function S.array(build: Build, node: Node, v: {Json.Value}, path: string, depth: integer): Failure?
  local n = #v
  local least_items, most_items = node.min_items, node.max_items
  if least_items ~= nil and n < least_items then
    return fail(path, "the array holds fewer than " .. String.counted(least_items, "item") .. " (minItems)")
  end
  if most_items ~= nil and n > most_items then
    return fail(path, "the array holds more than " .. String.counted(most_items, "item") .. " (maxItems)")
  end
  local prefix = node.prefix_items or {}
  for i, item in ipairs(v) do
    local schema = prefix[i] or node.items
    if schema ~= nil then
      local why = S.check(build, schema, item, path .. "/" .. tostring(i - 1), depth + 1)
      if why ~= nil then return why end
    end
  end
  if node.unique_items then
    for i = 1, n do
      for j = i + 1, n do
        local a, b = v[i], v[j]
        if build.steps > MAX_STEPS then return too_long(path) end
        if a ~= nil and b ~= nil and S.equal(build, a, b, 0) then
          return fail(path, "items " .. tostring(i - 1) .. " and " .. tostring(j - 1) .. " are the same (uniqueItems)")
        end
      end
    end
  end
  local contains = node.contains
  if contains ~= nil then
    local matched = 0
    for _, item in ipairs(v) do
      if S.check(build, contains, item, path, depth + 1) == nil then matched = matched + 1 end
      if build.steps > MAX_STEPS then return too_long(path) end
    end
    local least = node.min_contains or 1
    if matched < least then return fail(path, "too few items match contains") end
    local most_contains = node.max_contains
    if most_contains ~= nil and matched > most_contains then
      return fail(path, "too many items match contains (maxContains)")
    end
  end
  return nil
end

function S.object(build: Build, node: Node, v: {string: Json.Value}, path: string, depth: integer): Failure?
  local names: mut {string} = {}
  for k in pairs(v) do names[#names + 1] = k end
  table.sort(names)
  local least_props, most_props = node.min_properties, node.max_properties
  if least_props ~= nil and #names < least_props then
    return fail(path, "the object holds fewer than " .. String.counted(least_props, "member") .. " (minProperties)")
  end
  if most_props ~= nil and #names > most_props then
    return fail(path, "the object holds more than " .. String.counted(most_props, "member") .. " (maxProperties)")
  end
  for _, name in ipairs(node.required or {}) do
    if v[name] == nil then
      return fail(path, "the member " .. Json.quote(name) .. " is required")
    end
  end
  for name, needs in pairs(node.dependent_required or {}) do
    if v[name] ~= nil then
      for _, other in ipairs(needs) do
        if v[other] == nil then
          return fail(path, "the member " .. Json.quote(other) .. " is required with " .. Json.quote(name))
        end
      end
    end
  end
  local props = node.properties or {}
  for _, name in ipairs(names) do
    local member = v[name]
    assert(member ~= nil)
    local at = path .. "/" .. token(name)
    local keys = node.property_names
    if keys ~= nil then
      local why = S.check(build, keys, name, at, depth + 1)
      if why ~= nil then return why end
    end
    local schema = props[name] or node.additional
    if schema ~= nil then
      local why = S.check(build, schema, member, at, depth + 1)
      if why ~= nil then
        if props[name] == nil and schema.always == false then
          return fail(at, "the member " .. Json.quote(name) .. " is not one the schema names (additionalProperties)")
        end
        return why
      end
    end
  end
  return nil
end

function S.combined(build: Build, node: Node, v: Json.Value, path: string, depth: integer): Failure?
  for _, each in ipairs(node.all_of or {}) do
    local why = S.check(build, each, v, path, depth + 1)
    if why ~= nil then return why end
  end
  local any = node.any_of
  if any ~= nil then
    local first: Failure? = nil
    local ok = false
    for _, each in ipairs(any) do
      local why = S.check(build, each, v, path, depth + 1)
      if why == nil then
        ok = true
        break
      end
      if build.steps > MAX_STEPS then return too_long(path) end
      first = first or why
    end
    if not ok then
      return fail(path, "the value matches none of anyOf: " .. (if first ~= nil then first.message else "" end))
    end
  end
  local one = node.one_of
  if one ~= nil then
    local matched = 0
    for _, each in ipairs(one) do
      if S.check(build, each, v, path, depth + 1) == nil then matched = matched + 1 end
      if build.steps > MAX_STEPS then return too_long(path) end
    end
    if matched ~= 1 then
      return fail(path, "the value matches " .. tostring(matched) .. " of oneOf's schemas, not exactly one")
    end
  end
  local negated = node.negated
  if negated ~= nil then
    local matches = S.check(build, negated, v, path, depth + 1) == nil
    if build.steps > MAX_STEPS then return too_long(path) end
    if matches then return fail(path, "the value matches the schema not refuses") end
  end
  local cond = node.if_node
  if cond ~= nil then
    local held = S.check(build, cond, v, path, depth + 1) == nil
    if build.steps > MAX_STEPS then return too_long(path) end
    local branch = if held then node.then_node else node.else_node end
    if branch ~= nil then
      local why = S.check(build, branch, v, path, depth + 1)
      if why ~= nil then return why end
    end
  end
  return nil
end

--- A schema compiled, over its build.
local class Compiled is JsonSchema.Schema
  build: Build

  function check(self, value: Json.Value): (true) | (false, Failure)
    self.build.steps = 0
    if not shallow(self.build, value, 0) then
      return false, fail("", "the value is nested past 64 levels")
    end
    self.build.steps = 0
    local why = S.check(self.build, assert(self.build.root), value, "", 0)
    if why ~= nil then return false, why end
    return true
  end
end

--- `schema`, a JSON Schema as [`Json.decode`] reads one, compiled, or nil and why: the failure's `path` is the
--- JSON Pointer of the part of the schema refused, and its message says why (a keyword it does not assert, a
--- `$ref` it does not follow, a value a keyword cannot take). Each definition of `$defs` is compiled too, so one a
--- `$ref` does not reach is still checked.
function JsonSchema.compile(schema: Json.Value): (JsonSchema.Schema) | (nil, Failure)
  local defs: mut {string: Json.Value} = {}
  local top = if kind_of(schema) == "object" then Json.object_of(schema) else nil end
  if top ~= nil then
    for _, key in ipairs({ "$defs", "definitions" }) do
      local listed = top[key]
      if listed ~= nil then
        local named = if kind_of(listed) == "object" then Json.object_of(listed) else nil end
        if named == nil then
          return nil, fail("/" .. key, key .. " must be an object of schemas")
        end
        for name, each in pairs(named) do defs[name] = each end
      end
    end
  end
  local build: Build = { defs = defs, compiled = {}, nodes = 0, steps = 0 }
  local root, why = S.compile(build, schema, "", 0)
  if root == nil then return nil, why end
  build.root = root
  for name, each in pairs(defs) do
    local node, bad = S.compile(build, each, "/$defs/" .. token(name), 1)
    if node == nil then return nil, bad end
    build.compiled[name] = node
  end
  local compiled: Compiled = { build = build }
  return compiled
end

return JsonSchema
