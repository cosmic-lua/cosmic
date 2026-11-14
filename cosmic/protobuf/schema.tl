--- A Protocol Buffers message declared once, as a Teal record and the numbers of its fields, and read and written
--- as that record. [`cosmic.protobuf`] is the wire format with no schema; this module is the schema, and a program
--- that uses the wire codec alone does not carry it.
---
---     local Schema = require("cosmic.protobuf.schema")
---
---     local record Track
---       title?: string
---       seconds?: number
---       tags: {string}
---     end
---     local TRACK <const> = Schema.message_of("Track", { title = Schema.string(1), seconds = 2, tags = 3 })
---     local bytes = assert(TRACK:encode({ title = "Blue", seconds = 215.5, tags = { "jazz" } }))
---     local track = assert(TRACK:decode(bytes))
---
--- The build writes a message's reader and writer from the record's own declaration and the table of the call
--- ([`message_of`]), so what `decode` answers is the record and a record literal is what `encode` takes.
---
--- A bare number takes the encoding the field's type gives, and a helper names another:
---
--- - `integer`: a varint, which is `int32`, `int64`, `uint32` and `uint64`. [`sint`], [`fixed32`], [`fixed64`],
---   [`sfixed32`] and [`sfixed64`] name the others.
--- - `number`: a double. [`float`] is a float.
--- - `boolean`: a bool.
--- - `string`: any bytes, a `bytes`. [`string`] holds them to UTF-8, a `string` of a `.proto` file.
--- - an enum: [`enum`], with the codec [`enum_of`] answers for it.
--- - a record: [`message`], with the codec [`message_of`] answers for it, or [`self`] for the record's own.
--- - `{T}`: a repeated field of `T`'s encoding, written one field for each element and read packed or not.
---   `{ packed = true }` writes numbers, booleans and enums packed.
--- - [`Unknown`]: what the record keeps of a message without understanding it. It takes no number.
---
--- Presence is the field's own declaration. `f?: T` is nil where the field is absent and is not written when nil.
--- `f: T` must be there: `decode` fails without it, and it is always written. `f: {T}` is an empty array where
--- absent, and `f?: {T}` nil. `{ implicit = true }` on a field declared `f: T` is proto3's field with no presence:
--- absent reads as zero, `""` or false, and that value is not written.
---
--- A record that declares a field of [`Unknown`] keeps what it does not understand, so that a program which
--- decodes a message, changes a field and encodes it loses nothing of the rest: a field whose number the call
--- does not name, a field of a named number that arrives with another wire type, and an enum number the enum
--- does not name. The last two leave their field nil, and are written back while it is still nil; one of a
--- repeated field is always written back. A field declared `f: T` has no nil to be left as, so either fails
--- `decode` for it. A record with no such field drops the first and the third and fails
--- `decode` for the second.
---
--- `decode` never raises, whatever the bytes, under the wire codec's bounds. It answers nil and the first thing that did not fit, by the path of
--- fields from the root: `protobuf: Album.tracks[2].title (field 1): not UTF-8`. The bounds are the wire
--- codec's ([`Protobuf.Options`]), and an option that is no integer of 1 or more raises, as [`Protobuf.decode`]
--- raises for it. `encode` answers nil and why for a record the schema cannot write, such as an integer outside a
--- `fixed32`. A record that holds itself through its own fields, which no `decode` answers, has no bytes: `encode`
--- of one does not return.
--- @public

local Protobuf = require("cosmic.protobuf")

