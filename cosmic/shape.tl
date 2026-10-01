--- Checks a decoded value against a declared shape, and hands it back as
--- a typed record. What `cosmic.json` decodes, or a loaded chunk returns,
--- is `any`, and reading a field from it costs a cast that nothing checks.
--- `into` walks the value against a [`Spec`] built from the functions
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
--- [`decode_into`] is [`Json.decode`] and `into` in one call, for text that
--- is not used as anything but the record:
---
---     local server, err: Server | nil, string = Shape.decode_into(text, SERVER)
---
--- The result's type comes from the caller's annotation, not from the
--- spec, and nothing checks that the two agree: a field the record has
--- and the spec lacks is simply never set. Teal infers the type in a
--- declaration with its error, as above, in a `return` from a function
--- declared `T | nil, string`, and in `local s: Server = must(...)`. A
--- bare `local s = must(Shape.into(...))` fails to compile with "cannot
--- infer declaration type".
---
--- [`record_of`] makes the record and its shape one declaration: the
--- spec is read off the record's declaration where the module is built,
--- and `into` answers the record's own type, so a field added to the
--- record is checked from then on and no annotation can disagree:
---
---     local record Server
---       host: string
---       port: integer | nil
---     end
---     local SERVER <const> = Shape.record_of("Server")
---     local server, err = SERVER:into(decoded)
---
--- The rules, fixed here:
---
--- - The answer is a copy. A record keeps only the fields its spec
---   names, so a key the payload grew is dropped rather than refused
---   ([`strict_record`] refuses it instead), and the value handed in is
---   never written to.
--- - JSON is the decoder in mind. A missing key and [`Json.null`], which
---   `Json.decode(text, { null_value = Json.null })` puts where the text
---   says `null`, are the same thing: `optional` admits either and
---   answers nil. A list answers a JSON array ([`Json.is_array`]), so an
---   empty one encodes as `[]`, and a map or record refuses one.
--- - Nothing is converted, with one exception: `integer` takes a float
---   with no fraction, like the `8080.0` another language's encoder
---   writes, and answers the integer. `number` refuses `"1"`.
--- - A failure names the first value that does not fit, by its path
---   from the root as `cosmic.json` names one, `$.rows[2].id`, with list
---   indices counted from 1: `$.rows[2].id: expected string, got
---   integer`. A record's fields and a map's keys are checked in byte
---   order, and a list's elements in index order, so the same value
---   always reports the same failure. Only the first is answered: a
---   config file whose author wants every mistake sees them one at a
---   time, re-running after each fix.
--- - `into` never raises on a value, whatever it holds. A spec that was
---   not built by these functions is a programming error, and raises.

local Json = require("cosmic.json")

local record Shape
  --- Which check a [`Spec`] is.
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

  --- One node of a shape. Build it with the functions and values of
  --- this module; its fields are how `into` reads it, not an interface.
  record Spec
    --- Which check this node is.
    kind: Shape.Kind
    --- Whether a missing value satisfies it.
    optional: boolean
    --- The element's spec, for "list" and "map".
    of: Spec
    --- The fields' specs, for "record".
    fields: {string: Spec}
    --- The fields' names in byte order, for "record".
    names: {string}
    --- Whether a key `fields` does not name is refused, for "record".
    strict: boolean
    --- The values admitted, for "one_of".
    values: {string | number | boolean}
  end

  --- A [`Spec`] and the record `T` it was built from, which
  --- [`record_of`] answers. Its methods answer a `T`, so no annotation
  --- stands between the spec and the type of what it checks.
  record Typed<T>
    --- The record's shape: what `record` builds for the fields it
    --- declares.
    spec: Spec
    --- [`into`] over `spec`, answering a `T`.
    into: function(self: Typed<T>, value: any): T | nil, string
    --- [`decode_into`] over `spec`, answering a `T`.
    decode_into: function(self: Typed<T>, text: string, opts?: Json.DecodeOptions): T | nil, string
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

