--- Checks a decoded value against a declared shape, and hands it back as
--- a typed record. What `cosmic.json` decodes, or a loaded chunk returns,
--- is `any`, and reading a field from it costs a cast that nothing checks.
--- `into` walks the value against a [`Spec`] once, and answers a new value
--- holding what the spec names and nothing else, so every read after it is
--- an ordinary typed read. A `Spec<T>` is the shape of a `T`: the functions
--- that build one give it the type of the check they make, so what `into`
--- answers is a `T` and no annotation stands between the two.
---
--- A record's spec is made by [`record_of`], which the build reads off the
--- record's own declaration, so a field added to the record is checked
--- from then on. Its parts are built from the others: `list`, `map`,
--- `optional`, [`one_of`], [`sparse_list`], and the leaves `string`, `number`,
--- `integer`, `boolean` and `any`.
---
---     local record Server
---       host: string
---       port: integer | nil
---     end
---     local SERVER <const> = Shape.record_of("Server")
---     local server, err = SERVER:into(decoded)
---     local servers, why = Shape.into(decoded, Shape.list(SERVER.spec))
---
--- [`decode_into`] is [`Json.decode`] and `into` in one call, for text that
--- is not used as anything but the record:
---
---     local server, err = Shape.decode_into(text, SERVER.spec)
---
--- An array holds every index from 1, so a list that may have a missing
--- element is not a `{T}`: `list(optional(x))` does not compile
--- (`array_of_optional`), and [`sparse_list`] answers `{integer: T}`.
---
--- [`Raw`] builds nodes that name no type, for the build and for tests of
--- the walk; `into` takes none of them.
---
--- The rules, fixed here:
---
--- - The answer is a copy. A record keeps only the fields its spec
---   names, so a key the payload grew is dropped rather than refused
---   ([`Typed.strict`] refuses it instead), and the value handed in is
---   never written to.
--- - JSON is the decoder in mind. A missing key and [`Json.null`], which
---   `Json.decode(text, { null_value = Json.null })` puts where the text
---   says `null`, are the same thing: `optional` admits either and
---   answers nil. A list answers a JSON array ([`Json.is_array`]), so an
---   empty one encodes as `[]`, and a map or record refuses one.
--- - Nothing is converted, with one exception: `integer` takes a float
---   with no fraction, like the `8080.0` another language's encoder
---   writes, and answers the integer. `number` refuses `"1"`.
--- - A failure names the first value that does not fit by its path from
---   the root `$`, list indices counted from 0 as the JSON document
---   counts them: `$.rows[1].id: want string, got integer`. A key that
---   is not an identifier is quoted as JSON quotes it, `$["a b"]`, and
---   a value that is not there, or [`Json.null`], is `$.rows[1].id: missing`. A failure of
---   [`record_of`]'s `into` starts with the record's name, as
---   `Envelope: $.rows[1].id: missing`. A record's
---   fields and a map's keys are checked in byte order, and a list's
---   elements in index order, so the same value
---   always reports the same failure. Only the first is answered: a
---   config file whose author wants every mistake sees them one at a
---   time, re-running after each fix.
--- - `into` never raises on a value, whatever it holds. A spec that was
---   not built by these functions is a programming error, and raises.

local FieldPath = require("cosmic.internal.field_path")
local Json = require("cosmic.json")