local record Schema
  --- What a field's entry may say beside its number.
  record Options
    --- Write a repeated field of numbers, booleans or enums packed (default false).
    packed?: boolean
    --- Read an absent field as zero, `""` or false, and do not write that value (default false).
    implicit?: boolean
  end

  --- A field's entry in the table of [`message_of`]: its number and how it is encoded. The build reads the call
  --- that makes one, written `Schema.float(6)` where the table is; a program has no other use for it.
  record Entry
    --- The field's number.
    number: integer
  end

  --- What a record keeps of a message without understanding it, as a field of this type. Nil where a message
  --- held nothing of the kind.
  record Unknown
    --- The fields whose numbers the record's call does not name, in the order of the bytes.
    fields: {Protobuf.Field}
    --- The fields of a named number that were set aside: one of another wire type than its encoding, and an
    --- enum number the enum does not name. Each is written back while its field is nil.
    held: {Protobuf.Field}
  end

  --- A message as the wire codec read it, which a codec's `read` takes.
  type Message = Protobuf.Message

  --- An enum and its numbers, which [`enum_of`] answers.
  record Enum<E>
    --- The value of that number, or nil where the enum names none, or for nil.
    name: function(number: integer?): E?
    --- The number of a value.
    number: function(value: E): integer
  end

  --- A message's reader and writer, which [`message_of`] answers.
  record Codec<T>
    --- The record's name, as [`message_of`] was given it.
    name: string
    --- The bytes of `value`, or nil and why the schema cannot write it.
    encode: function(self: Codec<T>, value: T): string?, string
    --- The message in `bytes`, which may come from anywhere, or nil and the first thing that did not fit. It
    --- never raises for any bytes. `opts` are [`Protobuf.decode`]'s.
    decode: function(self: Codec<T>, bytes: string, opts?: Protobuf.Options): T?, string
    --- What the build wrote to read the record: the record of a message that was read, or nil and a failure with
    --- no root, a path from this message and why.
    read: function(message: Protobuf.Message): T?, string
    --- What the build wrote to write the record: its bytes, or nil and a failure with no root.
    write: function(value: T): string?, string
  end

  --- What the build wrote of a record's fields, made once for the codec.
  record Plan
    --- Each named number's wire type, plus 8 where a packed field of that number fits too.
    wires: {integer: integer}
    --- Each named number's field.
    names: {integer: string}
    --- The named numbers, least first.
    numbers: {integer}
    --- Whether a field is one the record does not understand: of a number it does not name, or of another wire
    --- type than the number's encoding.
    strange: function(number: integer, wire: integer): boolean
  end

  --- One message being read by the code the build wrote.
  record Reading
    --- The message as the wire codec read it.
    message: Protobuf.Message
    --- Whether the record keeps what it does not understand.
    keeps: boolean
    --- What becomes the record's [`Unknown`]: its `fields`.
    unknown: mut {Protobuf.Field}
    --- What becomes the record's [`Unknown`]: its `held`.
    held: mut {Protobuf.Field}
    --- The first thing that did not fit, as a path and a reason, or "".
    mut bad: string
  end

  --- One message being written by the code the build wrote.
  record Writing
    --- The fields written so far.
    writer: Protobuf.Writer
    --- The first thing that could not be written, or "".
    mut bad: string
  end

  --- What the code the build writes for [`message_of`] calls. Nothing else has a use for them.
  record Build
    --- What a codec's reader keeps of the record's fields: `wires` holds each named number's wire type, plus 8
    --- where a packed field of that number fits too, and `names` its field.
    plan: function(wires: {integer: integer}, names: {integer: string}): Plan
    --- A reading of `message`. `enums` says of each enum field's number whether the enum names a number. Where
    --- the record keeps, what it does not understand is set aside; where it drops, a field of a named number
    --- and another wire type is the reading's failure.
    open: function(message: Protobuf.Message, plan: Plan, enums: {integer: function(integer): boolean},
      keeps: boolean): Reading
    --- `value`, a required field's, or `zero` and a failure where it is nil.
    need: function<V>(r: Reading, number: integer, field: string, value: V?, zero: V): V
    --- A field held to UTF-8: its text, or nil, and a failure where its bytes are no UTF-8.
    text: function(r: Reading, number: integer, field: string): string?
    --- An embedded message, read by `read`, or nil where the number has none.
    message: function<T>(r: Reading, number: integer, field: string,
      read: function(Protobuf.Message): T?, string): T?
    --- A required enum field: the value `named`, or `first` and a failure where the field is missing or the enum
    --- names no such number. `first` is a value of the enum, which stands where there is none to answer.
    need_enum: function<E>(r: Reading, number: integer, field: string, named: E?, first: E): E
    --- `value`, or `zero` where it is nil: a field with no presence.
    or_zero: function<V>(value: V?, zero: V): V
    --- Why a required message is not there: the reading's failure, or that the field is missing.
    missing: function(r: Reading, number: integer, field: string): string
    --- A repeated field of integers of that kind, packed or not.
    integers: function(r: Reading, number: integer, field: string, kind: string): {integer}
    --- A repeated `float` or `double`, packed or not.
    numbers: function(r: Reading, number: integer, field: string, kind: string): {number}
    --- A repeated field of any bytes.
    all_bytes: function(r: Reading, number: integer, field: string): {string}
    --- A repeated `bool`.
    bools: function(r: Reading, number: integer, field: string): {boolean}
    --- A repeated field held to UTF-8.
    texts: function(r: Reading, number: integer, field: string): {string}
    --- A repeated enum: the values the enum names, in order.
    enums: function<E>(r: Reading, number: integer, field: string, name: function(integer?): E?): {E}
    --- A repeated embedded message, each read by `read`.
    messages: function<T>(r: Reading, number: integer, field: string,
      read: function(Protobuf.Message): T?, string): {T}
    --- `values`, or nil where it is empty: an optional repeated field.
    some: function<V>(values: {V}): {V}?
    --- What the record keeps, or nil where the message held nothing of the kind.
    unknown: function(r: Reading): Unknown?
    --- `value` and "", or nil and the reading's failure.
    done: function<T>(r: Reading, value: T): T?, string

    --- A message to write.
    writer: function(): Writing
    --- A varint field, where `value` is not nil. Each `put_` below writes its own kind the same way: nothing for
    --- nil, and a failure kept in `w` for a value the kind cannot hold.
    put_int: function(w: Writing, number: integer, value: integer?)
    --- A `sint`.
    put_sint: function(w: Writing, number: integer, value: integer?)
    --- A `bool`.
    put_bool: function(w: Writing, number: integer, value: boolean?)
    --- A `fixed32`, from 0 to 4294967295.
    put_fixed32: function(w: Writing, number: integer, value: integer?)
    --- An `sfixed32`, from -2147483648 to 2147483647.
    put_sfixed32: function(w: Writing, number: integer, value: integer?)
    --- A `fixed64` or an `sfixed64`.
    put_fixed64: function(w: Writing, number: integer, value: integer?)
    --- A `float`.
    put_float: function(w: Writing, number: integer, value: number?)
    --- A `double`.
    put_double: function(w: Writing, number: integer, value: number?)
    --- A field of any bytes.
    put_bytes: function(w: Writing, number: integer, value: string?)
    --- A field held to UTF-8.
    put_string: function(w: Writing, number: integer, value: string?)
    --- An enum, by its number.
    put_enum: function<E>(w: Writing, number: integer, value: E?, number_of: function(E): integer)
    --- An embedded message, written by `write`.
    put_message: function<T>(w: Writing, number: integer, field: string, value: T?,
      write: function(T): string?, string)
    --- A repeated field of numbers of that kind: packed where `packed`, one field each otherwise.
    put_numbers: function(w: Writing, number: integer, kind: string, values: {number}?, packed: boolean)
    --- A repeated `bool`.
    put_bools: function(w: Writing, number: integer, values: {boolean}?, packed: boolean)
    --- A repeated field of any bytes.
    put_all_bytes: function(w: Writing, number: integer, values: {string}?)
    --- A repeated field held to UTF-8.
    put_all_strings: function(w: Writing, number: integer, values: {string}?)
    --- A repeated enum.
    put_enums: function<E>(w: Writing, number: integer, values: {E}?, number_of: function(E): integer,
      packed: boolean)
    --- A repeated embedded message, each written by `write`.
    put_messages: function<T>(w: Writing, number: integer, field: string, values: {T}?,
      write: function(T): string?, string)
    --- The bytes written, with what the record keeps after them: every unknown field, and each held field
    --- whose number `present`, which has every number the record names, does not say is set. Nil and why where a field could not be written: a path
    --- from this message, `.field` for each level, then `: ` and the reason.
    close: function(w: Writing, unknown?: Unknown, present?: {integer: boolean}): string?, string
  end

  --- The codec of the enum `name`, written by the build from the enum's declaration and `numbers`, which names
  --- the number of each value: `Schema.enum_of("Module.Kind", { Play = 1, Pause = 2 })`. The numbers may be
  --- zero or negative. The build refuses a value with no number, a number for no value, and two values of one
  --- number. `name` is a string literal, as [`message_of`]'s is, and the last two arguments are the build's to
  --- write.
  enum_of: function<E>(name: string, numbers: {string: integer}, name_of?: function(integer?): E?,
    number_of?: function(E): integer): Enum<E>

  --- The codec of the Teal record `name`, written by the build from the record's own declaration and `fields`,
  --- which names each field's number, or an entry a helper of this module makes for it.
  ---
  --- `name` is a string literal, read as [`Shape.record_of`]'s is: `Record` for a record declared above the
  --- call, `module.Record` for one a required module declares. `fields` is a table written in the call, each
  --- key a field of the record. The build refuses, where the call is: a field with no number, a number with no
  --- field, a number given twice, outside 1 to 536870911 or among the 19000 to 19999 the format reserves, an
  --- encoding that does not fit the field's type, a field of a type that has none (a function, a union, a
  --- generic), a field named by a keyword, a record that is also an array or implements an interface, two
  --- records that hold each other, more than 150 required embedded messages, and, in a record that keeps what
  --- it does not understand, a repeated enum (declare `{integer}`).
  ---
  --- A Lua function captures 255 locals at most, and the record's reader captures each codec its fields name:
  --- a message of more embedded types than that holds their codecs as fields of one record, which is one capture.
  ---
  --- The build puts after `fields` the two functions that write and read the record (write neither). A call
  --- it did not complete (through another name, in a chunk loaded by hand, in the Lua `cosmic compile` writes)
  --- raises here.
  message_of: function<T>(name: string, fields: {string: integer | Entry}, write?: function(T): string?, string,
    read?: function(Protobuf.Message): T?, string): Codec<T>

  --- The field's own encoding, with options.
  field: function(number: integer, options?: Options): Entry
  --- A `sint32` or `sint64`, for an `integer`.
  sint: function(number: integer, options?: Options): Entry
  --- A `fixed32`, from 0 to 4294967295, for an `integer`.
  fixed32: function(number: integer, options?: Options): Entry
  --- A `fixed64`, for an `integer`.
  fixed64: function(number: integer, options?: Options): Entry
  --- An `sfixed32`, from -2147483648 to 2147483647, for an `integer`.
  sfixed32: function(number: integer, options?: Options): Entry
  --- An `sfixed64`, for an `integer`.
  sfixed64: function(number: integer, options?: Options): Entry
  --- A `float`, for a `number`.
  float: function(number: integer, options?: Options): Entry
  --- A `string`, held to UTF-8 when read and when written, for a `string`.
  string: function(number: integer, options?: Options): Entry
  --- An enum, by its codec.
  enum: function<E>(number: integer, codec: Enum<E>, options?: Options): Entry
  --- An embedded message, by its codec.
  message: function<T>(number: integer, codec: Codec<T>, options?: Options): Entry
  --- An embedded message of the record the call is for: a message that holds itself.
  self: function(number: integer, options?: Options): Entry

  --- What the generated code calls.
  build: Build
