--- Resolves `Schema.message_of("Module.Record", { field = number })` and `Schema.enum_of("Module.Enum", { Value =
--- number })` where a module is compiled: each call names a record or an enum and gives its numbers, and this reads
--- the declaration off the checker's types and the table off the call's syntax, checks one against the other, and
--- splices into the call the Teal functions that write and read the record, or that turn the enum's values to
--- numbers and back, over [`cosmic.protobuf.schema`]'s `build`. The checker types that code as any other, so what a
--- call answers is typed by what the functions answer.
---
--- A call is found and its name read as [`build.syntax_shape_specs`] reads [`Shape.record_of`]'s, with the parts the
--- two share ([`build.syntax_record_calls`]): the module binds [`cosmic.protobuf.schema`] at its top level, the name
--- is a plain string literal, and a call that already has its functions is left as it is.
---
--- What is written goes on the call's own line, so the lines a message names do not move.
local Ast = require("lang.ast")
local Driver = require("build.driver")
local Lexer = require("lang.lexer")
local Match = require("build.syntax_match")
local Node = require("build.syntax_node")
local RecordCalls = require("build.syntax_record_calls")
local Types = require("lang.types")

local record ProtobufSpecs
  --- One call's resolution.
  type Splice = RecordCalls.Splice

  --- What [`ProtobufSpecs.splices`] found of a source.
  record Found
    --- Each call's splice, the last in the source first; none where a call was refused.
    splices: {Splice}
    --- What was refused, as the compiler words a refusal (`file:line: ...`); "" where nothing was.
    refusal: string
    --- The line of the call refused; 0 where none was.
    line: integer
  end

  --- Whether `source` may hold a call this resolves: a cheap test of its text, before any of it is parsed.
  mentions: function(source: string): boolean

  --- What a compile splices into `source`, the text `module` of `build` was read from: each call's functions, put
  --- after the call's table. None for a source with no such call, or that the compiler would refuse anyway. Where a
  --- call cannot be resolved, none, and the refusal and the call's line.
  splices: function(build: Driver.Build, module: string, file: string, source: string): Found
end

local type Type = Types.Type

local SCHEMA <const> = "cosmic.protobuf.schema"

--- The greatest number a field may have.
local MAX_NUMBER <const> = 536870911

--- The most required embedded messages a record may have: its reader names a local for each, having no value to
--- stand for one that is missing, and a Lua function holds 200.
local MOST_REQUIRED_MESSAGES <const> = 150

--- The words a field cannot be named by in the code written for it.
local KEYWORDS <const>: {string: boolean} = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true,
  ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true,
  ["then"] = true, ["true"] = true, ["until"] = true, ["while"] = true,
}

--- How a field is encoded.
local enum Kind
  "int"
  "sint"
  "bool"
  "fixed32"
  "sfixed32"
  "fixed64"
  "sfixed64"
  "float"
  "double"
  "bytes"
  "string"
  "enum"
  "message"
end

--- What each kind is on the wire, and in the code written for it.
local record Wire
  --- The wire type.
  wire: integer
  --- The method of a message that reads one, and the one that reads every one; "" where a helper reads it.
  read: string
  --- The helper that writes one.
  put: string
  --- The [`Protobuf.Kind`] that packs it; "" where it is not a number.
  packs: string
  --- The value a required field has where it is missing, and an implicit one where it is absent.
  zero: string
end

local WIRES <const>: {Kind: Wire} = {
  int = { wire = 0, read = "int", put = "put_int", packs = "int", zero = "0" },
  sint = { wire = 0, read = "sint", put = "put_sint", packs = "sint", zero = "0" },
  bool = { wire = 0, read = "bool", put = "put_bool", packs = "", zero = "false" },
  fixed32 = { wire = 5, read = "fixed32", put = "put_fixed32", packs = "fixed32", zero = "0" },
  sfixed32 = { wire = 5, read = "sfixed32", put = "put_sfixed32", packs = "fixed32", zero = "0" },
  fixed64 = { wire = 1, read = "fixed64", put = "put_fixed64", packs = "fixed64", zero = "0" },
  sfixed64 = { wire = 1, read = "fixed64", put = "put_fixed64", packs = "fixed64", zero = "0" },
  float = { wire = 5, read = "float", put = "put_float", packs = "float", zero = "0.0" },
  double = { wire = 1, read = "double", put = "put_double", packs = "double", zero = "0.0" },
  bytes = { wire = 2, read = "bytes", put = "put_bytes", packs = "", zero = '""' },
  string = { wire = 2, read = "", put = "put_string", packs = "", zero = '""' },
  enum = { wire = 0, read = "", put = "", packs = "", zero = "" },
  message = { wire = 2, read = "", put = "", packs = "", zero = "" },
}

