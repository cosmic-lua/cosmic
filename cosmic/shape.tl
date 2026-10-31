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
--- A record's check is generated, not walked: the build writes, for each record
--- [`record_of`] names, a Teal function that builds the record field by field from
--- the checks of its fields' types, so the checker types it as any other code and
--- a hand-written one must answer a `T` or fail to compile.
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
--- - `into` never raises on a value, whatever it holds.

local FieldPath = require("cosmic.internal.field_path")
local Json = require("cosmic.json")

local record Shape
  --- A table of anything, which [`Build.object`] answers for the generated code to read fields from.
  type Table = {any: any}

  --- Which check a [`Node`] describes.
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

  --- What the build read of a record's declaration, for what needs its structure: [`Input.bind_strings`] binds the
  --- fields of a record from flat strings and [`Typed.strict`] describes a strict one. It checks nothing: a [`Spec`]'s
  --- `check` does, and runs over whatever is bound last.
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

  --- A shape, and the type `T` of what it checks: a value that passes it is a `T`. It is a check, and nothing else:
  --- `check` answers a `T` or why the value is not one, so a spec written by hand is a function the checker holds to its
  --- type, and `T` is true of whatever it passes. The functions below build one from another's check, so `T` follows
  --- from how it was built, and [`into`] answers it with no annotation to disagree. A record's spec is made by
  --- [`Shape.record_of`], from the record's own declaration.
  record Spec<T>
    --- `value` checked, as a `T` and "", or nil and what did not fit, named by its path under `path`. A missing value
    --- (nil or [`Json.null`]) is answered nil and "" by an optional spec and `path: missing` by any other.
    check: function(value: any, path: string): T?, string
    --- The node of a record's spec, for what reads its structure. It only advises: what those answer is run through
    --- `check` last, so a `describe` that lies cannot make a value of the wrong type.
    describe?: function(): Node
  end

  --- A [`Spec`] and the record `T` it was built from, which [`record_of`] answers. Its methods answer a `T`.
  record Typed<T>
    --- The record's shape: what [`record_of`] builds for the fields it declares.
    spec: Spec<T>
    --- The record's name, as [`record_of`] was given it. A failure of
    --- `into` or [`decode_into`] starts with it: `Envelope: $.items[3].name: missing`.
    name: string
    --- The record's check, by whether it refuses a key it does not name; what the build generated for it.
    make: function(strict: boolean): Spec<T>
    --- What the build read of the record's fields.
    node: Node
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

  --- What the code the build generates for [`record_of`] calls. Nothing else has a use for them.
  record Build
    --- `value` as the table of a record of `names`, or nil and why it is none: a missing value, a value that is no
    --- table or is a JSON array, and, where `strict`, a key the record does not name.
    object: function(value: any, path: string, names: {string}, strict: boolean): Shape.Table?, string
    --- The field `name` of the table `object` answered.
    get: function(t: Shape.Table, name: string): any
    --- `path` extended by the field `name`.
    step: function(path: string, name: string): string
    --- `why`, or `path: missing` where a required field's check answered nothing and no reason.
    failed: function(why: string, path: string): string
    --- The failure of an enumeration, as [`one_of`] words it.
    not_one_of: function(path: string, value: any, ...: string): string
  end

  --- What the generated code calls.
  mut build: Build

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

--- `path`'s message for a value that is not `want`.
local function mismatch(path: string, want: string, v: any): string
  if v == nil then return path .. ": missing" end
  return ("%s: want %s, got %s"):format(path, want, kind_of(v))
end

--- What `values` ask for, for a message.
local function wanted(values: {string}): string
  local parts: mut {string} = {}
  for i, v in ipairs(values) do parts[i] = shown(v) end
  return "one of " .. table.concat(parts, ", ")
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

--- What a strict record of `names` refuses in `t`, before any field is looked at: a key that is not a string, named
--- where the record stands, or else the first string key it does not name, in byte order, named where that key is
--- (`$.prot: unknown key`). A key that is not a string takes precedence, so a strict record fails where it stands or at
--- its keys, never at a field as well. Answers the message, or "".
local function unknown_key(t: {any: any}, names: {string}, path: string): string
  local members = Json.members(t)
  if members.layout ~= "object" then
    local refused = least_refused(t, is_name)
    if refused ~= nil then return refusal(path, "record", refused) end
    return ""
  end
  local known: mut {string: boolean} = {}
  for _, name in ipairs(names) do known[name] = true end
  for _, k in ipairs(members.keys) do
    if k is string and known[k] ~= true then
      return field_path(path, k) .. ": unknown key"
    end
  end
  return ""