end

local LEN <const> = Protobuf.LEN

--- A failure of the field `field`, numbered `number`: its path and why.
local function trouble(field: string, number: integer, why: string): string
  return (".%s (field %d): %s"):format(field, number, why)
end

--- A wire codec's failure without the module's name, which the root's failure carries once.
local function bare(why: string): string
  return (why:gsub("^protobuf: ", ""))
end

local function fail(r: Schema.Reading, field: string, number: integer, why: string)
  if r.bad == "" then r.bad = trouble(field, number, why) end
end

--- A failure the wire codec answered for the field.
local function fail_wire(r: Schema.Reading, field: string, number: integer, why: string)
  fail(r, field, number, bare(why))
end

--- A failure below the field `field`, which may be an element (`tracks[2]`): `inner` is what the read of the
--- message it holds answered, a path from that message and why.
local function fail_below(r: Schema.Reading, field: string, inner: string)
  if r.bad == "" then r.bad = "." .. field .. inner end
end

--- The bits of [`Protobuf.Message`]'s `wires` that fit a number whose entry of a plan's `wires` is `wire`.
local function fitting(wire: integer): integer
  local bits = 1 << (wire & 7)
  if wire >= 8 then bits = bits | (1 << LEN) end
  return bits
end

local MISFIT <const> = "it has another wire type than its encoding"

