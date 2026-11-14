--- The Protocol Buffers wire format, read and written with no schema. A message on the wire is a list of fields,
--- each a number, a wire type and a value. What a field means is not on the wire, so the caller says it: a
--- [`Protobuf.Message`] is read through a method for each type (`int`, `sint`, `double`, `string`, `message`),
--- and a [`Protobuf.Writer`] has a method of the same name to write one.
---
--- [`Protobuf.decode`] reads the fields of a message and [`Protobuf.writer`] builds the bytes of one.
--- [`Protobuf.encode`] writes a list of fields as they were read, for the fields a program passes on without
--- knowing them. [`Protobuf.varint`] and [`Protobuf.read_varint`] are the format's integer alone, which also
--- frames the messages of a stream.
---
--- The four wire types and the types of a `.proto` file each holds:
---
--- - [`Protobuf.VARINT`]: `int32`, `int64`, `uint32`, `uint64`, `bool` and an `enum` (read with `int`, or
---   `bool`), and `sint32` and `sint64` (read with `sint`).
--- - [`Protobuf.FIXED64`]: `fixed64` and `sfixed64` (`fixed64`) and `double`.
--- - [`Protobuf.LEN`]: `string`, `bytes`, an embedded message, and a packed repeated field.
--- - [`Protobuf.FIXED32`]: `fixed32`, `sfixed32` and `float`.
---
--- An integer is 64 bits. A `uint64` or `fixed64` above 9223372036854775807 is the negative integer of the same
--- bits, which `math.ult` compares and `("%x"):format` prints as the unsigned one. A negative `int32` is ten
--- bytes on the wire, as the format has it, and reads back negative.
---
--- A message is read by the format's rules for a field that comes more than once. A read of one value answers
--- the last. `message` answers the embedded messages of that number merged, as one message of all their fields.
--- A `repeated_` read answers every value in order, and takes a packed field, an unpacked one, or both. A field
--- of another wire type than the read asks for is not that field: the read passes over it. Every field stays in
--- the message, known to the caller or not, and `fields` lists them.
---
--- [`Protobuf.decode`] takes bytes from anywhere. It never raises and reads no byte outside what it was given.
--- It refuses the whole message, with nil and why, for a varint of more than 64 bits, a field number of 0 or
--- above 536870911, a length that passes the end, a value the bytes end inside, the wire types the
--- format does not have (6 and 7), and a group (wire types 3 and 4, which only proto2 writes). A varint written
--- in more bytes than it needs is read as its value. One whose tenth byte holds more than the 64th bit is
--- refused, where the reference implementations drop the bits past it: the bytes are read by nanopb, in the
--- core, and that is its rule. A decode holds [`Protobuf.Options`]' `max_fields` fields at most
--- and messages nest `max_depth` deep at most: past either, the answer is nil and why. A decode costs time and
--- memory in proportion to the bytes and copies none of them: an embedded message is read in place when it is
--- asked for.

local Raw = require("cosmic.internal.protobuf")