end

--- `v` as a table of anything, or nil where it is not a table.
local function as_table(v: any): Shape.Table?
  if v is Shape.Table then return v end
  return nil
end

--- `v` as the `T` the caller says. The one cast of the module, for [`Shape.list`], which marks a dense array of what its
--- element spec checked (the mark is a call on a map, [`Json.with_holes`], and the array it marks is the same table).
local function trust<T>(v: any): T
  return v as T
end

--- `value` checked against `spec`, as a new value holding what the spec
--- names, and "". nil and the first thing that did not fit, named by
--- its path, when it does not. The answer's type is the spec's, which
--- follows from how the spec was built.
--- @param value any The decoded value
--- @param spec Spec<T> The shape it must have
--- @return T The value, typed
--- @return string "" or what did not fit
function Shape.into<T>(value: any, spec: Shape.Spec<T>): T?, string
  local out, failed = spec.check(value, "$")
  if failed ~= "" then return nil, failed end
  return out, ""
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
--- answers nil and "".
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
  local decoded, trouble = Json.decode(text, opts)
  if decoded == nil and trouble ~= "" then return nil, trouble end
  return Shape.into(decoded, spec)
end

--- Whether `v` is missing: nothing, or [`Json.null`].
local function absent(v: any): boolean
  return v == nil or rawequal(v, Json.null)
end