--- Each [`Shape.Kind`] by its spelling. Teal's `is` on an enum tests
--- only for a string, so [`need_spec`] asks this table instead. Nothing
--- ties it to the enum: the tests build a spec of every kind, so a kind
--- left out fails there.
local KINDS <const>: {string: Shape.Kind} = {
  string = "string", number = "number", integer = "integer", boolean = "boolean",
  any = "any", list = "list", map = "map", record = "record", one_of = "one_of",
}

local function leaf(kind: Shape.Kind): Spec
  return { kind = kind, optional = false }
end

Shape.string = leaf("string")
Shape.number = leaf("number")
Shape.integer = leaf("integer")
Shape.boolean = leaf("boolean")
Shape.any = leaf("any")

--- Raises unless `spec` is one these functions built: a spec is part of
--- the program, so a wrong one is the caller's bug, not the data's.
local function need_spec(spec: any, what: string)
  local kind: any = nil
  if spec is {any: any} then kind = spec["kind"] end
  if not (kind is string) or KINDS[kind] == nil then
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

--- A record's spec over a copy of `fields`, its names in byte order.
local function record_spec(fields: {string: Spec}, strict: boolean, what: string): Spec
  local own: {string: Spec} = {}
  local names: {string} = {}
  for name, spec in pairs(fields) do
    need_spec(spec, ("%s's field %q"):format(what, name))
    own[name] = spec
    names[#names + 1] = name
  end
  table.sort(names)
  return { kind = "record", optional = false, fields = own, names = names, strict = strict }
end

--- A table with the named fields, each of its own shape. Keys it does
--- not name are ignored, and left out of the answer; [`strict_record`]
--- refuses them.
--- @param fields {string: Spec} Each field's shape, by its name
--- @return Spec The record's shape
function Shape.record(fields: {string: Spec}): Spec
  return record_spec(fields, false, "record")
end

--- A record that refuses every key it does not name, for a config file
--- where a misspelled key should fail rather than vanish:
--- `{"prot": 8080}` against `strict_record({ port = Shape.integer })`
--- fails with `$.prot: unknown key`. The keys are checked before the
--- fields, so the misspelling is named rather than the field it was
--- meant to be, and the first unknown one in byte order is the one
--- reported. A key is unknown whatever its value, [`Json.null`] included:
--- `"prot": null` is still a misspelling. A key that is not a string is
--- refused as a map refuses one, `$: expected record, got the integer
--- key 1`. Otherwise it is `record`: a named field that is `optional`
--- may be missing or [`Json.null`], and the answer is a copy.
--- @param fields {string: Spec} Each field's shape, by its name
--- @return Spec The record's shape
function Shape.strict_record(fields: {string: Spec}): Spec
  return record_spec(fields, true, "strict_record")
end

--- The shape `of`, which a missing value, or [`Json.null`], also
--- satisfies; either reads back as nil.
--- @param of Spec The shape a present value must have
--- @return Spec The optional shape
function Shape.optional(of: Spec): Spec
  need_spec(of, "optional's shape")
  return {
    kind = of.kind, optional = true, of = of.of, fields = of.fields,
    names = of.names, strict = of.strict, values = of.values,
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

local quoted = Json.quote

--- `path` extended by the field `name`, as a message spells where a miss
--- is: `$.user` for a word, `$["a key"]` for any other key.
local function field_path(path: string, name: string): string
  if name:match("^[%a_][%w_]*$") then
    return path .. "." .. name
  end
  return path .. "[" .. quoted(name) .. "]"
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
  end
  return spec.kind
end

--- `path`'s message for a value of the wrong kind.
local function mismatch(path: string, spec: Spec, v: any): string
  return ("%s: expected %s, got %s"):format(path, wanted(spec), kind_of(v))
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
  return ("%s: expected %s, got %s"):format(path, kind, key_named(key))
end

--- What a strict record `spec` refuses in `t`, before any field is
--- looked at: a key that is not a string, named where the record
--- stands, or else the first string key it does not name, in byte
--- order, named where that key is (`$.prot: unknown key`). A key that
--- is not a string takes precedence, so a strict record fails where it
--- stands or at its keys, never at a field as well. Answers the message,
--- or "".
local function unknown_key(t: {any: any}, spec: Spec, path: string): string
  local members = Json.members(t)
  if members.layout ~= "object" then
    local refused = least_refused(t, is_name)
    if refused ~= nil then return refusal(path, "record", refused) end
    return ""
  end
  for _, k in ipairs(members.keys) do
    if k is string and spec.fields[k] == nil then
      return field_path(path, k) .. ": unknown key"
    end
  end
  return ""
end

--- `v` checked against `spec` at `path`: the copy to answer and "", or
--- nil and the message for the first value that does not fit. The copy
--- is nil too for a missing value an optional spec admits.
local walk: function(v: any, spec: Spec, path: string): any, string

local function walk_record(t: {any: any}, spec: Spec, path: string): any, string
  if spec.strict then
    local unknown = unknown_key(t, spec, path)
    if unknown ~= "" then return nil, unknown end
  end
  local out: {string: any} = {}
  for _, name in ipairs(spec.names) do
    local got, failed = walk(rawget(t, name), spec.fields[name], field_path(path, name))
    if failed ~= "" then return nil, failed end
    out[name] = got
  end
  return out, ""
end

local function walk_list(t: {any: any}, spec: Spec, path: string): any, string
  -- A key the list refuses fails it where it stands, and no element is
  -- looked at; the elements go in index order.
  local members = Json.members(t, true)
  if members.layout == "mixed" or (members.layout == "object" and #members.keys > 0) then
    return nil, refusal(path, "list", least_refused(t, is_index))
  end
  local keys = members.keys
  local count = #keys > 0 and #keys or members.extent
  local out: {any} = {}
  local after = 0
  for i = 1, count do
    local k: integer = i
    if #keys > 0 then
      local key = keys[i]
      if key is integer then k = key end
    end
    -- A hole is a missing element: it fails a list whose elements are
    -- not optional, as a missing field fails a record, and each run of
    -- holes is one miss, at its first index.
    if not spec.of.optional and k > after + 1 then
      return nil, mismatch(("%s[%d]"):format(path, after + 1), spec.of, nil)
    end
    after = k
    local got, failed = walk(rawget(t, k), spec.of, ("%s[%d]"):format(path, k))
    if failed ~= "" then return nil, failed end
    out[k] = got
  end
  return Json.array(out), ""
end

local function walk_map(t: {any: any}, spec: Spec, path: string): any, string
  -- Every key is checked before any value, so a map with a key it
  -- refuses fails where it stands; the values go in key order, so the
  -- same map always reports the same miss.
  local members = Json.members(t)
  if members.layout ~= "object" then
    return nil, refusal(path, "map", least_refused(t, is_name))
  end
  local out: {string: any} = {}
  for _, k in ipairs(members.keys) do
    if k is string then
      local got, failed = walk(rawget(t, k), spec.of, field_path(path, k))
      if failed ~= "" then return nil, failed end
      out[k] = got
    end
  end
  return out, ""
end

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
  elseif kind == "list" or kind == "map" or kind == "record" then
    if v is {any: any} then
      if kind == "list" then return walk_list(v, spec, path) end
      if Json.is_array(v) then return nil, mismatch(path, spec, v) end
      if kind == "map" then return walk_map(v, spec, path) end
      return walk_record(v, spec, path)
    end
  else
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
function Shape.into<T>(value: any, spec: Spec): T | nil, string
  need_spec(spec, "into's shape")
  local out, failed = walk(value, spec, "$")
  if failed ~= "" then return nil, failed end
  -- cast: the one from `any`, which walk has just built to `spec`
  return out as T, ""
end

--- The JSON `text` holds, checked against `spec` as `into` does, and
--- "". nil and a message when it does not: [`Json.decode`]'s own, naming
--- the line and column, when the text is not JSON, or `into`'s, naming
--- the `$.path` of the first value that does not fit, when it is JSON of
--- another shape. `opts` are [`Json.decode`]'s, forwarded as they are
--- (`json5`, `null_value`, `max_depth`). The answer's type is the
--- caller's annotation, as `into`'s is. Text that is `null` decodes to
--- nothing (unless `opts.null_value` says otherwise), so a required
--- spec answers `$: expected record, got nothing` and an optional one
--- answers nil and "". Raises only when `spec` is not a Spec.
---
---     local text = '{"host": "localhost", "port": 8080}'
---     local server, err: Server | nil, string = Shape.decode_into(text, SERVER)
---     -- server.port == 8080; with "port": "x", err is
---     -- "$.port: expected integer, got string"
--- @param text string The JSON text
--- @param spec Spec The shape it must have
--- @param opts Json.DecodeOptions What [`Json.decode`] takes
--- @return T The value, typed
--- @return string "" or what was wrong with the text
function Shape.decode_into<T>(text: string, spec: Spec, opts?: Json.DecodeOptions): T | nil, string
  need_spec(spec, "decode_into's shape")
  local decoded, trouble = Json.decode(text, opts)
  if decoded == nil and trouble ~= "" then return nil, trouble end
  local out, failed: T | nil, string = Shape.into(decoded, spec)
  if out == nil then return nil, failed end
  return out, ""
end

local function typed_into<T>(self: Shape.Typed<T>, value: any): T | nil, string
  return Shape.into(value, self.spec)
end

local function typed_decode_into<T>(self: Shape.Typed<T>, text: string,
                                    opts?: Json.DecodeOptions): T | nil, string
  return Shape.decode_into(text, self.spec, opts)
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
--- which the calling module requires at its top level. The spec is what `record`
--- builds for the record's fields: strings, integers, numbers, booleans
--- and `any`; arrays and string-keyed maps of those; an enum, as
--- [`one_of`] with its values in byte order; records of those; and a
--- field typed `T | nil`, as `optional`. A function, a union of more
--- than one type, a generic, an interface and a record that holds itself
--- are refused when the module is built, naming the field. The record
--- keeps its fields only: a key the payload grew is dropped, as `record`
--- does, and `spec` is a [`Spec`] to put inside any other.
---
--- The build, not the program, reads the declaration: it splices the
--- spec and the record's type in after `name`, which are `built` and
--- `_witness` (write neither). It finds a call written as
--- `Shape.record_of("Name")` and no other (not through another name, not
--- with a computed name), and a script run with `--standalone` has no
--- build: the checker answers a read of the result's fields with `T
--- (unresolved generic)`, and a call that gets that far raises here. Such a script writes its
--- spec with `record`, or runs as `cosmic script.tl`, which builds the
--- tree around it.
--- @param name string The record, as a string literal
--- @param built Spec What the build read off the record
--- @param _witness function(): T A function the build writes to name `T`, which it never calls
--- @return Typed<T> The spec and the record it checks
function Shape.record_of<T>(name: string, built?: Spec, _witness?: function(): T): Shape.Typed<T>
  -- TODO: a strict form, refusing a key the record does not name, once a
  -- config record wants one: a `Typed:strict()` over a copy of `spec`.
  if built == nil then
    error(("shape: record_of(%q) was not resolved: the build reads a record's declaration " ..
      "from a call written as Shape.record_of(\"Name\") in a module it compiles, so an " ..
      "aliased or computed call, a chunk loaded by hand, and a script run with " ..
      "--standalone have no spec for it; call Shape.record_of(\"Name\") directly under a " ..
      "build, or write the spec with Shape.record"):format(name), 2)
  end
  need_spec(built, "record_of's built")
  if built.kind ~= "record" then
    error(("shape: record_of(%q) was given a %s spec, not a record's"):format(name, built.kind), 2)
  end
  local typed: Shape.Typed<T> = {
    spec = built, into = typed_into, decode_into = typed_decode_into,
  }
  return typed
end

return Shape