local record Protobuf
  --- One field as it is on the wire: `number`, the field's number from 1 to 536870911; `wire`, its wire type
  --- ([`Protobuf.VARINT`], [`Protobuf.FIXED64`], [`Protobuf.LEN`] or [`Protobuf.FIXED32`]); and `value`, the
  --- bytes of a [`Protobuf.LEN`] field and the integer of any other. A [`Protobuf.FIXED32`] is from 0 to
  --- 4294967295; [`Protobuf.encode`] also takes one from -2147483648.
  type Field = Raw.Field

  --- What [`Protobuf.decode`] may be told. Every field is optional.
  record Options
    --- How deep messages may nest, the decoded one counted, 1 or more (default [`Protobuf.default_depth`],
    --- 100). At that depth `message` and `repeated_message` answer nil and why.
    max_depth?: integer
    --- How many fields one message may hold, 1 or more (default [`Protobuf.default_fields`], 65536). A message
    --- of more is refused whole, as is an embedded one when it is asked for, which counts the fields of
    --- every part merged into it. The elements of a packed field are not counted: a `repeated_` read
    --- answers one for each byte of the field at most.
    max_fields?: integer
  end

  --- What a packed field holds, for `packed`: named as the method that writes one such value.
  enum Kind
    "int"
    "sint"
    "fixed32"
    "fixed64"
    "float"
    "double"
  end

  --- A varint that was read, from [`Protobuf.read_varint`]: `value`, the integer, and `next`, the position of
  --- the byte after it.
  type Varint = Raw.Varint

  --- The fields of a message that was read, from [`Protobuf.decode`]. No method raises or changes it. Every
  --- method but `fields` and `has` takes a field's number and reads the fields of that number whose wire type
  --- is the one it asks for.
  ---
  --- `fields(keep?)`: Every field, in the order of the bytes, the unknown ones too. An embedded message is its
  --- bytes. With `keep`, the fields it answers true for, by number and wire type: the bytes of the others are not
  --- copied, which is how a program takes the fields it does not know from a message it has read the rest of.
  ---
  --- `has(number)`: Whether any field has this number, of any wire type.
  ---
  --- `wires(number)`: The wire types of the fields of this number, a bit for each: `1 << Protobuf.LEN` is set
  --- where one is length-delimited. 0 where no field has the number. A read by number passes over a field of
  --- another wire type than it asks for, and this says that there is one.
  ---
  --- `int(number)`: The last varint of that number as an `int32`, `int64`, `uint32`, `uint64` or an `enum`, or
  --- nil. It is the 64 bits of the varint: nothing is cut to 32.
  ---
  --- `sint(number)`: The last varint of that number as a `sint32` or `sint64`, whose sign is in its low bit, or
  --- nil.
  ---
  --- `bool(number)`: The last varint of that number as a `bool`, true unless it is 0, or nil.
  ---
  --- `fixed32(number)`: The last 4-byte field of that number as a `fixed32`, from 0 to 4294967295, or nil.
  ---
  --- `sfixed32(number)`: The last 4-byte field of that number as an `sfixed32`, from -2147483648 to 2147483647,
  --- or nil.
  ---
  --- `fixed64(number)`: The last 8-byte field of that number as a `fixed64` or `sfixed64`, or nil.
  ---
  --- `float(number)`: The last 4-byte field of that number as a `float`, or nil.
  ---
  --- `double(number)`: The last 8-byte field of that number as a `double`, or nil.
  ---
  --- `bytes(number)`: The bytes of the last length-delimited field of that number, or nil.
  ---
  --- `string(number)`: As `bytes`, where they are UTF-8, which a `string` holds. Nil where they are not, as where
  --- there is no such field: `bytes` tells the two apart.
  ---
  --- `message(number)`: The embedded message of that number: every length-delimited field of the number read as a
  --- message, and their fields merged in order. With no such field it is a message of no fields. Nil and why
  --- where the bytes are no message, where the fields pass `max_fields`, or where this message is `max_depth`
  --- deep. Each call reads the fields again, so a caller that needs the message twice keeps it.
  ---
  --- `repeated_int(number)`: Every `int` of that number in order, packed or not; an empty list where there is
  --- none. Nil and why where a packed field ends inside a varint or holds one that is malformed.
  ---
  --- `repeated_sint(number)`: Every `sint` of that number, as `repeated_int`.
  ---
  --- `repeated_fixed32(number)`: Every `fixed32` of that number in order, packed or not. Nil and why where a
  --- packed field's length is no multiple of 4.
  ---
  --- `repeated_sfixed32(number)`: Every `sfixed32` of that number, as `repeated_fixed32`.
  ---
  --- `repeated_fixed64(number)`: Every `fixed64` of that number in order, packed or not. Nil and why where a
  --- packed field's length is no multiple of 8.
  ---
  --- `repeated_float(number)`: Every `float` of that number, as `repeated_fixed32`.
  ---
  --- `repeated_double(number)`: Every `double` of that number, as `repeated_fixed64`.
  ---
  --- `repeated_bytes(number)`: The bytes of every length-delimited field of that number in order: a repeated
  --- `bytes` or `string`.
  ---
  --- `repeated_message(number)`: Every embedded message of that number in order, each by itself and none merged.
  --- Nil and why as `message` fails, for the first that does.
  type Message = Raw.Message

  --- The bytes of a message being written, from [`Protobuf.writer`]. Each method but `encode` writes one field
  --- after those before it and answers the writer, so calls chain. None raises: the first field that cannot be
  --- written (a number that is no field's, a value past its type) is why `encode` fails, and the fields after
  --- it are not written.
  interface Writer
    --- A varint field: an `int32`, `int64`, `uint32`, `uint64` or an `enum`. A negative value is ten bytes.
    int: function(self: Writer, number: integer, value: integer): Writer
    --- A varint field with its sign in the low bit, as `sint32` and `sint64` are: a small negative value
    --- is a short one.
    sint: function(self: Writer, number: integer, value: integer): Writer
    --- A `bool`: the varint 1 or 0.
    bool: function(self: Writer, number: integer, value: boolean): Writer
    --- A 4-byte field, a `fixed32` or `sfixed32`: `value` is from -2147483648 to 4294967295.
    fixed32: function(self: Writer, number: integer, value: integer): Writer
    --- An 8-byte field, a `fixed64` or `sfixed64`.
    fixed64: function(self: Writer, number: integer, value: integer): Writer
    --- A `float`: `value` rounded to the nearest single, which for one past them all is the infinity of its
    --- sign. A NaN is the bytes `00 00 c0 7f` whatever its sign and payload.
    float: function(self: Writer, number: integer, value: number): Writer
    --- A `double`. A NaN is the bytes `00 00 00 00 00 00 f8 7f` whatever its sign and payload.
    double: function(self: Writer, number: integer, value: number): Writer
    --- A length-delimited field of any bytes.
    bytes: function(self: Writer, number: integer, value: string): Writer
    --- A `string`: as `bytes`, and `value` must be UTF-8.
    string: function(self: Writer, number: integer, value: string): Writer
    --- An embedded message: the fields `child` holds now. Writing more to `child` afterwards changes
    --- nothing here. A `child` that cannot be encoded is why this writer cannot.
    message: function(self: Writer, number: integer, child: Writer): Writer
    --- A packed repeated field: every value in one length-delimited field, each written as `kind` writes
    --- one. An empty list writes no field, as the format has it. A value of an integer kind that is no
    --- integer, or past its kind, cannot be written. A `bool` is packed as the "int" 1 or 0.
    packed: function(self: Writer, number: integer, kind: Kind, values: {number}): Writer
    --- The bytes of the fields written so far, or nil and why the first that could not be written could
    --- not. It may be called again after more fields. Two messages' bytes joined are the bytes of the two
    --- merged.
    encode: function(self: Writer): string?, string
  end

  --- The wire type of a varint: an integer in 1 to 10 bytes, 7 bits in each, the low ones first.
  VARINT: integer
  --- The wire type of 8 bytes, the low one first.
  FIXED64: integer
  --- The wire type of a length, as a varint, and that many bytes.
  LEN: integer
  --- The wire type of 4 bytes, the low one first.
  FIXED32: integer
  --- The `max_depth` of a decode that is given none: what the reference implementations allow.
  default_depth: integer
  --- The `max_fields` of a decode that is given none.
  default_fields: integer
end

Protobuf.VARINT = 0
Protobuf.FIXED64 = 1
Protobuf.LEN = 2
Protobuf.FIXED32 = 5
Protobuf.default_depth = 100
Protobuf.default_fields = 65536

local VARINT <const> = 0
local FIXED64 <const> = 1
local LEN <const> = 2
local FIXED32 <const> = 5

--- The greatest field number: a tag is 32 bits, and the low 3 are the wire type.
local MAX_NUMBER <const> = 536870911

--- The greatest single.
local MAX_FLOAT <const> = 3.4028234663852886e+38

--- Half way from the greatest single to the next power of two, 2^128 - 2^103: a double below it rounds to the
--- greatest single, and one from it up to no single.
local FLOAT_OVERFLOW <const> = 3.4028235677973366e+38

--- `value` as a varint.
local function varint_bytes(value: integer): string
  if value >= 0 and value < 0x80 then return string.char(value) end
  local out: mut {string} = {}
  local rest = value
  while rest < 0 or rest >= 0x80 do
    out[#out + 1] = string.char(rest & 0x7f | 0x80)
    rest = rest >> 7
  end
  out[#out + 1] = string.char(rest)
  return table.concat(out)
end

local function zigzag(value: integer): integer
  return value << 1 ~ (if value < 0 then -1 else 0 end)
end

--- A bound of a decode: `given`, or `default` where it is nil. Raises for one that is no integer of 1 or more,
--- which is the caller's mistake and none of the bytes'.
local function bound(name: string, given: integer?, default: integer): integer
  if given == nil then return default end
  if math.type(given) ~= "integer" or given < 1 then
    error(("protobuf: %s must be an integer of 1 or more"):format(name), 3)
  end
  return given
end

--- The message in the bytes `data`, which may come from anywhere, or nil and why they are no message or hold
--- more than `max_fields` fields. It never raises for any bytes; it raises for an option that is no integer of
--- 1 or more. Only the fields of this message are read: an embedded one is read when `message` asks for it.
--- Empty bytes are a message of no fields.
function Protobuf.decode(data: string, opts?: Protobuf.Options): Protobuf.Message?, string
  local o: Protobuf.Options = opts or {}
  local max_depth = bound("max_depth", o.max_depth, Protobuf.default_depth)
  local max_fields = bound("max_fields", o.max_fields, Protobuf.default_fields)
  return Raw.decode(data, max_depth, max_fields)
end

--- Why `number` is no field's, or "".
local function number_trouble(number: integer): string
  if math.type(number) == "integer" and number >= 1 and number <= MAX_NUMBER then return "" end
  return ("protobuf: %s is no field number (1 to %d)"):format(tostring(number), MAX_NUMBER)
end

local function double_bytes(value: number): string
  if value ~= value then return "\x00\x00\x00\x00\x00\x00\xf8\x7f" end
  return string.pack("<d", value)
end

--- The 4 bytes of `value`, or nil and why it is past them.
local function fixed32_bytes(number: integer, value: integer): string?, string
  if value < -0x80000000 or value > 0xffffffff then
    return nil, ("protobuf: field %d: %d does not fit 32 bits"):format(number, value)
  end
  return string.pack("<I4", value & 0xffffffff), ""
end

--- A NaN is written as one quiet NaN, whatever its sign and payload: the bytes of `0/0` differ between
--- processors.
local function float_bytes(value: number): string
  if value ~= value then return "\x00\x00\xc0\x7f" end
  -- `string.pack` converts as C does, which leaves a double past the greatest single undefined, so those are
  -- rounded here.
  local single = value
  if single >= FLOAT_OVERFLOW then
    single = math.huge
  elseif single <= -FLOAT_OVERFLOW then
    single = -math.huge
  elseif single > MAX_FLOAT then
    single = MAX_FLOAT
  elseif single < -MAX_FLOAT then
    single = -MAX_FLOAT
  end
  return string.pack("<f", single)
end

--- Writes a field of that wire type whose value on the wire is `body` to `parts`, and answers the writer's
--- trouble after it: `trouble` where that is one already, `why` where there is no body, and the reason `number`
--- is no field's. "" where the field was written.
local function added(parts: mut {string}, trouble: string, number: integer, wire: integer, body: string?,
                     why: string): string
  if trouble ~= "" then return trouble end
  if body == nil then return why end
  local refused = number_trouble(number)
  if refused ~= "" then return refused end
  local tag = varint_bytes(number << 3 | wire)
  parts[#parts + 1] = tag
  local value = if wire == LEN then varint_bytes(#body) .. body else body end
  parts[#parts + 1] = value
  return ""
end

--- The bytes of one value of a packed field, or nil and why it is not of `kind`.
local function packed_bytes(number: integer, kind: Protobuf.Kind, value: number): string?, string
  if kind == "float" then return float_bytes(value), "" end
  if kind == "double" then return double_bytes(value), "" end
  local whole = math.tointeger(value)
  if whole == nil then
    return nil, ("protobuf: field %d: %s is no integer"):format(number, tostring(value))
  end
  if kind == "int" then return varint_bytes(whole), "" end
  if kind == "sint" then return varint_bytes(zigzag(whole)), "" end
  if kind == "fixed64" then return string.pack("<i8", whole), "" end
  return fixed32_bytes(number, whole)
end

local class Building is Protobuf.Writer
  parts: mut {string}
  --- Why the first field that could not be written could not, or "". Nothing is written after it.
  mut trouble: string

  function int(self, number: integer, value: integer): Protobuf.Writer
    self.trouble = added(self.parts, self.trouble, number, VARINT, varint_bytes(value), "")
    return self
  end

  function sint(self, number: integer, value: integer): Protobuf.Writer
    self.trouble = added(self.parts, self.trouble, number, VARINT, varint_bytes(zigzag(value)), "")
    return self
  end

  function bool(self, number: integer, value: boolean): Protobuf.Writer
    self.trouble = added(self.parts, self.trouble, number, VARINT, if value then "\1" else "\0" end, "")
    return self
  end

  function fixed32(self, number: integer, value: integer): Protobuf.Writer
    local body, why = fixed32_bytes(number, value)
    self.trouble = added(self.parts, self.trouble, number, FIXED32, body, why)
    return self
  end

  function fixed64(self, number: integer, value: integer): Protobuf.Writer
    self.trouble = added(self.parts, self.trouble, number, FIXED64, string.pack("<i8", value), "")
    return self
  end

  function float(self, number: integer, value: number): Protobuf.Writer
    self.trouble = added(self.parts, self.trouble, number, FIXED32, float_bytes(value), "")
    return self
  end

  function double(self, number: integer, value: number): Protobuf.Writer
    self.trouble = added(self.parts, self.trouble, number, FIXED64, double_bytes(value), "")
    return self
  end

  function bytes(self, number: integer, value: string): Protobuf.Writer
    self.trouble = added(self.parts, self.trouble, number, LEN, value, "")
    return self
  end

  function string(self, number: integer, value: string): Protobuf.Writer
    if utf8.len(value) == nil then
      self.trouble = added(self.parts, self.trouble, number, LEN, nil,
        ("protobuf: field %d: a string that is not UTF-8"):format(number))
      return self
    end
    self.trouble = added(self.parts, self.trouble, number, LEN, value, "")
    return self
  end

  function message(self, number: integer, child: Protobuf.Writer): Protobuf.Writer
    local body, why = child:encode()
    self.trouble = added(self.parts, self.trouble, number, LEN, body, why)
    return self
  end

  function packed(self, number: integer, kind: Protobuf.Kind, values: {number}): Protobuf.Writer
    if #values == 0 then return self end
    local out: mut {string} = {}
    for _, value in ipairs(values) do
      local bytes, why = packed_bytes(number, kind, value)
      if bytes == nil then
        self.trouble = added(self.parts, self.trouble, number, LEN, nil, why)
        return self
      end
      out[#out + 1] = bytes
    end
    self.trouble = added(self.parts, self.trouble, number, LEN, table.concat(out), "")
    return self
  end

  function encode(self): string?, string
    if self.trouble ~= "" then return nil, self.trouble end
    return table.concat(self.parts), ""
  end
end

--- A writer of a message with no fields yet.
function Protobuf.writer(): Protobuf.Writer
  local writer: Building = { parts = {}, trouble = "" }
  return writer
end

--- The bytes of `fields`, in their order, or nil and why one cannot be written: a number that is no field's, a
--- wire type that is none of the four, or a value that is not what its wire type holds. What
--- [`Protobuf.decode`]'s `fields` lists is written as the same fields, each varint in the fewest bytes.
function Protobuf.encode(fields: {Protobuf.Field}): string?, string
  local out: mut {string} = {}
  for _, field in ipairs(fields) do
    local number, wire, value = field.number, field.wire, field.value
    local why = number_trouble(number)
    if why ~= "" then return nil, why end
    local body: string
    if value is string then
      if wire ~= LEN then
        return nil, ("protobuf: field %d: wire type %s holds no bytes"):format(number, tostring(wire))
      end
      body = varint_bytes(#value) .. value
    elseif wire == VARINT then
      body = varint_bytes(value)
    elseif wire == FIXED64 then
      body = string.pack("<i8", value)
    elseif wire == FIXED32 then
      local four, four_why = fixed32_bytes(number, value)
      if four == nil then return nil, four_why end
      body = four
    elseif wire == LEN then
      return nil, ("protobuf: field %d: a length-delimited field holds bytes, not an integer"):format(number)
    else
      return nil, ("protobuf: field %d: %s is no wire type"):format(number, tostring(wire))
    end
    out[#out + 1] = varint_bytes(number << 3 | wire)
    out[#out + 1] = body
  end
  return table.concat(out), ""
end

--- `value` as a varint, 1 to 10 bytes: the fewest that hold it, and ten for a negative one. Before a
--- message's bytes it is the length that frames them in a stream.
function Protobuf.varint(value: integer): string
  return varint_bytes(value)
end

--- The varint in `data` at the position `at` (default 1), and the position after it, or nil and why: the bytes
--- end inside it, or it holds more than 64 bits. It never raises. A failure with fewer than 10 bytes from `at`
--- on is always the first, so a reader of a stream then waits for more bytes. A length read from a peer is any
--- 64 bits, negative above 2^63 - 1: hold it to a limit before waiting for that many bytes.
function Protobuf.read_varint(data: string, at?: integer): Protobuf.Varint?, string
  local start = at or 1
  if math.type(start) ~= "integer" or start < 1 then
    return nil, ("protobuf: %s is no position"):format(tostring(start))
  end
  return Raw.read_varint(data, start)
end

return Protobuf