--- The elements of the list `value` at `path`, each checked by `of`, in index order: a map from each index there is,
--- and the first missing index below the highest (a hole) when `sparse` is false. Or nil and why.
local function list_of<A>(value: any, path: string, check: function(value: any, path: string): A?, string,
                          sparse: boolean): {integer: A}?, string
  if absent(value) then return nil, path .. ": missing" end
  local t = as_table(value)
  if t == nil then return nil, mismatch(path, "list", value) end
  -- A key the list refuses fails it where it stands, and no element is looked at.
  local members = Json.members(t, true)
  if members.layout == "mixed" or (members.layout == "object" and #members.keys > 0) then
    return nil, refusal(path, "list", least_refused(t, is_index))
  end
  local keys = members.keys
  local count = if #keys > 0 then #keys else members.extent end
  local out: mut {integer: A} = {}
  local after = 0
  for i = 1, count do
    local k: integer = i
    if #keys > 0 then
      local key = keys[i]
      if key is integer then k = key end
    end
    -- A hole is a missing element, and each run of holes is one miss, at its first index.
    if not sparse and k > after + 1 then return nil, index_path(path, after + 1) .. ": missing" end
    after = k
    local got, failed = check(rawget(t, k), index_path(path, k))
    if failed ~= "" then return nil, failed end
    if got ~= nil then
      out[k] = got
    elseif not sparse then
      return nil, index_path(path, k) .. ": missing"
    end
  end
  return out, ""
end

--- A list whose every element has shape `of`: a table whose every key
--- is a positive integer, the empty table included, answered as `{A}`. An index
--- missing below the highest is a missing element, and so is one `of` answers nothing for: a list of optional
--- elements has holes, which an array cannot hold, so `list(optional(x))` does not compile
--- (`array_of_optional`) and fails at run time where an element is missing. [`sparse_list`] answers it as `{integer: A}`.
--- The answer is marked a JSON array, so an empty one still encodes as `[]`.
--- @param of Spec<A> Each element's shape
--- @return Spec<{A}> The list's shape
function Shape.list<A>(of: Shape.Spec<A>): Shape.Spec<{A}>
  return {
    check = function(value: any, path: string): {A}?, string
      local items, why = list_of(value, path, of.check, false)
      if items == nil then return nil, why end
      -- `items` holds every index from 1 to its length, so it is an array: marked as one, it is answered as `{A}`.
      local marked, trouble = Json.with_holes(items)
      assert(marked, trouble)
      return trust(marked), ""
    end,
  }
end

--- A list whose elements may be missing or [`Json.null`], answered as a map from each index that is there:
--- `[1, null, 3]` against `sparse_list(Shape.optional(Shape.integer))` is `{[1] = 1, [3] = 3}`. The answer is marked
--- a JSON array of that length ([`Json.with_holes`]). `{integer: A}` is a map, so a read of an index is optional.
--- @param of Spec<A?> The shape of each element, an optional one
--- @return Spec<{integer: A}> The list's shape
function Shape.sparse_list<A>(of: Shape.Spec<A?>): Shape.Spec<{integer: A}>
  return {
    check = function(value: any, path: string): {integer: A}?, string
      local items, why = list_of(value, path, of.check, true)
      if items == nil then return nil, why end
      local marked, trouble = Json.with_holes(items)
      assert(marked, trouble)
      return marked, ""
    end,
  }
end

--- A table whose every key is a string and every value has shape `of`,
--- the empty table included.
--- @param of Spec<A> Each value's shape
--- @return Spec<{string: A}> The map's shape
function Shape.map<A>(of: Shape.Spec<A>): Shape.Spec<{string: A}>
  return {
    check = function(value: any, path: string): {string: A}?, string
      if absent(value) then return nil, path .. ": missing" end
      local t = as_table(value)
      if t == nil or Json.is_array(t) then return nil, mismatch(path, "map", value) end
      -- Every key is checked before any value, so a map with a key it refuses fails where it stands; the values go in
      -- key order, so the same map always reports the same miss.
      local members = Json.members(t)
      if members.layout ~= "object" then
        return nil, refusal(path, "map", least_refused(t, is_name))
      end
      local out: mut {string: A} = {}
      for _, k in ipairs(members.keys) do
        if k is string then
          local got, failed = of.check(rawget(t, k), field_path(path, k))
          if failed ~= "" then return nil, failed end
          if got ~= nil then out[k] = got end
        end
      end
      return out, ""
    end,
  }
end

--- The shape `of`, which a missing value, or [`Json.null`], also
--- satisfies; either reads back as nil.
--- @param of Spec<A> The shape a present value must have
--- @return Spec<A?> The optional shape
function Shape.optional<A>(of: Shape.Spec<A>): Shape.Spec<A?>
  return {
    check = function(value: any, path: string): A?, string
      if absent(value) then return nil, "" end
      return of.check(value, path)
    end,
  }
end

--- Exactly one of `values`, compared with `==`: the members of an
--- enumeration, such as `Shape.one_of("debug", "info", "warn")`.
--- Raises when given none.
--- @param ... string The values admitted
--- @return Spec<string> The enumeration's shape
function Shape.one_of(...: string): Shape.Spec<string>
  local values: {string} = { ... }
  if #values == 0 or #values ~= select("#", ...) then
    error("shape: one_of needs at least one value, and no nil", 2)
  end
  local want = wanted(values)
  return {
    check = function(value: any, path: string): string?, string
      if absent(value) then return nil, path .. ": missing" end
      for _, allowed in ipairs(values) do
        if value == allowed then return allowed, "" end
      end
      if value is string or value is number or value is boolean then
        return nil, ("%s: want %s, got %s"):format(path, want, shown(value))
      end
      return nil, mismatch(path, want, value)
    end,
  }
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
local function strict_node(node: Shape.Node): Shape.Node
  local fields: {string: Shape.Node}? = nil
  if node.fields ~= nil then
    local own: mut {string: Shape.Node} = {}
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

--- The record's spec for `strict`, over what the build generated, with the node that describes it.
local function spec_for<T>(make: function(strict: boolean): Shape.Spec<T>, node: Shape.Node, strict: boolean): Shape.Spec<T>
  local made = make(strict)
  return { check = made.check, describe = function(): Shape.Node return node end }
end

local function typed_strict<T>(self: Shape.Typed<T>): Shape.Typed<T>
  local held = self.stricter
  if held ~= nil then
    return held
  end
  local node = strict_node(self.node)
  local strict: Shape.Typed<T> = {
    name = self.name, spec = spec_for(self.make, node, true), make = self.make, node = node, into = typed_into,
    decode_into = typed_decode_into, strict = typed_strict,
  }
  -- A strict record made strict again is itself; kept, so that a call per request builds nothing.
  strict.stricter = strict
  self.stricter = strict
  return strict
end

--- The check of the Teal record `name`, written by the build off the record's own declaration and answered with the
--- record's type, so a record and its shape are one declaration: `into` and [`decode_into`] answer a `T`, and no
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
--- which the calling module requires at its top level. A record may hold
--- strings, integers, numbers, booleans and `any`; arrays and
--- string-keyed maps of those; an enum; records of those; and a field typed
--- `T | nil`, which may be missing. A function, a union of more
--- than one type, a generic, an interface and a record that holds itself
--- are refused when the module is built, naming the field. A field of type
--- `any` may be missing, since `any` holds nil: a payload that
--- lacks its key is accepted and the field is nil, where a field of any other
--- type must be there. To refuse a missing key, test the field after `into`.
--- The record keeps its fields only: a key the payload grew is dropped.
---
--- The build, not the program, writes the check: it puts after `name` a function
--- that builds the record and the node that describes its fields, which are `make` and
--- `node` (write neither). Anything a program passes there is a function the
--- checker types, so it answers a `T` or does not compile; a call the build did
--- not complete (through another name, with a computed name, in a chunk loaded
--- by hand, or in a script run with `--standalone`, which has no build) raises
--- here. Such a script runs as `cosmic script.tl`, which builds the tree around it.
--- @param name string The record, as a string literal
--- @param make function(strict: boolean): Spec<T> What the build wrote
--- @param node Node What the build read off the record
--- @return Typed<T> The spec and the record it checks
function Shape.record_of<T>(name: string, make?: function(strict: boolean): Shape.Spec<T>, node?: Shape.Node):
    Shape.Typed<T>
  if make == nil or node == nil then
    error(("shape: record_of(%q) was not resolved: the build writes a record's check from a call written as " ..
      "Shape.record_of(\"Name\") in a module it compiles, so an aliased or computed call, a chunk loaded by " ..
      "hand, and a script run with --standalone have none for it; call Shape.record_of(\"Name\") directly " ..
      "under a build, or run the script as `cosmic script.tl`"):format(name), 2)
  end
  return {
    name = name, spec = spec_for(make, node, false), make = make, node = node, into = typed_into,
    decode_into = typed_decode_into, strict = typed_strict,
  }
end

Shape.build = {
  object = function(value: any, path: string, names: {string}, strict: boolean): Shape.Table?, string
    local t = as_table(value)
    if t == nil or Json.is_array(t) or absent(value) then
      return nil, mismatch(path, "record", value)
    end
    if strict then
      local unknown = unknown_key(t, names, path)
      if unknown ~= "" then return nil, unknown end
    end
    return t, ""
  end,
  get = function(t: Shape.Table, name: string): any return rawget(t, name) end,
  step = field_path,
  failed = function(why: string, path: string): string
    if why ~= "" then return why end
    return path .. ": missing"
  end,
  not_one_of = function(path: string, value: any, ...: string): string
    local allowed: {string} = { ... }
    if value is string or value is number or value is boolean then
      return ("%s: want %s, got %s"):format(path, wanted(allowed), shown(value))
    end
    return mismatch(path, wanted(allowed), value)
  end,
}

Shape.string = {
  check = function(value: any, path: string): string?, string
    if value is string then return value, "" end
    return nil, mismatch(path, "string", if absent(value) then nil else value end)
  end,
}
Shape.number = {
  check = function(value: any, path: string): number?, string
    if value is number then return value, "" end
    return nil, mismatch(path, "number", if absent(value) then nil else value end)
  end,
}
Shape.integer = {
  check = function(value: any, path: string): integer?, string
    if value is integer then return value, "" end
    if value is number then
      local whole = math.tointeger(value)
      if whole ~= nil then return whole, "" end
      return nil, ("%s: want integer, got %s"):format(path, shown(value))
    end
    return nil, mismatch(path, "integer", if absent(value) then nil else value end)
  end,
}
Shape.boolean = {
  check = function(value: any, path: string): boolean?, string
    if value is boolean then return value, "" end
    return nil, mismatch(path, "boolean", if absent(value) then nil else value end)
  end,
}

Shape.any = {
  check = function(value: any, path: string): any, string
    if absent(value) then return nil, path .. ": missing" end
    return value, ""
  end,
}

return Shape
