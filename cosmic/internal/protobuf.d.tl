-- The Protocol Buffers wire format at the Lua boundary, as the core
-- reads it through nanopb: the bytes are indexed once, and each field is
-- answered by its number and type.
--- @kind binding

local record protobuf
  -- The types cosmic/protobuf/init.tl names Field, Varint, Message, Kind and Writer and documents, declared here because a
  -- declaration may require only declarations, and the userdata below must say what they are where they are declared.

  -- One field as it is on the wire.
  record Field
    -- The field's number, from 1 to 536870911.
    number: integer
    -- The wire type: [`Protobuf.VARINT`], [`Protobuf.FIXED64`], [`Protobuf.LEN`] or [`Protobuf.FIXED32`].
    wire: integer
    -- The value: the bytes of a [`Protobuf.LEN`] field, and the integer of any other. A [`Protobuf.FIXED32`]
    -- is from 0 to 4294967295; [`Protobuf.encode`] also takes one from -2147483648.
    value: integer | string
  end

  -- A varint that was read, from [`Protobuf.read_varint`].
  record Varint
    -- The integer.
    value: integer
    -- The position of the byte after it.
    next: integer
  end

  -- The fields of a message that was read, from [`Protobuf.decode`]. No method raises or changes it. Every
  -- method but `fields` and `has` takes a field's number and reads the fields of that number whose wire type
  -- is the one it asks for.
  interface Message
    -- Every field, in the order of the bytes, the unknown ones too. An embedded message is its bytes. With
    -- `keep`, the fields it answers true for, by number and wire type: the bytes of the others are not copied,
    -- which is how a program takes the fields it does not know from a message it has read the rest of.
    fields: function(self: Message, keep?: function(number: integer, wire: integer): boolean): {Field}
    -- Whether any field has this number, of any wire type.
    has: function(self: Message, number: integer): boolean
    -- The wire types of the fields of this number, a bit for each: `1 << Protobuf.LEN` is set where one is
    -- length-delimited. 0 where no field has the number. A read by number passes over a field of another wire
    -- type than it asks for, and this says that there is one.
    wires: function(self: Message, number: integer): integer
    -- The last varint of that number as an `int32`, `int64`, `uint32`, `uint64` or an `enum`, or nil. It is
    -- the 64 bits of the varint: nothing is cut to 32.
    int: function(self: Message, number: integer): integer?
    -- The last varint of that number as a `sint32` or `sint64`, whose sign is in its low bit, or nil.
    sint: function(self: Message, number: integer): integer?
    -- The last varint of that number as a `bool`, true unless it is 0, or nil.
    bool: function(self: Message, number: integer): boolean?
    -- The last 4-byte field of that number as a `fixed32`, from 0 to 4294967295, or nil.
    fixed32: function(self: Message, number: integer): integer?
    -- The last 4-byte field of that number as an `sfixed32`, from -2147483648 to 2147483647, or nil.
    sfixed32: function(self: Message, number: integer): integer?
    -- The last 8-byte field of that number as a `fixed64` or `sfixed64`, or nil.
    fixed64: function(self: Message, number: integer): integer?
    -- The last 4-byte field of that number as a `float`, or nil.
    float: function(self: Message, number: integer): number?
    -- The last 8-byte field of that number as a `double`, or nil.
    double: function(self: Message, number: integer): number?
    -- The bytes of the last length-delimited field of that number, or nil.
    bytes: function(self: Message, number: integer): string?
    -- As `bytes`, where they are UTF-8, which a `string` holds. Nil where they are not, as where there is no
    -- such field: `bytes` tells the two apart.
    string: function(self: Message, number: integer): string?
    -- The embedded message of that number: every length-delimited field of the number read as a message, and
    -- their fields merged in order. With no such field it is a message of no fields. Nil and why where the
    -- bytes are no message, where the fields pass `max_fields`, or where this message is `max_depth` deep.
    -- Each call reads the fields again, so a caller that needs the message twice keeps it.
    message: function(self: Message, number: integer): Message?, string
    -- Every `int` of that number in order, packed or not; an empty list where there is none. Nil and why
    -- where a packed field ends inside a varint or holds one that is malformed.
    repeated_int: function(self: Message, number: integer): {integer}?, string
    -- Every `sint` of that number, as [`repeated_int`].
    repeated_sint: function(self: Message, number: integer): {integer}?, string
    -- Every `fixed32` of that number in order, packed or not. Nil and why where a packed field's length is
    -- no multiple of 4.
    repeated_fixed32: function(self: Message, number: integer): {integer}?, string
    -- Every `sfixed32` of that number, as [`repeated_fixed32`].
    repeated_sfixed32: function(self: Message, number: integer): {integer}?, string
    -- Every `fixed64` of that number in order, packed or not. Nil and why where a packed field's length is
    -- no multiple of 8.
    repeated_fixed64: function(self: Message, number: integer): {integer}?, string
    -- Every `float` of that number, as [`repeated_fixed32`].
    repeated_float: function(self: Message, number: integer): {number}?, string
    -- Every `double` of that number, as [`repeated_fixed64`].
    repeated_double: function(self: Message, number: integer): {number}?, string
    -- The bytes of every length-delimited field of that number in order: a repeated `bytes` or `string`.
    repeated_bytes: function(self: Message, number: integer): {string}
    -- Every embedded message of that number in order, each by itself and none merged. Nil and why as
    -- `message` fails, for the first that does.
    repeated_message: function(self: Message, number: integer): {Message}?, string
  end

  -- What a packed field holds, for `packed`: named as the method that writes one such value.
  enum Kind
    "int"
    "sint"
    "fixed32"
    "fixed64"
    "float"
    "double"
  end

  -- The bytes of a message being written, from [`Protobuf.writer`]. Each method but `encode` writes one field
  -- after those before it and answers the writer, so calls chain. None raises for a field it cannot write: the first field that cannot be
  -- written (a number that is no field's, a value past its type) is why `encode` fails, and the fields after
  -- it are not written.
  interface Writer
    -- A varint field: an `int32`, `int64`, `uint32`, `uint64` or an `enum`. A negative value is ten bytes.
    int: function(self: Writer, number: integer, value: integer): Writer
    -- A varint field with its sign in the low bit, as `sint32` and `sint64` are: a small negative value
    -- is a short one.
    sint: function(self: Writer, number: integer, value: integer): Writer
    -- A `bool`: the varint 1 or 0.
    bool: function(self: Writer, number: integer, value: boolean): Writer
    -- A 4-byte field, a `fixed32` or `sfixed32`: `value` is from -2147483648 to 4294967295.
    fixed32: function(self: Writer, number: integer, value: integer): Writer
    -- An 8-byte field, a `fixed64` or `sfixed64`.
    fixed64: function(self: Writer, number: integer, value: integer): Writer
    -- A `float`: `value` rounded to the nearest single, which for one past them all is the infinity of its
    -- sign. A NaN is the bytes `00 00 c0 7f` whatever its sign and payload.
    float: function(self: Writer, number: integer, value: number): Writer
    -- A `double`. A NaN is the bytes `00 00 00 00 00 00 f8 7f` whatever its sign and payload.
    double: function(self: Writer, number: integer, value: number): Writer
    -- A length-delimited field of any bytes.
    bytes: function(self: Writer, number: integer, value: string): Writer
    -- A `string`: as `bytes`, and `value` must be UTF-8.
    string: function(self: Writer, number: integer, value: string): Writer
    -- An embedded message: the fields `child` holds now. Writing more to `child` afterwards changes
    -- nothing here. A `child` that cannot be encoded is why this writer cannot.
    message: function(self: Writer, number: integer, child: Writer): Writer
    -- A packed repeated field: every value in one length-delimited field, each written as `kind` writes
    -- one. An empty list writes no field, as the format has it. A value of an integer kind that is no
    -- integer, or past its kind, cannot be written. A `bool` is packed as the "int" 1 or 0.
    packed: function(self: Writer, number: integer, kind: Kind, values: {number}): Writer
    -- The bytes of the fields written so far, or nil and why the first that could not be written could
    -- not. It may be called again after more fields. Two messages' bytes joined are the bytes of the two
    -- merged.
    encode: function(self: Writer): string?, string
  end

  -- A message being written. Writer above says what each method writes.
  record Building is Writer
    userdata

    int: function(Building, number: integer, value: integer): Writer
    sint: function(Building, number: integer, value: integer): Writer
    bool: function(Building, number: integer, value: boolean): Writer
    fixed32: function(Building, number: integer, value: integer): Writer
    fixed64: function(Building, number: integer, value: integer): Writer
    float: function(Building, number: integer, value: number): Writer
    double: function(Building, number: integer, value: number): Writer
    bytes: function(Building, number: integer, value: string): Writer
    string: function(Building, number: integer, value: string): Writer
    message: function(Building, number: integer, child: Writer): Writer
    packed: function(Building, number: integer, kind: Kind, values: {number}): Writer
    encode: function(Building): string?, string
  end

  -- A message that was read. Message above says what each method answers.
  record Decoded is Message
    userdata

    -- Every field, or those `keep` answers true for.
    fields: function(Decoded, keep?: function(number: integer, wire: integer): boolean): {Field}
    -- Whether any field has the number.
    has: function(Decoded, number: integer): boolean
    -- The wire types of the number's fields, a bit for each.
    wires: function(Decoded, number: integer): integer
    -- The last field of the number and of the read's wire type, as the type the read is named for, or nil.
    int: function(Decoded, number: integer): integer?
    sint: function(Decoded, number: integer): integer?
    bool: function(Decoded, number: integer): boolean?
    fixed32: function(Decoded, number: integer): integer?
    sfixed32: function(Decoded, number: integer): integer?
    fixed64: function(Decoded, number: integer): integer?
    float: function(Decoded, number: integer): number?
    double: function(Decoded, number: integer): number?
    bytes: function(Decoded, number: integer): string?
    -- As `bytes`, and nil where they are not UTF-8.
    string: function(Decoded, number: integer): string?
    -- The embedded messages of the number merged, or nil and why they are none.
    message: function(Decoded, number: integer): Message?, string
    -- Every value of the number in order, packed or not, or nil and why a packed field holds none.
    repeated_int: function(Decoded, number: integer): {integer}?, string
    repeated_sint: function(Decoded, number: integer): {integer}?, string
    repeated_fixed32: function(Decoded, number: integer): {integer}?, string
    repeated_sfixed32: function(Decoded, number: integer): {integer}?, string
    repeated_fixed64: function(Decoded, number: integer): {integer}?, string
    repeated_float: function(Decoded, number: integer): {number}?, string
    repeated_double: function(Decoded, number: integer): {number}?, string
    -- The bytes of every length-delimited field of the number in order.
    repeated_bytes: function(Decoded, number: integer): {string}
    -- Every embedded message of the number in order, none merged, or nil and why one is none.
    repeated_message: function(Decoded, number: integer): {Message}?, string
  end

  -- The message in `data`, and "", or nil and why the bytes are none. A
  -- message holds `max_fields` fields at most, and messages nest
  -- `max_depth` deep at most.
  decode: function(data: string, max_depth: integer, max_fields: integer): Decoded?, string
  -- The varint at byte `at` of `data` and the position after it, or nil
  -- and why there is none. Raises where `at` is under 1.
  read_varint: function(data: string, at: integer): Varint?, string
  -- A writer of a message with no fields yet.
  writer: function(): Building
end

return protobuf