local function plan(wires: {integer: integer}, names: {integer: string}): Schema.Plan
  local numbers: mut {integer} = {}
  for number in pairs(wires) do numbers[#numbers + 1] = number end
  table.sort(numbers)
  return {
    wires = wires, names = names, numbers = numbers,
    strange = function(number: integer, wire: integer): boolean
      local named = wires[number]
      return named == nil or (1 << wire) & fitting(named) == 0
    end,
  }
end

local function open(message: Protobuf.Message, planned: Schema.Plan,
                    enums: {integer: function(integer): boolean}, keeps: boolean): Schema.Reading
  local unknown: mut {Protobuf.Field} = {}
  local held: mut {Protobuf.Field} = {}
  local wires = planned.wires
  local bad = ""
  if keeps then
    for _, f in ipairs(message:fields(planned.strange)) do
      if wires[f.number] == nil then
        unknown[#unknown + 1] = f
      else
        held[#held + 1] = f
      end
    end
    -- An enum's number is its last varint, which is what a read of the field takes: an earlier one a later
    -- field replaced is not what the message says, and holding it would bring it back.
    for _, number in ipairs(planned.numbers) do
      local named = enums[number]
      if named ~= nil then
        local value = message:int(number)
        if value ~= nil and not named(value) then
          held[#held + 1] = { number = number, wire = Protobuf.VARINT, value = value }
        end
      end
    end
  else
    for _, number in ipairs(planned.numbers) do
      local there = message:wires(number)
      if there & ~fitting(assert(wires[number])) ~= 0 then
        bad = trouble(assert(planned.names[number]), number, MISFIT)
        break
      end
    end
  end
  return { message = message, keeps = keeps, unknown = unknown, held = held, bad = bad }
end

--- Why a required field has no value: none of its number is there, or those that are have another wire type,
--- which a record that keeps has set aside.
local function absent(r: Schema.Reading, number: integer): string
  if r.message:wires(number) == 0 then return "missing" end
  return MISFIT
end

local function need<V>(r: Schema.Reading, number: integer, field: string, value: V?, zero: V): V
  if value ~= nil then return value end
  fail(r, field, number, absent(r, number))
  return zero
end

local function text(r: Schema.Reading, number: integer, field: string): string?
  local m = r.message
  local value = m:string(number)
  if value == nil and m:bytes(number) ~= nil then fail(r, field, number, "not UTF-8") end
  return value
end

--- Whether the number has a length-delimited field, which an embedded message is.
local function embedded(r: Schema.Reading, number: integer): boolean
  return r.message:wires(number) & (1 << LEN) ~= 0
end

local function message<T>(r: Schema.Reading, number: integer, field: string,
                          read: function(Protobuf.Message): T?, string): T?
  if not embedded(r, number) then return nil end
  local inner, why = r.message:message(number)
  if inner == nil then
    fail_wire(r, field, number, why)
    return nil
  end
  local value, bad = read(inner)
  if value == nil then fail_below(r, field, bad) end
  return value
end

local function list<V>(r: Schema.Reading, number: integer, field: string, values: {V}?, why: string): {V}
  if values == nil then
    fail_wire(r, field, number, why)
    return {}
  end
  return values
end

local function integers(r: Schema.Reading, number: integer, field: string, kind: string): {integer}
  local m = r.message
  local values, why: {integer}?, string
  if kind == "sint" then
    values, why = m:repeated_sint(number)
  elseif kind == "fixed32" then
    values, why = m:repeated_fixed32(number)
  elseif kind == "sfixed32" then
    values, why = m:repeated_sfixed32(number)
  elseif kind == "fixed64" or kind == "sfixed64" then
    values, why = m:repeated_fixed64(number)
  else
    values, why = m:repeated_int(number)
  end
  return list(r, number, field, values, why)
end

local function numbers(r: Schema.Reading, number: integer, field: string, kind: string): {number}
  local m = r.message
  local values, why: {number}?, string
  if kind == "float" then
    values, why = m:repeated_float(number)
  else
    values, why = m:repeated_double(number)
  end
  return list(r, number, field, values, why)
end

local function all_bytes(r: Schema.Reading, number: integer, field: string): {string}
  return list(r, number, field, r.message:repeated_bytes(number), "")
end

local function need_enum<E>(r: Schema.Reading, number: integer, field: string, named: E?, first: E): E
  if named ~= nil then return named end
  local raw = r.message:int(number)
  if raw ~= nil then
    fail(r, field, number, ("the enum names no number %d"):format(raw))
  else
    fail(r, field, number, absent(r, number))
  end
  return first
end

local function or_zero<V>(value: V?, zero: V): V
  if value ~= nil then return value end
  return zero
end

local function missing(r: Schema.Reading, number: integer, field: string): string
  if r.bad ~= "" then return r.bad end
  return trouble(field, number, absent(r, number))
end

local function bools(r: Schema.Reading, number: integer, field: string): {boolean}
  local values, why = r.message:repeated_int(number)
  local out: mut {boolean} = {}
  for _, value in ipairs(list(r, number, field, values, why)) do
    out[#out + 1] = value ~= 0
  end
  return out
end

local function texts(r: Schema.Reading, number: integer, field: string): {string}
  local values = r.message:repeated_bytes(number)
  for i, value in ipairs(values) do
    if utf8.len(value) == nil then
      if r.bad == "" then r.bad = (".%s[%d] (field %d): not UTF-8"):format(field, i, number) end
      return {}
    end
  end
  return list(r, number, field, values, "")
end

local function enums<E>(r: Schema.Reading, number: integer, field: string, name: function(integer?): E?): {E}
  local values, why = r.message:repeated_int(number)
  local out: mut {E} = {}
  for _, value in ipairs(list(r, number, field, values, why)) do
    local named = name(value)
    if named ~= nil then out[#out + 1] = named end
  end
  return out
end

local function messages<T>(r: Schema.Reading, number: integer, field: string,
                           read: function(Protobuf.Message): T?, string): {T}
  local out: mut {T} = {}
  local inner, why = r.message:repeated_message(number)
  for i, each in ipairs(list(r, number, field, inner, why)) do
    local value, bad = read(each)
    if value == nil then
      fail_below(r, ("%s[%d]"):format(field, i), bad)
      return {}
    end
    out[#out + 1] = value
  end
  return out
end

local function some<V>(values: {V}): {V}?
  if #values == 0 then return nil end
  return values
end

local function unknown(r: Schema.Reading): Schema.Unknown?
  if #r.unknown == 0 and #r.held == 0 then return nil end
  return { fields = r.unknown, held = r.held }
end

local function done<T>(r: Schema.Reading, value: T): T?, string
  if r.bad ~= "" then return nil, r.bad end
  return value, ""
end

local function writer(): Schema.Writing
  return { writer = Protobuf.writer(), bad = "" }
end

local function put_int(w: Schema.Writing, number: integer, value: integer?)
  if value ~= nil then w.writer:int(number, value) end
end

local function put_sint(w: Schema.Writing, number: integer, value: integer?)
  if value ~= nil then w.writer:sint(number, value) end
end

local function put_bool(w: Schema.Writing, number: integer, value: boolean?)
  if value ~= nil then w.writer:bool(number, value) end
end

--- The wire codec's `fixed32` takes a `fixed32` or an `sfixed32`, so the range of each is held here.
local function ranged(w: Schema.Writing, number: integer, value: integer, least: integer, most: integer): boolean
  if value >= least and value <= most then return true end
  if w.bad == "" then
    w.bad = (": field %d: %d is outside %d to %d"):format(number, value, least, most)
  end
  return false
end

local function put_fixed32(w: Schema.Writing, number: integer, value: integer?)
  if value ~= nil and ranged(w, number, value, 0, 4294967295) then
    w.writer:fixed32(number, value)
  end
end

local function put_sfixed32(w: Schema.Writing, number: integer, value: integer?)
  if value ~= nil and ranged(w, number, value, -2147483648, 2147483647) then
    w.writer:fixed32(number, value)
  end
end

local function put_fixed64(w: Schema.Writing, number: integer, value: integer?)
  if value ~= nil then w.writer:fixed64(number, value) end
end

local function put_float(w: Schema.Writing, number: integer, value: number?)
  if value ~= nil then w.writer:float(number, value) end
end

local function put_double(w: Schema.Writing, number: integer, value: number?)
  if value ~= nil then w.writer:double(number, value) end
end

local function put_bytes(w: Schema.Writing, number: integer, value: string?)
  if value ~= nil then w.writer:bytes(number, value) end
end

local function put_string(w: Schema.Writing, number: integer, value: string?)
  if value ~= nil then w.writer:string(number, value) end
end

local function put_enum<E>(w: Schema.Writing, number: integer, value: E?, number_of: function(E): integer)
  if value ~= nil then w.writer:int(number, number_of(value)) end
end

--- The bytes of an embedded message go in as a field's bytes: what a record keeps is written after its known
--- fields as bytes, which a [`Protobuf.Writer`] given as a child cannot take.
--
-- TODO: write an embedded message of a record that keeps nothing through a child writer, with no copy of its
-- bytes, once a converted program shows that encoding's cost matters: it is 1.1 to 1.6 times a hand-written
-- writer's on the wire codec.
local function put_one<T>(w: Schema.Writing, number: integer, field: string, value: T,
                          write: function(T): string?, string)
  local bytes, why = write(value)
  if bytes == nil then
    if w.bad == "" then w.bad = "." .. field .. why end
    return
  end
  w.writer:bytes(number, bytes)
end

local function put_message<T>(w: Schema.Writing, number: integer, field: string, value: T?,
                              write: function(T): string?, string)
  if value ~= nil then put_one(w, number, field, value, write) end
end

--- How [`Protobuf.Writer`]'s `packed` names each kind of number.
local PACKS <const>: {string: Protobuf.Kind} = {
  int = "int", sint = "sint", fixed32 = "fixed32", sfixed32 = "fixed32", fixed64 = "fixed64", sfixed64 = "fixed64",
  float = "float", double = "double",
}

local function put_numbers(w: Schema.Writing, number: integer, kind: string, values: {number}?, packed: boolean)
  if values == nil then return end
  local out = w.writer
  if kind == "double" or kind == "float" then
    if packed then
      out:packed(number, if kind == "double" then "double" else "float" end, values)
      return
    end
    for _, value in ipairs(values) do
      if kind == "double" then
        out:double(number, value)
      else
        out:float(number, value)
      end
    end
    return
  end
  for _, value in ipairs(values) do
    local whole = math.tointeger(value)
    if whole == nil then
      if w.bad == "" then
        w.bad = (": field %d: %s is no integer"):format(number, tostring(value))
      end
      return
    end
    if kind == "fixed32" and not ranged(w, number, whole, 0, 4294967295) then return end
    if kind == "sfixed32" and not ranged(w, number, whole, -2147483648, 2147483647) then return end
    if not packed then
      if kind == "int" then
        out:int(number, whole)
      elseif kind == "sint" then
        out:sint(number, whole)
      elseif kind == "fixed32" or kind == "sfixed32" then
        out:fixed32(number, whole)
      else
        out:fixed64(number, whole)
      end
    end
  end
  if packed then
    out:packed(number, assert(PACKS[kind], "the build names a kind of number"), values)
  end
end

local function put_bools(w: Schema.Writing, number: integer, values: {boolean}?, packed: boolean)
  if values == nil then return end
  if packed then
    local bits: mut {number} = {}
    for _, value in ipairs(values) do
      bits[#bits + 1] = if value then 1 else 0 end
    end
    w.writer:packed(number, "int", bits)
    return
  end
  for _, value in ipairs(values) do w.writer:bool(number, value) end
end

local function put_all_bytes(w: Schema.Writing, number: integer, values: {string}?)
  if values == nil then return end
  for _, value in ipairs(values) do w.writer:bytes(number, value) end
end

local function put_all_strings(w: Schema.Writing, number: integer, values: {string}?)
  if values == nil then return end
  for _, value in ipairs(values) do w.writer:string(number, value) end
end

local function put_enums<E>(w: Schema.Writing, number: integer, values: {E}?, number_of: function(E): integer,
                            packed: boolean)
  if values == nil then return end
  if packed then
    local each: mut {number} = {}
    for _, value in ipairs(values) do
      local n = number_of(value)
      each[#each + 1] = n
    end
    w.writer:packed(number, "int", each)
    return
  end
  for _, value in ipairs(values) do w.writer:int(number, number_of(value)) end
end

local function put_messages<T>(w: Schema.Writing, number: integer, field: string, values: {T}?,
                               write: function(T): string?, string)
  if values == nil then return end
  for i, value in ipairs(values) do
    put_one(w, number, ("%s[%d]"):format(field, i), value, write)
  end
end

local function close(w: Schema.Writing, kept?: Schema.Unknown, present?: {integer: boolean}): string?, string
  if w.bad ~= "" then return nil, w.bad end
  local bytes, why = w.writer:encode()
  if bytes == nil then return nil, ": " .. bare(why) end
  if kept == nil then return bytes, "" end
  local rest: mut {Protobuf.Field} = {}
  -- `present` has every number the record names. An unknown field of one, which only a hand-built [`Unknown`]
  -- holds, is left out: written after the field, a reader would take it over the field's value.
  for _, f in ipairs(kept.fields) do
    if present == nil or present[f.number] == nil then rest[#rest + 1] = f end
  end
  for _, f in ipairs(kept.held) do
    if present == nil or present[f.number] ~= true then rest[#rest + 1] = f end
  end
  local tail, tail_why = Protobuf.encode(rest)
  if tail == nil then return nil, ": " .. bare(tail_why) end
  return bytes .. tail, ""
end

local BUILD: Schema.Build = {
  plan = plan, open = open, need = need, text = text, message = message, need_enum = need_enum, or_zero = or_zero,
  missing = missing, integers = integers, numbers = numbers, all_bytes = all_bytes, bools = bools, texts = texts,
  enums = enums, messages = messages, some = some, unknown = unknown, done = done, writer = writer,
  put_int = put_int, put_sint = put_sint, put_bool = put_bool, put_fixed32 = put_fixed32, put_sfixed32 = put_sfixed32,
  put_fixed64 = put_fixed64, put_float = put_float, put_double = put_double, put_bytes = put_bytes,
  put_string = put_string, put_enum = put_enum, put_message = put_message, put_numbers = put_numbers,
  put_bools = put_bools, put_all_bytes = put_all_bytes, put_all_strings = put_all_strings, put_enums = put_enums,
  put_messages = put_messages, close = close,
}

local UNRESOLVED <const> = "schema: %s(%q) was not resolved: the build writes a codec from a call written as " ..
  "Schema.%s(\"Name\", { ... }) in a module it compiles, so an aliased or computed call, a chunk loaded by hand " ..
  "and the Lua `cosmic compile` writes have none for it; call it directly, in a module the build compiles"

local function enum_of<E>(name: string, _numbers: {string: integer}, name_of?: function(integer?): E?,
                          number_of?: function(E): integer): Schema.Enum<E>
  if name_of == nil or number_of == nil then
    error(UNRESOLVED:format("enum_of", name, "enum_of"), 2)
  end
  return { name = name_of, number = number_of }
end

local function codec_encode<T>(self: Schema.Codec<T>, value: T): string?, string
  local bytes, why = self.write(value)
  if bytes == nil then return nil, "protobuf: " .. self.name .. why end
  return bytes, ""
end

local function codec_decode<T>(self: Schema.Codec<T>, bytes: string, opts?: Protobuf.Options): T?, string
  local decoded, why = Protobuf.decode(bytes, opts)
  if decoded == nil then return nil, "protobuf: " .. self.name .. ": " .. bare(why) end
  local value, bad = self.read(decoded)
  if value == nil then return nil, "protobuf: " .. self.name .. bad end
  return value, ""
end

local function message_of<T>(name: string, _fields: {string: integer | Schema.Entry},
                             write?: function(T): string?, string,
                             read?: function(Protobuf.Message): T?, string): Schema.Codec<T>
  if write == nil or read == nil then
    error(UNRESOLVED:format("message_of", name, "message_of"), 2)
  end
  return { name = name, encode = codec_encode, decode = codec_decode, read = read, write = write }
end

local function entry(number: integer, _options?: Schema.Options): Schema.Entry
  return { number = number }
end

local function enum_entry<E>(number: integer, _codec: Schema.Enum<E>, _options?: Schema.Options): Schema.Entry
  return { number = number }
end

local function message_entry<T>(number: integer, _codec: Schema.Codec<T>, _options?: Schema.Options): Schema.Entry
  return { number = number }
end

local schema: Schema = {
  enum_of = enum_of, message_of = message_of, field = entry, sint = entry, fixed32 = entry, fixed64 = entry,
  sfixed32 = entry, sfixed64 = entry, float = entry, string = entry, enum = enum_entry, message = message_entry,
  self = entry, build = BUILD,
}

return schema