local record Shape
  --- Which check a [`Node`] is.
  enum Kind
    "string"
    "number"
    "integer"
    "boolean"
    "any"
    "list"
    "map"
    "record"
    "one_of"
  end

  --- One node of a shape, the tree `into` walks. It names no type: a [`Spec`] pairs one with the type it checks for, and
  --- [`Raw`] builds them bare, for the build's [`record_of`] and for tests of the walk.
  record Node
    --- Which check this node is.
    kind: Shape.Kind
    --- Whether a missing value satisfies it.
    optional: boolean
    --- The element's node, for "list" and "map".
    of?: Node
    --- The fields' nodes, for "record".
    fields?: {string: Node}
    --- The fields' names in byte order, for "record".
    names?: {string}
    --- Whether a key `fields` does not name is refused, for "record".
    strict?: boolean
    --- The values admitted, for "one_of".
    values?: {string | number | boolean}
  end

  --- A shape, and the type `T` of what it checks: a value that passes it is a `T`. The functions below build one from
  --- another, so `T` follows from how it was built, and [`into`] answers it with no annotation to disagree. A record's
  --- spec is made by [`record_of`], from the record's own declaration.
  record Spec<T>
    --- What `into` walks.
    node: Node
    --- Never set. A record with a type parameter that no field mentions leaves the checker nothing to solve `T` from,
    --- so this field, a function that would answer a `T`, makes `Spec<string>` and `Spec<integer>` two types.
    witness?: function(): T
  end

  --- A [`Spec`] and the record `T` it was built from, which [`record_of`] answers. Its methods answer a `T`.
  record Typed<T>
    --- The record's shape: what [`record_of`] builds for the fields it declares.
    spec: Spec<T>
    --- The record's name, as [`record_of`] was given it. A failure of
    --- `into` or [`decode_into`] starts with it: `Envelope: $.items[3].name: missing`.
    name: string
    --- [`into`] over `spec`, answering a `T`.
    into: function(self: Typed<T>, value: any): T?, string
    --- [`decode_into`] over `spec`, answering a `T`.
    decode_into: function(self: Typed<T>, text: string, opts?: Json.DecodeOptions): T?, string
    --- This record's shape, refusing every key a record in it does not name (`{"prot": 8080}` fails with `$.prot: unknown
    --- key` where the record has `port`), for a config file where a misspelled key should fail rather than vanish.
    strict: function(self: Typed<T>): Typed<T>
    --- The result of `strict`, kept by it.
    mut stricter?: Typed<T>
  end

  --- The nodes with no type, built as [`Spec`]s are. They are what the build splices into [`record_of`] and what tests of
  --- the walk draw; nothing here can be given to [`into`], which asks for a [`Spec`].
  record Raw
    --- Any string.
    string: Node
    --- Any number, integer or float.
    number: Node
    --- An integer, or a float with no fractional part that fits in one.
    integer: Node
    --- true or false.
    boolean: Node
    --- Anything but a missing value, unchecked and not copied.
    any: Node
    --- A list of `of`.
    list: function(of: Node): Node
    --- A map from strings to `of`.
    map: function(of: Node): Node
    --- `of`, or a missing value.
    optional: function(of: Node): Node
    --- Exactly one of the values.
    one_of: function(...: string | number | boolean): Node
    --- A table with the named fields.
    record: function(fields: {string: Node}): Node
    --- A record that refuses every key it does not name.
    strict_record: function(fields: {string: Node}): Node
    --- `node`, a record or a map, as a spec of a table of untrusted values: the one type its answer has whatever the
    --- fields hold. For a program that binds records it did not declare, such as a test that draws them.
    table_of: function(node: Node): Spec<{string: any}>
    --- `value` checked against `node`, as [`into`] does, answering the checked copy as it is, since nothing says its type.
    check: function(value: any, node: Node): any, string
  end

  --- The nodes with no type.
  mut raw: Raw

  --- Any string.
  mut string: Spec<string>
  --- Any number, integer or float.
  mut number: Spec<number>
  --- An integer, or a float with no fractional part that fits in one,
  --- which reads back as that integer.
  mut integer: Spec<integer>
  --- true or false.
  mut boolean: Spec<boolean>
  --- Anything but a missing value, unchecked and not copied.
  mut any: Spec<any>
end

local type Node = Shape.Node

--- Each [`Shape.Kind`] by its spelling. Teal's `is` on an enum tests
--- only for a string, so [`need_node`] asks this table instead. Nothing
--- ties it to the enum: the tests build a node of every kind, so a kind
--- left out fails there.
local KINDS <const>: {string: Shape.Kind} = {
  string = "string", number = "number", integer = "integer", boolean = "boolean",
  any = "any", list = "list", map = "map", record = "record", one_of = "one_of",
}

local function leaf(kind: Shape.Kind): Node
  return { kind = kind, optional = false }
end

local STRING <const> = leaf("string")
local NUMBER <const> = leaf("number")
local INTEGER <const> = leaf("integer")
local BOOLEAN <const> = leaf("boolean")
local ANY <const> = leaf("any")

--- Raises unless `node` is one these functions built: a shape is part of
--- the program, so a wrong one is the caller's bug, not the data's.
local function need_node(node: any, what: string)
  local kind: any = nil
  if node is {any: any} then kind = node["kind"] end
  if not (kind is string) or KINDS[kind] == nil then
    error(("shape: %s is not a Spec"):format(what), 3)
  end
end

--- The nodes of the specs this module made. A [`Spec`] is a table anyone can write, so what ties its `T` to the check it
--- holds is that its node is here: `into` and every constructor refuse a spec whose node is not.
local made: mut {Node: boolean} = {}

--- A [`Spec`] of a copy of `node`, which the registry holds: the copy is this spec's alone, so a node shared between
--- specs (the leaves of [`Raw`], say) never makes a spec that was written by hand look made.
local function spec_of<T>(node: Node): Shape.Spec<T>
  local own: Node = {
    kind = node.kind, optional = node.optional, of = node.of, fields = node.fields, names = node.names,
    strict = node.strict, values = node.values,
  }
  made[own] = true
  return { node = own }
end

--- Raises unless `spec` was made by this module.
local function need_made<T>(spec: Shape.Spec<T>, what: string)
  if made[spec.node] ~= true then
    error(("shape: %s is a Shape.Spec that cosmic.shape did not make: build it with Shape.<constructor> or " ..
      "Shape.record_of"):format(what), 3)
  end
end

local function raw_list(of: Node): Node
  need_node(of, "list's element")
  return { kind = "list", optional = false, of = of }
end

local function raw_map(of: Node): Node
  need_node(of, "map's value")
  return { kind = "map", optional = false, of = of }
end

--- A record's node over a copy of `fields`, its names in byte order.
local function record_node(fields: {string: Node}, strict: boolean, what: string): Node
  local own: mut {string: Node} = {}
  local names: mut {string} = {}
  for name, node in pairs(fields) do
    need_node(node, ("%s's field %q"):format(what, name))
    own[name] = node
    names[#names + 1] = name
  end
  table.sort(names)
  return { kind = "record", optional = false, fields = own, names = names, strict = strict }
end

local function raw_optional(of: Node): Node
  need_node(of, "optional's shape")
  return {
    kind = of.kind, optional = true, of = of.of, fields = of.fields,
    names = of.names, strict = of.strict, values = of.values,
  }
end

local function raw_one_of(...: string | number | boolean): Node
  local values: {string | number | boolean} = { ... }
  if #values == 0 or #values ~= select("#", ...) then
    error("shape: one_of needs at least one value, and no nil", 3)
  end
  return { kind = "one_of", optional = false, values = values }
end

local quoted = FieldPath.quote

local field_path, index_path = FieldPath.field, FieldPath.index

--- What a value is, for a message: the Lua type, with integer and float
--- told apart, and arrays by their JSON name.
local function kind_of(v: any): string
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
local function wanted(spec: Node): string
  if spec.kind == "one_of" then
    local parts: mut {string} = {}
    for i, v in ipairs(assert(spec.values)) do parts[i] = shown(v) end
    return "one of " .. table.concat(parts, ", ")
  end
  return spec.kind
end

--- `path`'s message for a value of the wrong kind.
local function mismatch(path: string, spec: Node, v: any): string
  if v == nil then return path .. ": missing" end
  return ("%s: want %s, got %s"):format(path, wanted(spec), kind_of(v))
end

--- A key a list or a map refuses, for a message: a scalar by its value,
--- anything else by its type alone, since its address would make the
--- same value's message differ from run to run.
local function key_named(k: any): string
  if k is string or k is number or k is boolean then
    return ("the %s key %s"):format(kind_of(k), shown(k))
  end
  return ("a %s key"):format(type(k))
end

local KEY_RANK <const>: {string: integer} = { number = 1, boolean = 2, string = 3 }

--- An order on keys that no address decides: numbers, then booleans,
--- then strings, each by value, then the rest by type. Keys of one
--- other type tie, and their messages are the same.
local function key_before(a: any, b: any): boolean
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    local ra, rb = KEY_RANK[ta] or 4, KEY_RANK[tb] or 4
    if ra ~= rb then return ra < rb end
    return ta < tb
  end
  if a is number and b is number then return a < b end
  if a is boolean and b is boolean then return not a and b end
  if a is string and b is string then return a < b end
  return false
end

local function is_index(k: any): boolean
  return k is integer and k >= 1
end

local function is_name(k: any): boolean
  return k is string
end

--- The first key of `t`, in [`key_before`]'s order, that `good` refuses,
--- or nil when it refuses none.
local function least_refused(t: {any: any}, good: function(any): boolean): any
  local least: any = nil
  for k in next, t do
    if not good(k) and (least == nil or key_before(k, least)) then least = k end
  end
  return least
end

--- The message for a container of `kind` that holds a key it refuses.
local function refusal(path: string, kind: string, key: any): string
  return ("%s: want %s, got %s"):format(path, kind, key_named(key))
end

--- What a strict record `spec` refuses in `t`, before any field is
--- looked at: a key that is not a string, named where the record
--- stands, or else the first string key it does not name, in byte
--- order, named where that key is (`$.prot: unknown key`). A key that
--- is not a string takes precedence, so a strict record fails where it
--- stands or at its keys, never at a field as well. Answers the message,
--- or "".
local function unknown_key(t: {any: any}, spec: Node, path: string): string
  local members = Json.members(t)
  if members.layout ~= "object" then
    local refused = least_refused(t, is_name)
    if refused ~= nil then return refusal(path, "record", refused) end
    return ""
  end
  local fields = assert(spec.fields)
  for _, k in ipairs(members.keys) do
    if k is string and fields[k] == nil then
      return field_path(path, k) .. ": unknown key"
    end
  end
  return ""
end

--- `v` checked against `spec` at `path`: the copy to answer and "", or
--- nil and the message for the first value that does not fit. The copy
--- is nil too for a missing value an optional spec admits.
local walk: function(v: any, spec: Node, path: string): any, string

local function walk_record(t: {any: any}, spec: Node, path: string): any, string
  if spec.strict == true then
    local unknown = unknown_key(t, spec, path)
    if unknown ~= "" then return nil, unknown end
  end
  local out: mut {string: any} = {}
  local fields, names = spec.fields, spec.names
  if fields == nil or names == nil then error("shape: a record spec holds no fields", 2) end
  for _, name in ipairs(names) do
    local got, failed = walk(rawget(t, name), fields[name], field_path(path, name))
    if failed ~= "" then return nil, failed end
    out[name] = got
  end
  return out, ""
end

local function walk_list(t: {any: any}, spec: Node, path: string): any, string
  -- A key the list refuses fails it where it stands, and no element is
  -- looked at; the elements go in index order.
  local members = Json.members(t, true)
  if members.layout == "mixed" or (members.layout == "object" and #members.keys > 0) then
    return nil, refusal(path, "list", least_refused(t, is_index))
  end
  local keys = members.keys
  local count = if #keys > 0 then #keys else members.extent end
  local out: mut {integer: any} = {}
  local after = 0
  local of = assert(spec.of)
  for i = 1, count do
    local k: integer = i
    if #keys > 0 then
      local key = keys[i]
      if key is integer then k = key end
    end
    -- A hole is a missing element: it fails a list whose elements are
    -- not optional, as a missing field fails a record, and each run of
    -- holes is one miss, at its first index.
    if not of.optional and k > after + 1 then
      return nil, mismatch(index_path(path, after + 1), of, nil)
    end
    after = k
    local got, failed = walk(rawget(t, k), of, index_path(path, k))
    if failed ~= "" then return nil, failed end
    out[k] = got
  end
  -- An element that is nil leaves a hole, and the list is as long as its highest element that is not.
  -- `out` is a new table of positions from 1 with no metatable, which `with_holes` takes.
  local list, why = Json.with_holes(out)
  return assert(list, why), ""
end

local function walk_map(t: {any: any}, spec: Node, path: string): any, string
  -- Every key is checked before any value, so a map with a key it
  -- refuses fails where it stands; the values go in key order, so the
  -- same map always reports the same miss.
  local members = Json.members(t)
  if members.layout ~= "object" then
    return nil, refusal(path, "map", least_refused(t, is_name))
  end
  local out: mut {string: any} = {}
  local of = assert(spec.of)
  for _, k in ipairs(members.keys) do
    if k is string then
      local got, failed = walk(rawget(t, k), of, field_path(path, k))
      if failed ~= "" then return nil, failed end
      out[k] = got
    end
  end
  return out, ""
end

walk = function(v: any, spec: Node, path: string): any, string
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
      return nil, ("%s: want integer, got %s"):format(path, shown(v))
    end
  elseif kind == "boolean" then
    if v is boolean then return v, "" end
  elseif kind == "any" then
    return v, ""
  elseif kind == "one_of" then
    local values = spec.values
    if values == nil then error("shape: a one_of spec holds no values", 2) end
    for _, want in ipairs(values) do
      if v == want then return v, "" end
    end
    if v is string or v is number or v is boolean then
      return nil, ("%s: want %s, got %s"):format(path, wanted(spec), shown(v))
    end
  elseif kind == "list" or kind == "map" or kind == "record" then
    if v is {any: any} then
      if kind == "list" then return walk_list(v, spec, path) end
      if Json.is_array(v) then return nil, mismatch(path, spec, v) end
      if kind == "map" then return walk_map(v, spec, path) end
      return walk_record(v, spec, path)
    end
  else
    error(("shape: a node of unknown kind %q"):format(tostring(kind)), 0)
  end
  return nil, mismatch(path, spec, v)
end

--- `value` checked against `spec`, as a new value holding what the spec
--- names, and "". nil and the first thing that did not fit, named by
--- its path, when it does not. The answer's type is the spec's, which
--- follows from how the spec was built.
--- Raises only when `spec` is not a Spec.
--- @param value any The decoded value
--- @param spec Spec<T> The shape it must have
--- @return T The value, typed
--- @return string "" or what did not fit
function Shape.into<T>(value: any, spec: Shape.Spec<T>): T?, string
  need_made(spec, "into's shape")
  local out, failed = walk(value, spec.node, "$")
  if failed ~= "" then return nil, failed end
  -- cast: the one from `any`, which walk has just built to the node, and the node is what makes a `Spec<T>`: every
  -- function that makes one gives it the `T` of the check it builds.
  return out as T, ""
end

--- The JSON `text` holds, checked against `spec` as `into` does, and
--- "". nil and a message when it does not: [`Json.decode`]'s own, naming
--- the line and column, when the text is not JSON, or `into`'s, naming
--- the path to the first value that does not fit, when it is JSON of
--- another shape. `opts` are [`Json.decode`]'s, forwarded as they are
--- (`json5`, `null_value`, `max_depth`). The answer's type is the spec's,
--- as `into`'s is. Text that is `null` decodes to
--- nothing (unless `opts.null_value` says otherwise), so a required
--- spec answers `$: missing` and an optional one
--- answers nil and "". Raises only when `spec` is not a Spec.
---
---     local SERVER <const> = Shape.record_of("Server")
---     local server, err = Shape.decode_into(text, SERVER.spec)
---     -- server.port == 8080; with "port": "x", err is
---     -- '$.port: want integer, got string'
--- @param text string The JSON text
--- @param spec Spec<T> The shape it must have
--- @param opts Json.DecodeOptions What [`Json.decode`] takes
--- @return T The value, typed
--- @return string "" or what was wrong with the text
function Shape.decode_into<T>(text: string, spec: Shape.Spec<T>, opts?: Json.DecodeOptions): T?, string
  need_made(spec, "decode_into's shape")
  local decoded, trouble = Json.decode(text, opts)
  if decoded == nil and trouble ~= "" then return nil, trouble end
  return Shape.into(decoded, spec)
end

--- A list whose every element has shape `of`: a table whose every key
--- is a positive integer, the empty table included, answered as `{A}`. An index
--- missing below the highest is a missing element, which `of` must be
--- ready for: a list of optional elements has holes, which an array
--- cannot hold, so `list(optional(x))` does not compile
--- (`array_of_optional`): [`sparse_list`] answers it as `{integer: A}`.
--- The answer is marked a JSON array, so an empty one still encodes as `[]`.
--- @param of Spec<A> Each element's shape
--- @return Spec<{A}> The list's shape
function Shape.list<A>(of: Shape.Spec<A>): Shape.Spec<{A}>
  need_made(of, "list's element")
  if of.node.optional then
    -- `any?` is `any` to the checker, so only the node tells that the element may be missing.
    error("shape: list's element is optional, which an array cannot hold: use `Shape.sparse_list`", 2)
  end
  return spec_of(raw_list(of.node))
end

--- A list whose elements may be missing or [`Json.null`], answered as a map from each index that is there:
--- `[1, null, 3]` against `sparse_list(Shape.optional(Shape.integer))` is `{[1] = 1, [3] = 3}`. The answer is marked
--- a JSON array of that length ([`Json.with_holes`]). `{integer: A}` is a map, so a read of an index is optional.
--- @param of Spec<A?> The shape of each element, an optional one
--- @return Spec<{integer: A}> The list's shape
function Shape.sparse_list<A>(of: Shape.Spec<A?>): Shape.Spec<{integer: A}>
  need_made(of, "sparse_list's element")
  if not of.node.optional then
    error("shape: sparse_list's element is not optional: wrap it in `Shape.optional`, or use `Shape.list`", 2)
  end
  return spec_of(raw_list(of.node))
end

--- A table whose every key is a string and every value has shape `of`,
--- the empty table included.
--- @param of Spec<A> Each value's shape
--- @return Spec<{string: A}> The map's shape
function Shape.map<A>(of: Shape.Spec<A>): Shape.Spec<{string: A}>
  need_made(of, "map's value")
  return spec_of(raw_map(of.node))
end

--- The shape `of`, which a missing value, or [`Json.null`], also
--- satisfies; either reads back as nil.
--- @param of Spec<A> The shape a present value must have
--- @return Spec<A?> The optional shape
function Shape.optional<A>(of: Shape.Spec<A>): Shape.Spec<A?>
  need_made(of, "optional's shape")
  return spec_of(raw_optional(of.node))
end

--- Exactly one of `values`, compared with `==`: the members of an
--- enumeration, such as `Shape.one_of("debug", "info", "warn")`.
--- Raises when given none.
--- @param ... string The values admitted
--- @return Spec<string> The enumeration's shape
function Shape.one_of(...: string): Shape.Spec<string>
  return spec_of(raw_one_of(...))
end

--- `failure` of a [`Typed`], led by the record's name; "" stays "".
local function named<T>(self: Shape.Typed<T>, failure: string): string
  if failure == "" then return "" end
  return self.name .. ": " .. failure
end

local function typed_into<T>(self: Shape.Typed<T>, value: any): T?, string
  local out, failed = Shape.into(value, self.spec)
  if failed ~= "" then return nil, named(self, failed) end
  return out, ""
end

local function typed_decode_into<T>(self: Shape.Typed<T>, text: string,
                                    opts?: Json.DecodeOptions): T?, string
  local decoded, trouble = Json.decode(text, opts)
  if decoded == nil and trouble ~= "" then return nil, trouble end
  return typed_into(self, decoded)
end

--- `node` and every record below it refusing a key it does not name.
local function strict_node(node: Node): Node
  local fields: {string: Node}? = nil
  if node.fields ~= nil then
    local own: mut {string: Node} = {}
    for name, field in pairs(node.fields) do
      own[name] = strict_node(field)
    end
    fields = own
  end
  local of = node.of
  return {
    kind = node.kind, optional = node.optional, of = if of ~= nil then strict_node(of) else nil end, fields = fields,
    names = node.names, strict = if node.kind == "record" then true else node.strict end, values = node.values,
  }
end

local function typed_strict<T>(self: Shape.Typed<T>): Shape.Typed<T>
  local held = self.stricter
  if held ~= nil then
    return held
  end
  need_made(self.spec, "strict's record")
  local strict: Shape.Typed<T> = {
    name = self.name, spec = spec_of(strict_node(self.spec.node)), into = typed_into, decode_into = typed_decode_into,
    strict = typed_strict,
  }
  -- A strict record made strict again is itself; kept, so that a call per request builds nothing.
  strict.stricter = strict
  self.stricter = strict
  return strict
end

--- The shape of the Teal record `name`, read off its declaration by the
--- build and answered with the record's type, so a record and its shape
--- are one declaration: `into` and [`decode_into`] answer a `T`, and no
--- annotation can say another.
---
---     local record Server
---       host: string
---       port: integer | nil
---     end
---     local SERVER <const> = Shape.record_of("Server")
---     local server, err = SERVER:into(decoded)
---
--- `name` is a string literal: `Record` for a record declared above the
--- call, in a block the call is in (a test's, or an example's, too), or
--- `module.Record` for one declared inside the module `module`'s record,
--- which the calling module requires at its top level. The spec is what [`Raw.record`]
--- builds for the record's fields: strings, integers, numbers, booleans
--- and `any`; arrays and string-keyed maps of those; an enum, as
--- [`one_of`] with its values in byte order; records of those; and a
--- field typed `T | nil`, as `optional`. A function, a union of more
--- than one type, a generic, an interface and a record that holds itself
--- are refused when the module is built, naming the field. A field of type
--- `any` is read as `optional(any)`, since `any` holds nil: a payload that
--- lacks its key is accepted and the field is nil, where a field of any other
--- type must be there. To refuse a missing key, test the field after `into`.
--- The record keeps its fields only: a key the payload grew is dropped, as
--- `raw.record` does, and `spec` is a [`Spec`] to put inside any other.
---
--- The build, not the program, reads the declaration: it splices the
--- spec and the record's type in after `name`, which are `built` and
--- `_witness` (write neither). It finds a call written as
--- `Shape.record_of("Name")` and no other (not through another name, not
--- with a computed name), and a script run with `--standalone` has no
--- build: the checker answers a read of the result's fields with `T
--- (unresolved generic)`, and a call that gets that far raises here. Such a script runs as
--- `cosmic script.tl`, which builds the tree around it.
--- @param name string The record, as a string literal
--- @param built Node What the build read off the record
--- @param _witness function(): T A function the build writes to name `T`, which it never calls
--- @return Typed<T> The spec and the record it checks
function Shape.record_of<T>(name: string, built?: Node, _witness?: function(): T): Shape.Typed<T>
  if built == nil then
    error(("shape: record_of(%q) was not resolved: the build reads a record's declaration " ..
      "from a call written as Shape.record_of(\"Name\") in a module it compiles, so an " ..
      "aliased or computed call, a chunk loaded by hand, and a script run with " ..
      "--standalone have no spec for it; call Shape.record_of(\"Name\") directly under a " ..
      "build, or run the script as `cosmic script.tl`"):format(name), 2)
  end
  need_node(built, "record_of's built")
  if built.kind ~= "record" then
    error(("shape: record_of(%q) was given a %s spec, not a record's"):format(name, built.kind), 2)
  end
  local typed: Shape.Typed<T> = {
    name = name, spec = spec_of(built), into = typed_into, decode_into = typed_decode_into, strict = typed_strict,
  }
  return typed
end

Shape.string = spec_of(STRING)
Shape.number = spec_of(NUMBER)
Shape.integer = spec_of(INTEGER)
Shape.boolean = spec_of(BOOLEAN)
Shape.any = spec_of(ANY)

--- `node` checked against, as `into` does, answering the checked copy as it is.
local function check(value: any, node: Node): any, string
  need_node(node, "check's node")
  return walk(value, node, "$")
end

--- `node`, a record or a map, as a spec of `{string: any}`.
local function table_of(node: Node): Shape.Spec<{string: any}>
  need_node(node, "table_of's node")
  if node.kind ~= "record" and node.kind ~= "map" then
    error(("shape: table_of takes a record or a map, not a %s: another node does not answer a table of names"):format(
      node.kind), 2)
  end
  return spec_of(node)
end

Shape.raw = {
  string = STRING, number = NUMBER, integer = INTEGER, boolean = BOOLEAN, any = ANY,
  list = raw_list, map = raw_map, optional = raw_optional, one_of = raw_one_of,
  record = function(fields: {string: Node}): Node return record_node(fields, false, "record") end,
  strict_record = function(fields: {string: Node}): Node
    return record_node(fields, true, "strict_record")
  end,
  check = check, table_of = table_of,
}

return Shape