--- The helpers of the schema module an entry may be made with, and the kind each names; "" for the field's own.
local HELPERS <const>: {string: string} = {
  field = "", sint = "sint", fixed32 = "fixed32", fixed64 = "fixed64", sfixed32 = "sfixed32", sfixed64 = "sfixed64",
  float = "float", string = "string", enum = "enum", message = "message", self = "self",
}

--- What a field's type is, as far as its encoding goes.
local record Shape
  --- "integer", "number", "boolean", "string", "enum", "record" or "unknown".
  base: string
  repeated: boolean
  optional: boolean
  --- The declaration, of an enum or a record.
  decl?: Types.Decl
end

--- One entry of the call's table.
local record Entry
  name: string
  number: integer
  --- The helper that made it, "" for a bare number.
  helper: string
  --- The text of the codec an `enum` or `message` entry names; "" otherwise.
  codec: string
  mut packed: boolean
  mut implicit: boolean
  --- The literal of `{ default = ... }`, which [`default_of`] holds to the field's kind; nil for none.
  mut default?: Ast.Exp
end

--- A field ready to be written: its entry, its type and its kind.
local record Planned
  entry: Entry
  shape: Shape
  kind: Kind
  --- The Teal text of the field's default, or "" for none.
  default: string
end

--- The text of the tokens `first` through `last`, each apart from the next by a space.
local function text_of(chunk: Ast.Chunk, first: integer, last: integer): string
  local parts: mut {string} = {}
  for i = first, last do
    parts[#parts + 1] = Lexer.text(chunk.tokens, i)
  end
  return table.concat(parts, " ")
end

--- The integer `e` writes, a literal or a negated one, or nil.
local function integer_of(e: Ast.Exp?): integer?
  if e == nil then return nil end
  if e.kind == "Integer" then return e.value end
  if e.kind == "Unary" and e.op == "-" then
    local operand = e.operand
    if operand.kind == "Integer" then return -operand.value end
  end
  return nil
end

--- The key and the value of an item of a table that is `name = value` or `["name"] = value`, or nil for another.
local function keyed(item: Ast.Item): string?, Ast.Exp?
  if item.kind == "Named" then return item.name, item.value end
  if item.kind == "Keyed" then
    local key = item.key
    if key.kind == "String" then return key.value, item.value end
  end
  return nil, nil
end

--- The options a table literal gives into `entry`, or why it gives none.
local function options_into(e: Ast.Exp, entry: Entry): boolean, string
  if e.kind ~= "Table" then return false, "the options must be a table written in the call" end
  for _, item in ipairs(e.items) do
    local key, value = keyed(item)
    if key == nil or value == nil then
      return false, "an option is written `packed = true`, `implicit = true` or `default = <literal>`"
    end
    if key == "default" then
      entry.default = value
    elseif key ~= "packed" and key ~= "implicit" then
      return false, ("%q is no option: they are `packed`, `implicit` and `default`"):format(key)
    elseif value.kind ~= "Boolean" then
      return false, ("`%s` is written `%s = true` or `%s = false`"):format(key, key, key)
    elseif key == "packed" then
      entry.packed = value.value
    else
      entry.implicit = value.value
    end
  end
  return true, ""
end

--- The entry `value` writes for the field `name`, or nil and why it is none. `schema` is the name the module gives
--- the schema module.
local function entry_of(chunk: Ast.Chunk, schema: string, name: string, value: Ast.Exp): Entry?, string
  local bare = integer_of(value)
  if bare ~= nil then
    return { name = name, number = bare, helper = "", codec = "", packed = false, implicit = false }, ""
  end
  local form = ("a number, or an entry written %s.float(6)"):format(schema)
  if value.kind ~= "Call" then return nil, "its entry must be " .. form end
  local callee = value.callee
  if callee.kind ~= "Field" then return nil, "its entry must be " .. form end
  local object = callee.object
  local helper = HELPERS[callee.name]
  if object.kind ~= "Name" or object.text ~= schema or helper == nil then
    return nil, "its entry must be " .. form
  end
  local number = integer_of(value.args[1])
  if number == nil then return nil, "its entry's number must be an integer written in the call" end
  local codec = ""
  local options = 2
  if helper == "enum" or helper == "message" then
    local named = value.args[2]
    if named == nil then
      return nil, ("%s.%s takes the codec of the field's type after its number"):format(schema, helper)
    end
    local path: Ast.Exp = named
    while path.kind == "Field" do path = path.object end
    if path.kind ~= "Name" then
      return nil, ("%s.%s takes its codec by name, `CODEC` or `Module.CODEC`: bind another to a local"):format(schema,
        helper)
    end
    codec = text_of(chunk, Node.base(named).first, Node.base(named).last)
    options = 3
  end
  if #value.args > options then return nil, "its entry has more arguments than its helper takes" end
  local entry: Entry = { name = name, number = number, helper = helper, codec = codec, packed = false,
    implicit = false }
  local given = value.args[options]
  if given ~= nil then
    local ok, why = options_into(given, entry)
    if not ok then return nil, why end
  end
  return entry, ""
end

--- What the type `t` of a field is, or nil and why it has no encoding.
local function shape_of(t: Type, omittable: boolean): Shape?, string
  local inner = t
  local optional = omittable
  if inner.tag == "union" then
    if #inner.members > 1 then return nil, "a union of more than one type has no encoding" end
    inner = assert(inner.members[1])
    optional = true
  end
  local repeated = false
  if inner.tag == "array" then
    repeated = true
    inner = inner.element
  end
  if inner.atom == true then
    local tag = tostring(inner.tag)
    if tag == "integer" or tag == "number" or tag == "boolean" or tag == "string" then
      return { base = tag, repeated = repeated, optional = optional }, ""
    end
    return nil, ("a %s has no encoding"):format(tag)
  end
  if inner.tag == "named" then
    local decl = inner.decl
    local body = decl.body
    if #inner.args > 0 or (body ~= nil and #body.tparams > 0) then
      return nil, "a generic type has no encoding"
    end
    if decl.module == SCHEMA and decl.names[#decl.names] == "Unknown" then
      if repeated then return nil, "a list of Unknown has no encoding" end
      return { base = "unknown", repeated = false, optional = optional }, ""
    end
    -- TODO: take an integer enum (`enum E: integer`) as a field's type, whose members are their own numbers and need no
    -- `enum_of` table, once a program of the tree declares a schema with one.
    if decl.kind == "enum" then
      return { base = "enum", repeated = repeated, optional = optional, decl = decl }, ""
    end
    if decl.kind == "record" then
      if body ~= nil and body.array ~= nil then
        return nil, "a record that is also an array has no encoding"
      end
      return { base = "record", repeated = repeated, optional = optional, decl = decl }, ""
    end
    return nil, ("a %s has no encoding"):format(decl.kind)
  end
  if inner.tag == "array" then return nil, "a list of lists has no encoding" end
  if inner.tag == "map" then
    return nil, "a map has no encoding yet"
  end
  if inner.tag == "fn" then return nil, "a function has no encoding" end
  return nil, "a type of this kind has no encoding"
end

--- The kind the entry gives a field of that shape, or nil and why the two do not fit. `target` is the record the
--- call is for.
local function kind_of(schema: string, entry: Entry, shape: Shape, target: Types.Decl): Kind?, string
  local helper, base = entry.helper, shape.base
  local kind: Kind
  if base == "integer" then
    if helper == "" then
      kind = "int"
    elseif helper == "sint" then
      kind = "sint"
    elseif helper == "fixed32" then
      kind = "fixed32"
    elseif helper == "fixed64" then
      kind = "fixed64"
    elseif helper == "sfixed32" then
      kind = "sfixed32"
    elseif helper == "sfixed64" then
      kind = "sfixed64"
    else
      return nil, ("%s.%s does not encode an integer"):format(schema, helper)
    end
  elseif base == "number" then
    if helper == "" then
      kind = "double"
    elseif helper == "float" then
      kind = "float"
    else
      return nil, ("%s.%s does not encode a number"):format(schema, helper)
    end
  elseif base == "boolean" then
    if helper ~= "" then return nil, ("%s.%s does not encode a boolean"):format(schema, helper) end
    kind = "bool"
  elseif base == "string" then
    if helper == "" then
      kind = "bytes"
    elseif helper == "string" then
      kind = "string"
    else
      return nil, ("%s.%s does not encode a string"):format(schema, helper)
    end
  elseif base == "enum" then
    if helper ~= "enum" then
      return nil, ("an enum's entry names its codec: %s.enum(%d, CODEC)"):format(schema, entry.number)
    end
    kind = "enum"
  else
    if helper == "self" then
      if shape.decl ~= target then
        return nil, ("%s.self is for a field of the record's own type"):format(schema)
      end
    elseif helper ~= "message" then
      return nil, ("a record's entry names its codec: %s.message(%d, CODEC), or %s.self(%d) for the record's own"):format(
        schema, entry.number, schema, entry.number)
    end
    kind = "message"
  end
  local packs = assert(WIRES[kind]).packs ~= "" or kind == "bool" or kind == "enum"
  if entry.packed and not (shape.repeated and packs) then
    return nil, "`packed` is for a repeated field of numbers, booleans or enums"
  end
  if entry.implicit and (shape.repeated or shape.optional or kind == "enum" or kind == "message") then
    return nil, "`implicit` is for a field declared `f: T` of a number, a boolean or a string"
  end
  if entry.default ~= nil then
    if shape.repeated or shape.optional or kind == "enum" or kind == "message" then
      return nil, "`default` is for a field declared `f: T` of a number, a boolean or a string"
    end
    if entry.implicit then return nil, "a field with a default is not also `implicit`" end
  end
  return kind, ""
end

--- A string literal of Teal for `text`.
local function quoted(text: string): string
  return ("%q"):format(text)
end

--- A string literal of Teal for any bytes, on one line: `%q` writes a newline as a backslash and a newline, which
--- would move the lines after the call.
local function quoted_bytes(text: string): string
  return '"' .. (text:gsub('[%c"\\\128-\255]', function(c: string): string
    return ("\\%03d"):format((assert(c:byte())))
  end)) .. '"'
end

--- The Teal text of the default `e` for a field of the kind `kind`, or nil and why it is none.
local function default_of(e: Ast.Exp, kind: Kind): string?, string
  local wanted: string
  if kind == "bool" then
    if e.kind == "Boolean" then return tostring(e.value), "" end
    wanted = "a boolean"
  elseif kind == "bytes" or kind == "string" then
    if e.kind == "String" then
      if kind == "string" and utf8.len(e.value) == nil then
        return nil, "the default is no UTF-8"
      end
      return quoted_bytes(e.value), ""
    end
    wanted = "a string"
  elseif kind == "float" or kind == "double" then
    local value: number? = integer_of(e)
    if e.kind == "Float" then
      value = e.value
    elseif e.kind == "Unary" and e.op == "-" then
      local operand = e.operand
      if operand.kind == "Float" then value = -operand.value end
    end
    if value ~= nil then
      if value ~= value or value == math.huge or value == -math.huge then
        return nil, "the default is no finite number"
      end
      -- A `float` is written in 32 bits, so a default it cannot hold would read back as another number.
      if kind == "float" and string.unpack("<f", string.pack("<f", value)) ~= value then
        return nil, ("the default %.17g is no float's value: write the one a float holds"):format(value)
      end
      local text = ("%.17g"):format(value)
      if text:find("[%.eE]") == nil then text = text .. ".0" end
      return text, ""
    end
    wanted = "a number"
  else
    local value = integer_of(e)
    if value ~= nil then
      if kind == "fixed32" and (value < 0 or value > 4294967295) then
        return nil, ("the default %d is outside 0 to 4294967295"):format(value)
      end
      if kind == "sfixed32" and (value < -2147483648 or value > 2147483647) then
        return nil, ("the default %d is outside -2147483648 to 2147483647"):format(value)
      end
      -- The literal of the least integer is a float in Lua: its digits are past the greatest.
      if value == math.mininteger then return "math.mininteger", "" end
      return tostring(value), ""
    end
    wanted = "an integer"
  end
  return nil, ("the default must be %s written in the call"):format(wanted)
end

--- What the generator knows while it writes one record's functions.
local record Gen
  --- The name the calling module gives the schema module.
  schema: string
  --- How the calling module spells the record.
  spelled: string
  --- Whether the record keeps what it does not understand, and the field that holds it.
  keeps: boolean
  unknown: string
end

--- The expression that reads the field, for the record's literal.
local function read_of(_g: Gen, p: Planned): string
  local e, kind = p.entry, p.kind
  local n, f = tostring(e.number), quoted(e.name)
  local w = assert(WIRES[kind])
  local codec_read = if e.helper == "self" then "pb_read" else e.codec .. ".read" end
  if p.shape.repeated then
    local list: string
    if kind == "bool" then
      list = ("pb_b.bools(pb_r, %s, %s)"):format(n, f)
    elseif kind == "bytes" then
      list = ("pb_b.all_bytes(pb_r, %s, %s)"):format(n, f)
    elseif kind == "string" then
      list = ("pb_b.texts(pb_r, %s, %s)"):format(n, f)
    elseif kind == "enum" then
      list = ("pb_b.enums(pb_r, %s, %s, %s.name)"):format(n, f, e.codec)
    elseif kind == "message" then
      list = ("pb_b.messages(pb_r, %s, %s, %s)"):format(n, f, codec_read)
    elseif kind == "float" or kind == "double" then
      list = ("pb_b.numbers(pb_r, %s, %s, %s)"):format(n, f, quoted(kind))
    else
      list = ("pb_b.integers(pb_r, %s, %s, %s)"):format(n, f, quoted(kind))
    end
    if p.shape.optional then return ("pb_b.some(%s)"):format(list) end
    return list
  end
  if kind == "message" then
    return ("pb_b.message(pb_r, %s, %s, %s)"):format(n, f, codec_read)
  end
  local raw: string
  if kind == "string" then
    raw = ("pb_b.text(pb_r, %s, %s)"):format(n, f)
  elseif kind == "enum" then
    raw = ("pb_m:int(%s)"):format(n)
  else
    raw = ("pb_m:%s(%s)"):format(w.read, n)
  end
  if kind == "enum" then
    if not p.shape.optional then
      local decl = assert(p.shape.decl, "an enum's shape holds its declaration")
      local values = assert(decl.body, "an enum that was planned has a body").values
      return ("pb_b.need_enum(pb_r, %s, %s, %s.name(%s), %s)"):format(n, f, e.codec, raw,
        quoted((assert(values[1], "an enum that was planned has a value"))))
    end
    return ("%s.name(%s)"):format(e.codec, raw)
  end
  if p.shape.optional then return raw end
  if e.implicit then return ("pb_b.or_zero(%s, %s)"):format(raw, w.zero) end
  if p.default ~= "" then return ("pb_b.or_zero(%s, %s)"):format(raw, p.default) end
  return ("pb_b.need(pb_r, %s, %s, %s, %s)"):format(n, f, raw, w.zero)
end

--- The statement that writes the field.
local function write_of(_g: Gen, p: Planned): string
  local e, kind = p.entry, p.kind
  local n, f = tostring(e.number), quoted(e.name)
  local w = assert(WIRES[kind])
  local value = "pb_v." .. e.name
  local codec_write = if e.helper == "self" then "pb_write" else e.codec .. ".write" end
  local packed = tostring(e.packed)
  if p.shape.repeated then
    if kind == "bool" then
      return ("pb_b.put_bools(pb_o, %s, %s, %s)"):format(n, value, packed)
    end
    if kind == "bytes" then return ("pb_b.put_all_bytes(pb_o, %s, %s)"):format(n, value) end
    if kind == "string" then
      return ("pb_b.put_all_strings(pb_o, %s, %s)"):format(n, value)
    end
    if kind == "enum" then
      return ("pb_b.put_enums(pb_o, %s, %s, %s.number, %s)"):format(n, value, e.codec, packed)
    end
    if kind == "message" then
      return ("pb_b.put_messages(pb_o, %s, %s, %s, %s)"):format(n, f, value, codec_write)
    end
    return ("pb_b.put_numbers(pb_o, %s, %s, %s, %s)"):format(n, quoted(kind), value, packed)
  end
  if kind == "enum" then
    return ("pb_b.put_enum(pb_o, %s, %s, %s.number)"):format(n, value, e.codec)
  end
  if kind == "message" then
    return ("pb_b.put_message(pb_o, %s, %s, %s, %s)"):format(n, f, value, codec_write)
  end
  local put = ("pb_b.%s(pb_o, %s, %s)"):format(w.put, n, value)
  if e.implicit then return ("if %s ~= %s then %s end"):format(value, w.zero, put) end
  return put
end

--- The two functions of the record: the writer, then the reader, as the arguments the call lacks.
local function functions_of(g: Gen, planned: {Planned}): string
  local S, R = g.schema, g.spelled
  local wires: mut {string} = {}
  local names: mut {string} = {}
  local named: mut {string} = {}
  local reads: mut {string} = {}
  local writes: mut {string} = {}
  local present: mut {string} = {}
  local needed: mut {string} = {}
  for i, p in ipairs(planned) do
    local e = p.entry
    local wire = assert(WIRES[p.kind]).wire
    local packs = p.shape.repeated and (p.kind == "enum" or p.kind == "bool" or assert(WIRES[p.kind]).packs ~= "")
    wires[#wires + 1] = ("[%d] = %d"):format(e.number, if packs then wire + 8 else wire end)
    names[#names + 1] = ("[%d] = %s"):format(e.number, quoted(e.name))
    if g.keeps and p.kind == "enum" and not p.shape.repeated then
      named[#named + 1] = ("[%d] = function(pb_n: integer): boolean return %s.name(pb_n) ~= nil end"):format(
        e.number, e.codec)
    end
    if p.kind == "message" and not p.shape.repeated and not p.shape.optional then
      -- A required message has no value to stand for it where it is missing, so it is read before the literal.
      local held = "pb_q" .. tostring(i)
      needed[#needed + 1] = ("local %s = %s if %s == nil then return nil, pb_b.missing(pb_r, %d, %s) end"):format(
        held, read_of(g, p), held, e.number, quoted(e.name))
      reads[#reads + 1] = ("%s = %s"):format(e.name, held)
    else
      reads[#reads + 1] = ("%s = %s"):format(e.name, read_of(g, p))
    end
    writes[#writes + 1] = write_of(g, p)
    -- What was held for a number is written back while its field says nothing. A repeated field's is always:
    -- it is of another wire type than the elements, which no reader of them takes for one.
    local said = "true"
    if p.shape.repeated then
      said = "false"
    elseif p.shape.optional then
      said = ("pb_v.%s ~= nil"):format(e.name)
    elseif e.implicit then
      said = ("pb_v.%s ~= %s"):format(e.name, assert(WIRES[p.kind]).zero)
    end
    present[#present + 1] = ("[%d] = %s"):format(e.number, said)
  end
  if g.keeps then reads[#reads + 1] = ("%s = pb_b.unknown(pb_r)"):format(g.unknown) end
  local close = if g.keeps then
    ("pb_b.close(pb_o, pb_v.%s, { %s })"):format(g.unknown, table.concat(present, ", ")) else
    "pb_b.close(pb_o)" end
  -- A record of no fields has nothing to read of its value.
  local value = if #planned == 0 and not g.keeps then "_pb_v" else "pb_v" end
  local write = ("(function(): function(%s, into?: %s.Writing): string?, string " ..
    "local pb_b <const> = %s.build " ..
    "local function pb_write(%s: %s, pb_into?: %s.Writing): string?, string " ..
    "local pb_o = pb_b.writer(pb_into) %s return %s end return pb_write end)()"):format(R, S, S, value, R, S,
      table.concat(writes, " "), close)
  local read = ("(function(): function(%s.Message, lenient?: boolean): %s?, string " ..
    "local pb_b <const> = %s.build " ..
    "local pb_p <const> = pb_b.plan({ %s }, { %s }) " ..
    "local pb_e <const>: {integer: function(integer): boolean} = { %s } " ..
    "local function pb_read(pb_m: %s.Message, pb_l?: boolean): %s?, string " ..
    "local pb_r = pb_b.open(pb_m, pb_p, pb_e, %s, pb_l == true) %s " ..
    "local pb_t: %s = { %s } return pb_b.done(pb_r, pb_t) end return pb_read end)()"):format(S, R, S,
      table.concat(wires, ", "), table.concat(names, ", "), table.concat(named, ", "), S, R, tostring(g.keeps),
      table.concat(needed, " "), R, table.concat(reads, ", "))
  return ", " .. write .. ", " .. read
end

--- The functions of the record `decl`, spelled `spelled`, for the table `fields`, or nil and why.
local function gen_message(chunk: Ast.Chunk, schema: string, spelled: string, decl: Types.Decl, fields: Ast.Exp):
    string?, string
  local body = decl.body
  if body == nil then return nil, "a declaration the checker did not resolve" end
  if body.array ~= nil then return nil, "a record that is also an array is no message" end
  if #body.supers > 0 then return nil, "a record that implements an interface is no message" end
  if fields.kind ~= "Table" then return nil, "the fields must be a table written in the call" end
  local entries: mut {string: Entry} = {}
  local order: mut {string} = {}
  for _, item in ipairs(fields.items) do
    local name, value = keyed(item)
    if name == nil or value == nil then return nil, "each field is written `name = number`" end
    if entries[name] ~= nil then return nil, name .. ": it is given twice" end
    local entry, why = entry_of(chunk, schema, name, value)
    if entry == nil then return nil, name .. ": " .. why end
    if entry.number < 1 or entry.number > MAX_NUMBER then
      return nil, ("%s: %d is no field number: they are 1 to %d"):format(name, entry.number, MAX_NUMBER)
    end
    if entry.number >= 19000 and entry.number <= 19999 then
      return nil, ("%s: %d is a number the format reserves (19000 to 19999)"):format(name, entry.number)
    end
    entries[name] = entry
    order[#order + 1] = name
  end
  local declared: mut {string: Types.Field} = {}
  local g: Gen = { schema = schema, spelled = spelled, keeps = false, unknown = "" }
  local shapes: mut {string: Shape} = {}
  for _, field in ipairs(body.fields) do
    declared[field.name] = field
    if field.name:match("^[%a_][%w_]*$") == nil or KEYWORDS[field.name] == true then
      return nil, ("%s: a field of this name cannot be named in the code the build writes: rename it"):format(
        field.name)
    end
    local shape, why = shape_of(field.type, field.omittable == true)
    if shape == nil then return nil, field.name .. ": " .. why end
    shapes[field.name] = shape
    if shape.base == "unknown" then
      if g.keeps then return nil, field.name .. ": the record has two fields of Unknown" end
      if not shape.optional then
        return nil, ("%s: a field of Unknown is optional, `%s?: %s.Unknown`"):format(field.name, field.name, schema)
      end
      g = { schema = schema, spelled = spelled, keeps = true, unknown = field.name }
      if entries[field.name] ~= nil then
        return nil, field.name .. ": a field of Unknown takes no number"
      end
    elseif entries[field.name] == nil then
      return nil, ("%s: the field has no number: write `%s = <number>` in the call's table"):format(field.name,
        field.name)
    end
  end
  local numbers: mut {integer: string} = {}
  local planned: mut {Planned} = {}
  local required = 0
  for _, name in ipairs(order) do
    local entry = assert(entries[name])
    if declared[name] == nil then return nil, ("%s: the record has no such field"):format(name) end
    local other = numbers[entry.number]
    if other ~= nil then
      return nil, ("%s: number %d is %s's too"):format(name, entry.number, other)
    end
    numbers[entry.number] = name
    local shape = assert(shapes[name])
    local kind, why = kind_of(schema, entry, shape, decl)
    if kind == nil then return nil, name .. ": " .. why end
    if g.keeps and kind == "enum" and shape.repeated then
      return nil, name .. ": a repeated enum cannot keep the place of a number the enum does not name, and the " ..
        "record keeps what it does not understand: declare the field `{integer}`"
    end
    if kind == "message" and entry.helper == "message" then
      local theirs = assert(shape.decl, "a record's shape holds its declaration").body
      local inside: {Types.Field} = if theirs ~= nil then theirs.fields else {} end
      for _, inner in ipairs(inside) do
        local held, _ = shape_of(inner.type, inner.omittable == true)
        if held ~= nil and held.decl == decl then
          return nil, ("%s: %s and %s hold each other, and the code for one cannot name the other's before it " ..
            "is made: a message that holds itself is written with %s.self"):format(name, decl.name,
              assert(shape.decl).name, schema)
        end
      end
    end
    if kind == "message" and not shape.repeated and not shape.optional then
      required = required + 1
    end
    local default = ""
    local literal = entry.default
    if literal ~= nil then
      local text, unfit = default_of(literal, kind)
      if text == nil then return nil, name .. ": " .. unfit end
      default = text
    end
    planned[#planned + 1] = { entry = entry, shape = shape, kind = kind, default = default }
  end
  if required > MOST_REQUIRED_MESSAGES then
    return nil, ("the record has %d required embedded messages, and its reader holds %d at most: declare some " ..
      "optional"):format(required, MOST_REQUIRED_MESSAGES)
  end
  table.sort(planned, function(a: Planned, b: Planned): boolean
    return a.entry.number < b.entry.number
  end)
  return functions_of(g, planned), ""
end

--- The functions of the enum `decl`, spelled `spelled`, for the table `numbers`, or nil and why.
local function gen_enum(spelled: string, decl: Types.Decl, numbers: Ast.Exp): string?, string
  local body = decl.body
  if body == nil then return nil, "a declaration the checker did not resolve" end
  if numbers.kind ~= "Table" then return nil, "the numbers must be a table written in the call" end
  local given: mut {string: integer} = {}
  local taken: mut {integer: string} = {}
  for _, item in ipairs(numbers.items) do
    local name, value = keyed(item)
    local number = integer_of(value)
    if name == nil or number == nil then return nil, "each value is written `Name = number`" end
    if number < -2147483648 or number > 2147483647 then
      return nil, ("%s: %d is outside an enum's numbers, which are 32 bits"):format(name, number)
    end
    if given[name] ~= nil then return nil, name .. ": it is given twice" end
    local other = taken[number]
    if other ~= nil then return nil, ("%s: number %d is %s's too"):format(name, number, other) end
    given[name] = number
    taken[number] = name
  end
  local values: mut {string} = {}
  local known: mut {string: boolean} = {}
  for _, value in ipairs(body.values) do
    values[#values + 1] = value
    known[value] = true
    if given[value] == nil then return nil, ("%s: the value has no number"):format(value) end
  end
  if #values == 0 then return nil, "an enum with no values has no numbers" end
  for name in pairs(given) do
    if known[name] ~= true then return nil, ("%s: the enum has no such value"):format(name) end
  end
  table.sort(values)
  local names: mut {string} = {}
  local of: mut {string} = {}
  for i, value in ipairs(values) do
    local number = assert(given[value])
    names[#names + 1] = ("if pb_n == %d then return %s end"):format(number, quoted(value))
    if i < #values then
      of[#of + 1] = ("if pb_v == %s then return %d end"):format(quoted(value), number)
    else
      of[#of + 1] = ("return %d"):format(number)
    end
  end
  return (", function(pb_n: integer?): %s? %s return nil end, function(pb_v: %s): integer %s end"):format(spelled,
    table.concat(names, " "), spelled, table.concat(of, " ")), ""
end

function ProtobufSpecs.mentions(source: string): boolean
  return source:find("message_of", 1, true) ~= nil or source:find("enum_of", 1, true) ~= nil
end

--- The calls of `pattern` in `chunk` on the name `schema`.
local function calls_of(chunk: Ast.Chunk, schema: string, pattern: string): {Match.Hit}?, string
  local compiled, trouble = Match.compile(pattern)
  if compiled == nil then return nil, trouble end
  local calls: mut {Match.Hit} = {}
  for _, hit in ipairs(Match.find_all(compiled, chunk, chunk)) do
    local on = hit.caps["_S"]
    local head = if on ~= nil then on.nodes[1] else nil end
    if head ~= nil and head.kind == "Name" and head.text == schema then
      calls[#calls + 1] = hit
    end
  end
  return calls, ""
end

function ProtobufSpecs.splices(build: Driver.Build, module: string, file: string, source: string): ProtobufSpecs.Found
  local none: {RecordCalls.Splice} = {}
  local nothing: ProtobufSpecs.Found = { splices = none, refusal = "", line = 0 }
  if not ProtobufSpecs.mentions(source) then return nothing end
  -- A module that names the calls without requiring the schema module at its top level has nothing to splice: that
  -- is seen in its syntax, before lowering it and all it requires.
  -- TODO: refuse a use of `message_of` or `enum_of` the build does not complete (through an alias, as a value), as
  -- build.syntax_shape_specs refuses one of `record_of`, once a module is found to write one; such a use raises
  -- when it runs.
  local read = build:parsed(module)
  if read ~= nil and not read.broken and RecordCalls.required(read.chunk)[SCHEMA] == nil then
    return nothing
  end
  build:lower({ module })
  local outcome = build:result(module, false)
  if outcome == nil or outcome.broken then return nothing end
  local chunk = outcome.chunk
  local aliases = RecordCalls.required(chunk)
  local schema = aliases[SCHEMA]
  if schema == nil then return nothing end
  local splices: mut {RecordCalls.Splice} = {}
  for _, what in ipairs({ "message_of", "enum_of" }) do
    local calls, trouble = calls_of(chunk, schema, ("$S.%s($N, $T, $$$MORE)"):format(what))
    if calls == nil then return { splices = none, refusal = trouble, line = 0 } end
    for _, hit in ipairs(calls) do
      local span = Node.span(chunk, hit.node)
      local where = ("%s:%d: %s.%s"):format(file, span.y, schema, what)
      local more = hit.caps["___MORE"]
      -- A call that already has its functions is left as it is: they are functions the checker types.
      if more ~= nil and #more.nodes > 0 then continue end
      local named = assert(hit.caps["_N"], "the pattern captures _N")
      local table_cap = assert(hit.caps["_T"], "the pattern captures _T")
      local literal = named.nodes[1]
      local fields = table_cap.nodes[1]
      if literal == nil or literal.kind ~= "String" then
        return { splices = none, line = span.y,
          refusal = where .. ": the name must be a string literal, which the build reads" }
      end
      local written = Lexer.text(chunk.tokens, named.first)
      local quote = written:sub(1, 1)
      if literal.long or (quote ~= '"' and quote ~= "'") or written:find("\\", 1, true) ~= nil then
        return { splices = none, line = span.y,
          refusal = where .. ": the name must be a plain quoted string with no escape in it" }
      end
      local function refused(why: string): ProtobufSpecs.Found
        return { splices = none, line = span.y, refusal = ("%s(%q): %s"):format(where, literal.value, why) }
      end
      local target, unresolved = RecordCalls.resolve_name(build, outcome, literal.value, Node.base(hit.node).first,
        aliases)
      if target == nil then return refused(unresolved) end
      local at = target.type
      local wanted = if what == "message_of" then "record" else "enum" end
      if at.tag ~= "named" or at.decl.kind ~= wanted then
        return refused(("it is no %s"):format(wanted))
      end
      if fields == nil or not (fields.kind == "Table") then
        return refused("its second argument must be a table written in the call")
      end
      local made, why: string?, string
      if what == "message_of" then
        made, why = gen_message(chunk, schema, target.spelled, at.decl, fields)
      else
        made, why = gen_enum(target.spelled, at.decl, fields)
      end
      if made == nil then return refused(why) end
      splices[#splices + 1] = { at = Lexer.stop(chunk.tokens, table_cap.last) - 1, text = made }
    end
  end
  table.sort(splices, function(a: RecordCalls.Splice, b: RecordCalls.Splice): boolean
    return a.at > b.at
  end)
  return { splices = splices, refusal = "", line = 0 }
end

return ProtobufSpecs
