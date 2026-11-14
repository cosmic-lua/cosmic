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

  --- What a packed field holds, for `packed`: named as the method that writes one such value. One of
  --- `"int"`, `"sint"`, `"fixed32"`, `"fixed64"`, `"float"`, `"double"`.
  type Kind = Raw.Kind

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
  --- after those before it and answers the writer, so calls chain. None raises for a field it cannot write: the first field that cannot be
  --- written (a number that is no field's, a value past its type) is why `encode` fails, and the fields after
  --- it are not written.
  ---
  --- `int(number, value)`: A varint field: an `int32`, `int64`, `uint32`, `uint64` or an `enum`. A negative value
  --- is ten bytes.
  ---
  --- `sint(number, value)`: A varint field with its sign in the low bit, as `sint32` and `sint64` are: a small
  --- negative value is a short one.
  ---
  --- `bool(number, value)`: A `bool`: the varint 1 or 0.
  ---
  --- `fixed32(number, value)`: A 4-byte field, a `fixed32` or `sfixed32`: `value` is from -2147483648 to
  --- 4294967295.
  ---
  --- `fixed64(number, value)`: An 8-byte field, a `fixed64` or `sfixed64`.
  ---
  --- `float(number, value)`: A `float`: `value` rounded to the nearest single, which for one past them all is the
  --- infinity of its sign. A NaN is the bytes `00 00 c0 7f` whatever its sign and payload.
  ---
  --- `double(number, value)`: A `double`. A NaN is the bytes `00 00 00 00 00 00 f8 7f` whatever its sign and
  --- payload.
  ---
  --- `bytes(number, value)`: A length-delimited field of any bytes.
  ---
  --- `string(number, value)`: A `string`: as `bytes`, and `value` must be UTF-8.
  ---
  --- `message(number, child)`: An embedded message: the fields `child` holds now. Writing more to `child`
  --- afterwards changes nothing here. A `child` that cannot be encoded is why this writer cannot.
  ---
  --- `packed(number, kind, values)`: A packed repeated field: every value in one length-delimited field, each
  --- written as `kind` writes one. An empty list writes no field, as the format has it. A value of an integer
  --- kind that is no integer, or past its kind, cannot be written. A `bool` is packed as the "int" 1 or 0.
  ---
  --- `encode()`: The bytes of the fields written so far, or nil and why the first that could not be written could
  --- not. It may be called again after more fields. Two messages' bytes joined are the bytes of the two merged.
  type Writer = Raw.Writer

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

--- The 4 bytes of `value`, or nil and why it is past them.
local function fixed32_bytes(number: integer, value: integer): string?, string
  if value < -0x80000000 or value > 0xffffffff then
    return nil, ("protobuf: field %d: %d does not fit 32 bits"):format(number, value)
  end
  return string.pack("<I4", value & 0xffffffff), ""
end

--- A writer of a message with no fields yet.
function Protobuf.writer(): Protobuf.Writer
  return Raw.writer()
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
