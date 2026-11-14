--- Tests of [`cosmic.protobuf`]. The bytes in hex are what the reference implementation (the `protobuf` package
--- of Python) writes for a message of these fields, and what it reads is what each case says is read.

local Codec = require("cosmic.codec")
local Protobuf = require("cosmic.protobuf")

local function bytes_of(hex: string): string
  local bytes = assert(Codec.unhex(hex))
  return bytes
end

--- The message in the bytes `hex` spells, which is one.
local function decoded(hex: string, opts?: Protobuf.Options): Protobuf.Message
  local message = assert(Protobuf.decode(bytes_of(hex), opts))
  return message
end

--- What the writer holds, in hex.
local function written(writer: Protobuf.Writer): string
  local bytes = assert(writer:encode())
  return Codec.hex(bytes)
end

local function refused(hex: string)
  local ok, message, why = pcall(Protobuf.decode, bytes_of(hex))
  assert(ok, hex .. " raised")
  assert(message == nil and why is string and why:find("^protobuf: ") ~= nil, hex .. " was read")
end

local function unwritable(writer: Protobuf.Writer, pattern: string)
  local bytes, why = writer:encode()
  assert(bytes == nil and why:find(pattern) ~= nil, why)
end

--- The fields written as [`Protobuf.encode`] writes them, in hex.
local function encoded(fields: {Protobuf.Field}): string
  local bytes = assert(Protobuf.encode(fields))
  return Codec.hex(bytes)
end

--- The message in `data`, which is one.
local function message_in(data: string, opts?: Protobuf.Options): Protobuf.Message
  local message = assert(Protobuf.decode(data, opts))
  return message
end

local record IntCase
  value: integer
  hex: string
end

local type WriteInt = function(Protobuf.Writer, integer, integer): Protobuf.Writer
local type ReadInt = function(Protobuf.Message, integer): integer?

--- Each value is written as the reference writes it in field `number`, and its bytes read back as it.
local function check_ints(number: integer, write: WriteInt, read: ReadInt, cases: {IntCase})
  for _, case in ipairs(cases) do
    assert(written(write(Protobuf.writer(), number, case.value)) == case.hex,
      ("%d is not written as %s"):format(case.value, case.hex))
    assert(read(decoded(case.hex), number) == case.value, ("%s is not read as %d"):format(case.hex, case.value))
  end
end

local function write_int(w: Protobuf.Writer, number: integer, value: integer): Protobuf.Writer
  return w:int(number, value)
end

local function write_sint(w: Protobuf.Writer, number: integer, value: integer): Protobuf.Writer
  return w:sint(number, value)
end

local function write_fixed32(w: Protobuf.Writer, number: integer, value: integer): Protobuf.Writer
  return w:fixed32(number, value)
end

local function write_fixed64(w: Protobuf.Writer, number: integer, value: integer): Protobuf.Writer
  return w:fixed64(number, value)
end

local function read_int(m: Protobuf.Message, number: integer): integer?
  return m:int(number)
end

local function read_sint(m: Protobuf.Message, number: integer): integer?
  return m:sint(number)
end

local function read_fixed32(m: Protobuf.Message, number: integer): integer?
  return m:fixed32(number)
end

local function read_sfixed32(m: Protobuf.Message, number: integer): integer?
  return m:sfixed32(number)
end

local function read_fixed64(m: Protobuf.Message, number: integer): integer?
  return m:fixed64(number)
end

local function test_a_varint_integer_is_written_and_read_as_the_reference_does()
  -- int32: a negative one is the ten bytes of its 64-bit sign extension.
  check_ints(1, write_int, read_int, {
    { value = 0, hex = "0800" },
    { value = 1, hex = "0801" },
    { value = 127, hex = "087f" },
    { value = 128, hex = "088001" },
    { value = 300, hex = "08ac02" },
    { value = 2147483647, hex = "08ffffffff07" },
    { value = -1, hex = "08ffffffffffffffffff01" },
    { value = -2147483648, hex = "0880808080f8ffffffff01" },
  })
  -- int64.
  check_ints(2, write_int, read_int, {
    { value = 0, hex = "1000" },
    { value = math.maxinteger, hex = "10ffffffffffffffff7f" },
    { value = -1, hex = "10ffffffffffffffffff01" },
    { value = math.mininteger, hex = "1080808080808080808001" },
  })
  -- uint32, and uint64: 2^63 and 2^64 - 1 are the negative integers of their bits.
  check_ints(3, write_int, read_int, { { value = 0, hex = "1800" }, { value = 4294967295, hex = "18ffffffff0f" } })
  check_ints(4, write_int, read_int, {
    { value = math.maxinteger, hex = "20ffffffffffffffff7f" },
    { value = math.mininteger, hex = "2080808080808080808001" },
    { value = -1, hex = "20ffffffffffffffffff01" },
  })
  assert(("%x"):format(assert(decoded("20ffffffffffffffffff01"):int(4))) == "ffffffffffffffff")
end

local function test_a_zigzag_integer_is_written_and_read_as_the_reference_does()
  -- sint32.
  check_ints(5, write_sint, read_sint, {
    { value = 0, hex = "2800" },
    { value = -1, hex = "2801" },
    { value = 1, hex = "2802" },
    { value = -2, hex = "2803" },
    { value = 2147483647, hex = "28feffffff0f" },
    { value = -2147483648, hex = "28ffffffff0f" },
  })
  -- sint64.
  check_ints(6, write_sint, read_sint, {
    { value = 0, hex = "3000" },
    { value = -1, hex = "3001" },
    { value = math.maxinteger, hex = "30feffffffffffffffff01" },
    { value = math.mininteger, hex = "30ffffffffffffffffff01" },
  })
end

local function test_a_bool_is_one_byte_and_any_nonzero_varint_is_true()
  assert(written(Protobuf.writer():bool(7, true)) == "3801")
  assert(written(Protobuf.writer():bool(7, false)) == "3800")
  assert(decoded("3801"):bool(7) == true and decoded("3800"):bool(7) == false)
  assert(decoded("3802"):bool(7) == true)
  assert(decoded(""):bool(7) == nil)
end

local function test_a_fixed_integer_is_written_and_read_as_the_reference_does()
  check_ints(8, write_fixed32, read_fixed32, {
    { value = 0, hex = "4500000000" },
    { value = 1, hex = "4501000000" },
    { value = 4294967295, hex = "45ffffffff" },
  })
  check_ints(10, write_fixed32, read_sfixed32, {
    { value = 0, hex = "5500000000" },
    { value = -1, hex = "55ffffffff" },
    { value = 2147483647, hex = "55ffffff7f" },
    { value = -2147483648, hex = "5500000080" },
  })
  -- fixed64, whose 2^63 and 2^64 - 1 are negative here, and sfixed64.
  check_ints(9, write_fixed64, read_fixed64, {
    { value = 0, hex = "490000000000000000" },
    { value = 1, hex = "490100000000000000" },
    { value = math.mininteger, hex = "490000000000000080" },
    { value = -1, hex = "49ffffffffffffffff" },
  })
  check_ints(11, write_fixed64, read_fixed64, {
    { value = math.maxinteger, hex = "59ffffffffffffff7f" },
    { value = math.mininteger, hex = "590000000000000080" },
  })
  -- The two readings of four bytes differ only above 2^31 - 1.
  assert(decoded("45ffffffff"):sfixed32(8) == -1 and decoded("55ffffffff"):fixed32(10) == 4294967295)
end

local record FloatCase
  value: number
  hex: string
end

local function test_a_float_is_written_and_read_as_the_reference_does()
  local singles: {FloatCase} = {
    { value = 0.0, hex = "6500000000" },
    { value = -0.0, hex = "6500000080" },
    { value = 1.5, hex = "650000c03f" },
    { value = -2.75, hex = "65000030c0" },
    { value = 3.4028234663852886e+38, hex = "65ffff7f7f" },
    { value = 1.401298464324817e-45, hex = "6501000000" },
    { value = math.huge, hex = "650000807f" },
    { value = -math.huge, hex = "65000080ff" },
  }
  for _, case in ipairs(singles) do
    assert(written(Protobuf.writer():float(12, case.value)) == case.hex, case.hex)
    local read = assert(decoded(case.hex):float(12))
    assert(read == case.value and 1 / read == 1 / case.value, case.hex)
  end
  -- A value no single holds is rounded to the nearest, and reads back as that.
  assert(written(Protobuf.writer():float(12, 0.1)) == "65cdcccc3d")
  assert(decoded("65cdcccc3d"):float(12) == 0.10000000149011612)
  -- Past the greatest single the nearest is still it, up to half way to the next power of two, and from
  -- there on the infinity, as the reference rounds.
  assert(written(Protobuf.writer():float(12, 3.40282347e+38)) == "65ffff7f7f")
  assert(written(Protobuf.writer():float(12, 3.4028235677973362e+38)) == "65ffff7f7f")
  assert(written(Protobuf.writer():float(12, -3.4028235677973362e+38)) == "65ffff7fff")
  assert(written(Protobuf.writer():float(12, 3.4028235677973366e+38)) == "650000807f")
  assert(written(Protobuf.writer():float(12, -3.4028235677973366e+38)) == "65000080ff")
  assert(written(Protobuf.writer():float(12, 1e39)) == "650000807f")
  assert(written(Protobuf.writer():packed(21, "float", { 3.40282347e+38, 1e39 })) == "aa0108ffff7f7f0000807f")
  assert(written(Protobuf.writer():float(12, -1.7976931348623157e308)) == "65000080ff")
  local nan = assert(decoded("650000c07f"):float(12))
  assert(nan ~= nan)
  assert(written(Protobuf.writer():float(12, 0 / 0)) == "650000c07f")
  assert(written(Protobuf.writer():float(12, -(0 / 0))) == "650000c07f")
end

local function test_a_double_is_written_and_read_as_the_reference_does()
  local doubles: {FloatCase} = {
    { value = 0.0, hex = "690000000000000000" },
    { value = -0.0, hex = "690000000000000080" },
    { value = 1.5, hex = "69000000000000f83f" },
    { value = 0.1, hex = "699a9999999999b93f" },
    { value = 1.7976931348623157e308, hex = "69ffffffffffffef7f" },
    { value = 5e-324, hex = "690100000000000000" },
    { value = math.huge, hex = "69000000000000f07f" },
    { value = -math.huge, hex = "69000000000000f0ff" },
  }
  for _, case in ipairs(doubles) do
    assert(written(Protobuf.writer():double(13, case.value)) == case.hex, case.hex)
    local read = assert(decoded(case.hex):double(13))
    assert(read == case.value and 1 / read == 1 / case.value, case.hex)
  end
  local nan = assert(decoded("69000000000000f87f"):double(13))
  assert(nan ~= nan)
  assert(written(Protobuf.writer():double(13, 0 / 0)) == "69000000000000f87f")
  assert(written(Protobuf.writer():double(13, -(0 / 0))) == "69000000000000f87f")
end

local function test_a_string_and_bytes_are_written_and_read_as_the_reference_does()
  assert(written(Protobuf.writer():string(14, "")) == "7200")
  assert(written(Protobuf.writer():string(14, "hello")) == "720568656c6c6f")
  local text = "h\u{e9}llo \u{2603} \u{1F600}"
  assert(written(Protobuf.writer():string(14, text)) == "720f68c3a96c6c6f20e2988320f09f9880")
  assert(decoded("720f68c3a96c6c6f20e2988320f09f9880"):string(14) == text)
  assert(decoded("7200"):string(14) == "" and decoded("7200"):bytes(14) == "")
  assert(written(Protobuf.writer():bytes(15, "")) == "7a00")
  assert(written(Protobuf.writer():bytes(15, "\x00\xff\x80")) == "7a0300ff80")
  assert(decoded("7a0300ff80"):bytes(15) == "\x00\xff\x80")
  -- 200 bytes: a length of two bytes.
  local long = ("\x07"):rep(200)
  local hex = written(Protobuf.writer():bytes(15, long))
  assert(hex:sub(1, 6) == "7ac801" and decoded(hex):bytes(15) == long)
end

local function test_a_string_that_is_not_utf8_is_bytes_alone()
  -- The reference reads these bytes into a proto2 `string`; here `string` holds what its name says.
  local message = decoded("7202c328")
  assert(message:string(14) == nil and message:bytes(14) == "\xc3\x28" and message:has(14))
  unwritable(Protobuf.writer():string(14, "\xc3\x28"), "field 14: a string that is not UTF%-8")
  assert(written(Protobuf.writer():bytes(14, "\xc3\x28")) == "7202c328")
end

local function test_a_string_cut_inside_a_character_is_not_completed_by_the_next_field()
  -- Field 1 holds the first byte of a two-byte character, and the tag of field 17 after it is a byte that
  -- would continue one.
  local message = decoded("0a01c3880101")
  assert(message:string(1) == nil and message:bytes(1) == "\xc3" and message:int(17) == 1)
end

local function test_the_greatest_field_number()
  assert(written(Protobuf.writer():int(536870911, 7)) == "f8ffffff0f07")
  assert(decoded("f8ffffff0f07"):int(536870911) == 7)
end

local function test_an_embedded_message_is_written_and_read_as_the_reference_does()
  local hex = "8201240896011202696e1a0c0102ffffffffffffffffff01220d220b08fbffffffffffffffff01"
  local deepest = Protobuf.writer():int(1, -5)
  local inner = Protobuf.writer():int(1, 150):string(2, "in"):packed(3, "int", { 1, 2, -1 }):message(4,
    Protobuf.writer():message(4, deepest))
  assert(written(Protobuf.writer():message(16, inner)) == hex)
  local read = assert(decoded(hex):message(16))
  assert(read:int(1) == 150 and read:string(2) == "in")
  local c = assert(read:repeated_int(3))
  assert(#c == 3 and c[1] == 1 and c[2] == 2 and c[3] == -1)
  local third = assert(assert(read:message(4)):message(4))
  assert(third:int(1) == -5)
end

local function test_a_child_written_to_after_it_was_embedded_changes_nothing()
  local child = Protobuf.writer():int(1, 1)
  local parent = Protobuf.writer():message(16, child)
  child:int(1, 2)
  assert(written(parent) == "8201020801")
  assert(written(child) == "08010802")
end

--- Whether the two lists hold the same values in the same order.
local function same_list<T>(got: {T}?, want: {T}): boolean
  if got == nil or #got ~= #want then return false end
  for i = 1, #want do
    if got[i] ~= want[i] then return false end
  end
  return true
end

local function test_packed_fields_are_written_and_read_as_the_reference_does()
  local ints = { 0, 1, 300, -1, 2147483647, -2147483648 }
  local hex = "8a011d0001ac02ffffffffffffffffff01ffffffff0780808080f8ffffffff01"
  assert(written(Protobuf.writer():packed(17, "int", ints)) == hex)
  assert(same_list(decoded(hex):repeated_int(17), ints))

  local sints = { 0, -1, 1, math.mininteger, math.maxinteger }
  hex = "920117000102ffffffffffffffffff01feffffffffffffffff01"
  assert(written(Protobuf.writer():packed(18, "sint", sints)) == hex)
  assert(same_list(decoded(hex):repeated_sint(18), sints))

  hex = "9a010c0000000001000000ffffffff"
  assert(written(Protobuf.writer():packed(19, "fixed32", { 0, 1, 4294967295 })) == hex)
  assert(same_list(decoded(hex):repeated_fixed32(19), { 0, 1, 4294967295 }))
  assert(same_list(decoded(hex):repeated_sfixed32(19), { 0, 1, -1 }))

  hex = "d2010cffffffffffffff7f00000080"
  assert(written(Protobuf.writer():packed(26, "fixed32", { -1, 2147483647, -2147483648 })) == hex)
  assert(same_list(decoded(hex):repeated_sfixed32(26), { -1, 2147483647, -2147483648 }))

  hex = "ca01100100000000000000ffffffffffffffff"
  assert(written(Protobuf.writer():packed(25, "fixed64", { 1, -1 })) == hex)
  assert(same_list(decoded(hex):repeated_fixed64(25), { 1, -1 }))

  hex = "a20118000000000000e03f000000000000f0ff9c7500883ce4377e"
  assert(written(Protobuf.writer():packed(20, "double", { 0.5, -math.huge, 1e300 })) == hex)
  assert(same_list(decoded(hex):repeated_double(20), { 0.5, -math.huge, 1e300 }))

  hex = "aa010c0000003f0000807f0000a0bf"
  assert(written(Protobuf.writer():packed(21, "float", { 0.5, math.huge, -1.25 })) == hex)
  assert(same_list(decoded(hex):repeated_float(21), { 0.5, math.huge, -1.25 }))
end

local function test_an_empty_packed_field_is_no_field_and_reads_as_no_values()
  assert(written(Protobuf.writer():packed(17, "int", {})) == "")
  -- A writer may still send one of no bytes.
  assert(same_list(decoded("8a0100"):repeated_int(17), {}))
  assert(same_list(decoded(""):repeated_int(17), {}))
  assert(same_list(decoded(""):repeated_double(17), {}))
  assert(#decoded(""):repeated_bytes(17) == 0)
end

local function test_unpacked_repeated_fields_are_written_and_read_as_the_reference_does()
  local hex = "c00103c0018e02c001ffffffffffffffffff01"
  assert(written(Protobuf.writer():int(24, 3):int(24, 270):int(24, -1)) == hex)
  assert(same_list(decoded(hex):repeated_int(24), { 3, 270, -1 }))

  hex = "d901000000000000f03fd9010000000000000040"
  assert(written(Protobuf.writer():double(27, 1.0):double(27, 2.0)) == hex)
  assert(same_list(decoded(hex):repeated_double(27), { 1.0, 2.0 }))

  hex = "b2010161b20100b20103636363"
  assert(written(Protobuf.writer():string(22, "a"):string(22, ""):string(22, "ccc")) == hex)
  assert(same_list(decoded(hex):repeated_bytes(22), { "a", "", "ccc" }))

  hex = "ba01020801ba0105120374776fba0100"
  assert(written(Protobuf.writer():message(23, Protobuf.writer():int(1, 1)):message(23,
    Protobuf.writer():string(2, "two")):message(23, Protobuf.writer())) == hex)
  local messages = assert(decoded(hex):repeated_message(23))
  assert(#messages == 3)
  assert(assert(messages[1]):int(1) == 1 and assert(messages[2]):string(2) == "two")
  assert(#assert(messages[3]):fields() == 0)
end

local function test_a_repeated_read_takes_packed_and_unpacked_fields_together()
  -- The reference reads each as 1, 2, 3, 4: one value, a packed pair, one value, an empty packed field; and a
  -- field declared unpacked that was sent packed.
  assert(same_list(decoded("8801018a010202038801048a0100"):repeated_int(17), { 1, 2, 3, 4 }))
  assert(same_list(decoded("c20103010203c00104"):repeated_int(24), { 1, 2, 3, 4 }))
  assert(same_list(decoded("9d01010000009a010802000000030000009d0104000000"):repeated_fixed32(19), { 1, 2, 3, 4 }))
end

local function test_the_last_of_a_field_sent_twice_wins()
  local message = decoded("08010802")
  assert(message:int(1) == 2)
  assert(same_list(message:repeated_int(1), { 1, 2 }))
  assert(decoded("7201617201627200"):bytes(14) == "")
end

local function test_a_field_of_another_wire_type_is_passed_over()
  -- Field 1 as 4 bytes, as a varint, and as 4 bytes again: the reference reads the int32 5 and keeps the others
  -- as unknown.
  local message = decoded("0d0100000008050d02000000")
  assert(message:int(1) == 5 and message:fixed32(1) == 2)
  assert(message:bytes(1) == nil and message:double(1) == nil)
  assert(same_list(message:repeated_int(1), { 5 }))
  assert(same_list(message:repeated_fixed32(1), { 1, 2 }))
  local empty = assert(message:message(1))
  assert(#empty:fields() == 0)
  assert(#message:fields() == 3)
end

local function test_embedded_messages_of_one_number_are_merged()
  -- Four parts of field 16: {a = 1}, {b = "hi"}, {a = 2, c = [7]}, {c = [8]}. The reference reads a = 2,
  -- b = "hi", c = [7, 8].
  local hex = "82010208018201041202686982010508021a01078201031a0108"
  local merged = assert(decoded(hex):message(16))
  assert(merged:int(1) == 2 and merged:string(2) == "hi")
  assert(same_list(merged:repeated_int(3), { 7, 8 }))
  assert(#merged:fields() == 5)
  local parts = assert(decoded(hex):repeated_message(16))
  assert(#parts == 4 and assert(parts[1]):int(1) == 1 and assert(parts[3]):int(1) == 2)
  -- The bytes of two messages joined are the two merged.
  local one = assert(Protobuf.writer():int(1, 1):string(2, "hi"):encode())
  local two = assert(Protobuf.writer():int(1, 2):encode())
  local joined = message_in(one .. two)
  assert(joined:int(1) == 2 and joined:string(2) == "hi")
end

local function test_unknown_fields_are_kept_and_written_back()
  local hex = "f80601fa06036162630805"
  local message = decoded(hex)
  assert(message:int(1) == 5)
  local fields = message:fields()
  assert(#fields == 3)
  local first, second, third = assert(fields[1]), assert(fields[2]), assert(fields[3])
  assert(first.number == 111 and first.wire == Protobuf.VARINT and first.value == 1)
  assert(second.number == 111 and second.wire == Protobuf.LEN and second.value == "abc")
  assert(third.number == 1 and third.wire == Protobuf.VARINT and third.value == 5)
  assert(encoded(fields) == hex)
end

local function test_a_message_of_every_type_is_read_and_written_back()
  local hex = "08f9ffffffffffffffff0120ffffffffffffffffff0130a7e8c8e99707380145efbeadde59feffffffffffffff" ..
    "650000c03f699a9999999999b9bf7205636166c3a97a02000182010608011a0205068a0103010203b2010178b2010179" ..
    "ba01020809c00104c00105"
  local message = decoded(hex)
  assert(message:int(1) == -7 and message:int(4) == -1 and message:sint(6) == -123456789012)
  assert(message:bool(7) == true and message:fixed32(8) == 0xdeadbeef and message:fixed64(11) == -2)
  assert(message:float(12) == 1.5 and message:double(13) == -0.1)
  assert(message:string(14) == "caf\u{e9}" and message:bytes(15) == "\x00\x01")
  local inner = assert(message:message(16))
  assert(inner:int(1) == 1 and same_list(inner:repeated_int(3), { 5, 6 }))
  assert(same_list(message:repeated_int(17), { 1, 2, 3 }))
  assert(same_list(message:repeated_bytes(22), { "x", "y" }))
  assert(assert(assert(message:repeated_message(23))[1]):int(1) == 9)
  assert(same_list(message:repeated_int(24), { 4, 5 }))
  assert(message:has(1) and not message:has(2) and message:int(2) == nil)
  assert(encoded(message:fields()) == hex)
  local w = Protobuf.writer():int(1, -7):int(4, -1):sint(6, -123456789012):bool(7, true):fixed32(8, 0xdeadbeef)
  w:fixed64(11, -2):float(12, 1.5):double(13, -0.1):string(14, "caf\u{e9}"):bytes(15, "\x00\x01")
  w:message(16, Protobuf.writer():int(1, 1):packed(3, "int", { 5, 6 })):packed(17, "int", { 1, 2, 3 })
  w:string(22, "x"):string(22, "y"):message(23, Protobuf.writer():int(1, 9)):int(24, 4):int(24, 5)
  assert(written(w) == hex)
end

local function test_a_varint_in_more_bytes_than_it_needs_is_its_value()
  -- The reference reads these too, and drops the bits the tenth byte holds past the 64th.
  assert(decoded("08818000"):int(1) == 1)
  assert(decoded("08ffffffffffffffffff02"):int(1) == math.maxinteger)
  assert(decoded("08ffffffffffffffffff7f"):int(1) == -1)
  local fields = decoded("08818000"):fields()
  assert(encoded(fields) == "0801")
  -- A tag may be padded too.
  assert(decoded("88800001"):int(1) == 1)
end

local function test_an_int_is_the_64_bits_of_its_varint()
  -- An int32 -1 cut to five bytes, which the reference reads into an int32 as -1, is here what it says.
  assert(decoded("08ffffffff0f"):int(1) == 4294967295)
end

local function test_bytes_that_are_no_message_are_refused_and_never_raise()
  refused("08ffffffffffffffffffff01") -- a varint of 11 bytes
  refused("ffffffffffffffffffffff0100") -- a tag of 11 bytes
  refused("0001") -- field number 0
  refused("0000")
  refused("0b0c") -- a group
  refused("0b")
  refused("0c")
  refused("f3067ff406")
  refused("0e") -- wire type 6
  refused("0f00") -- wire type 7
  refused("72056162") -- a length past the end
  refused("7201")
  refused("72")
  refused("0880") -- the bytes end inside a varint
  refused("80")
  refused("08") -- a tag and no value
  refused("45010203") -- 3 of 4 bytes
  refused("45")
  refused("4901020304050607") -- 7 of 8 bytes
  refused("8080808001") -- a tag whose field number is 2^29
  refused("80808080800100") -- a tag over 32 bits
  refused("ffffffffffffffffff0100")
  refused("7280808080808080808001") -- a length of 2^63
  refused("72ffffffffffffffffff01") -- a length of 2^64 - 1
  refused("72ffffffffffffffff7f") -- a length of 2^63 - 1
  refused("0801ff") -- bytes after the last field that are none
end

local function test_a_refusal_says_where_and_why()
  local _, why = Protobuf.decode(bytes_of("08010e"))
  assert(why == "protobuf: byte 3: field 1 has wire type 6, which the format does not have", why)
  _, why = Protobuf.decode(bytes_of("0b"))
  assert(why == "protobuf: byte 1: field 1 is a group (wire type 3), which is not read", why)
  _, why = Protobuf.decode(bytes_of("080172056162"))
  assert(why == "protobuf: byte 3: the length of field 14 passes the end of the bytes", why)
  _, why = Protobuf.decode(bytes_of("0880"))
  assert(why == "protobuf: byte 1: field 1: the bytes end inside a varint", why)
end

local function test_a_length_past_63_bits_is_past_the_end()
  -- Such a length is a negative integer here. Taken as a length it would move the read backwards, to read the
  -- same bytes again.
  local _, why = Protobuf.decode(bytes_of("080172ffffffffffffffffff01"))
  assert(why == "protobuf: byte 3: the length of field 14 passes the end of the bytes", why)
  _, why = Protobuf.decode(bytes_of("08017280808080808080808001"))
  assert(why == "protobuf: byte 3: the length of field 14 passes the end of the bytes", why)
  -- A length that goes back to the start of the bytes: -2 from the byte after it.
  _, why = Protobuf.decode(bytes_of("72feffffffffffffffff01"))
  assert(why == "protobuf: byte 1: the length of field 14 passes the end of the bytes", why)
end

local function test_a_malformed_packed_field_fails_the_read_and_not_the_decode()
  -- 5 bytes of fixed32, and a varint the field ends inside: the reference refuses the message, which knows the
  -- field is packed; here the field is bytes until it is read as numbers.
  local message = decoded("9a01050102030405")
  local values, why = message:repeated_fixed32(19)
  assert(values == nil and why == "protobuf: packed field 19 is 5 bytes, no multiple of 4", why)
  local floats, float_why = message:repeated_float(19)
  assert(floats == nil and float_why ~= "")
  local doubles, double_why = message:repeated_double(19)
  assert(doubles == nil and double_why == "protobuf: packed field 19 is 5 bytes, no multiple of 8", double_why)
  assert(message:bytes(19) == "\1\2\3\4\5")
  local ints, int_why = decoded("8a010180"):repeated_int(17)
  assert(ints == nil and int_why == "protobuf: packed field 17: the bytes end inside a varint", int_why)
  local long, long_why = decoded("8a010b" .. ("ff"):rep(10) .. "01"):repeated_sint(17)
  assert(long == nil and long_why == "protobuf: packed field 17: a varint is longer than 10 bytes", long_why)
  -- A packed varint does not read past its field into the next.
  local stopped, stopped_why = decoded("8a0101800801"):repeated_int(17)
  assert(stopped == nil and stopped_why ~= "")
end

local function test_a_malformed_embedded_message_fails_the_read_and_not_the_decode()
  local message = decoded("8201020880")
  local inner, why = message:message(16)
  assert(inner == nil and why == "protobuf: byte 4: field 1: the bytes end inside a varint (in field 16)", why)
  local each, each_why = message:repeated_message(16)
  assert(each == nil and each_why == why)
  assert(message:bytes(16) == "\x08\x80")
  -- One bad part fails the merge of all.
  local merged, merged_why = decoded("82010208018201020880"):message(16)
  assert(merged == nil and merged_why ~= "")
end

--- A message of field 1 nested `levels` deep inside the outermost, the innermost holding the varint 7 in field 2.
local function nested(levels: integer): string
  local bytes = assert(Protobuf.writer():int(2, 7):encode())
  for _ = 1, levels do
    bytes = assert(Protobuf.writer():bytes(1, bytes):encode())
  end
  return bytes
end

--- How many messages deep field 1 can be followed, the decoded one counted, and why it stopped.
local function depth_reached(message: Protobuf.Message): integer, string
  local depth = 1
  local at = message
  while at:has(1) do
    local inner, why = at:message(1)
    if inner == nil then return depth, why end
    at = inner
    depth = depth + 1
  end
  return depth, ""
end

local function test_messages_nest_to_max_depth_and_no_deeper()
  local deep = nested(150)
  local reached, why = depth_reached(message_in(deep))
  assert(Protobuf.default_depth == 100 and reached == 100, tostring(reached))
  assert(why == "protobuf: field 1 nests deeper than 100 messages", why)
  reached, why = depth_reached(message_in(deep, { max_depth = 3 }))
  assert(reached == 3 and why == "protobuf: field 1 nests deeper than 3 messages", why)
  reached, why = depth_reached(message_in(deep, { max_depth = 200 }))
  assert(reached == 151 and why == "")
  -- At the bound nothing below is read, as one message or as many, whether or not the field is there.
  local top = message_in(deep, { max_depth = 1 })
  local inner, inner_why = top:message(1)
  local each, each_why = top:repeated_message(1)
  assert(inner == nil and inner_why == "protobuf: field 1 nests deeper than 1 message", inner_why)
  assert(each == nil and each_why == inner_why)
  local absent, absent_why = top:message(9)
  assert(absent == nil and absent_why ~= "")
  local none, none_why = top:repeated_message(9)
  assert(none == nil and none_why == "protobuf: field 9 nests deeper than 1 message", none_why)
  assert(top:bytes(1) ~= nil)
end

local function test_a_message_holds_max_fields_and_no_more()
  local three = "080108020803"
  local message, why = Protobuf.decode(bytes_of(three), { max_fields = 2 })
  assert(message == nil and why == "protobuf: the message holds more than 2 fields", why)
  assert(#decoded(three, { max_fields = 3 }):fields() == 3)
  -- An embedded message is held to the bound when it is read, and its parts are counted together.
  local outer = decoded("8201040801080282010208038201020804", { max_fields = 3 })
  local merged, merged_why = outer:message(16)
  assert(merged == nil and merged_why == "protobuf: the message holds more than 3 fields (in field 16)", merged_why)
  local parts = assert(outer:repeated_message(16))
  assert(#parts == 3)
  -- The bound goes down with the messages: here to the third, inside two of one field each.
  local wide = bytes_of("080108020803")
  local nest = decoded(written(Protobuf.writer():message(1, Protobuf.writer():bytes(1, wide))), { max_fields = 2 })
  local below, below_why = assert(nest:message(1)):message(1)
  assert(below == nil and below_why == "protobuf: the message holds more than 2 fields (in field 1)", below_why)
  local each, each_why = assert(assert(nest:repeated_message(1))[1]):repeated_message(1)
  assert(each == nil and each_why == below_why)
  -- The default.
  assert(Protobuf.default_fields == 65536)
  local many = ("\x08\x01"):rep(65536)
  assert(#message_in(many):fields() == 65536)
  local over, over_why = Protobuf.decode(many .. "\x08\x01")
  assert(over == nil and over_why == "protobuf: the message holds more than 65536 fields", over_why)
  -- The values of a packed field are no fields.
  local packed = assert(Protobuf.writer():bytes(1, ("\x01"):rep(100000)):encode())
  assert(#assert(message_in(packed):repeated_int(1)) == 100000)
end

local function test_an_option_that_is_no_bound_raises()
  local bad: {Protobuf.Options} = { { max_depth = 0 }, { max_depth = -1 }, { max_fields = 0 } }
  for _, opts in ipairs(bad) do
    local ok, why = pcall(Protobuf.decode, "", opts)
    assert(not ok and tostring(why):find("must be an integer of 1 or more", 1, true) ~= nil, tostring(why))
  end
end

local function test_a_field_number_that_is_none_cannot_be_written()
  unwritable(Protobuf.writer():int(0, 1), "protobuf: 0 is no field number %(1 to 536870911%)")
  unwritable(Protobuf.writer():bytes(-1, "x"), "protobuf: %-1 is no field number")
  unwritable(Protobuf.writer():double(536870912, 1.0), "protobuf: 536870912 is no field number")
  unwritable(Protobuf.writer():packed(0, "int", { 1 }), "protobuf: 0 is no field number")
  unwritable(Protobuf.writer():message(0, Protobuf.writer()), "protobuf: 0 is no field number")
end

local function test_a_value_past_its_type_cannot_be_written()
  unwritable(Protobuf.writer():fixed32(1, 4294967296), "protobuf: field 1: 4294967296 does not fit 32 bits")
  unwritable(Protobuf.writer():fixed32(1, -2147483649), "does not fit 32 bits")
  unwritable(Protobuf.writer():packed(2, "fixed32", { 1, 4294967296 }), "field 2: 4294967296 does not fit 32 bits")
  unwritable(Protobuf.writer():packed(2, "int", { 1, 1.5 }), "protobuf: field 2: 1.5 is no integer")
  unwritable(Protobuf.writer():packed(2, "sint", { 1e30 }), "is no integer")
  unwritable(Protobuf.writer():packed(2, "fixed64", { 0.5 }), "is no integer")
  -- A float that is a whole number is one.
  assert(written(Protobuf.writer():packed(2, "int", { 3.0 })) == "120103")
end

local function test_the_first_failure_is_the_writers_and_nothing_follows_it()
  local writer = Protobuf.writer():int(1, 1):int(0, 2):fixed32(3, -1 << 40):int(4, 4)
  unwritable(writer, "^protobuf: 0 is no field number")
  writer:int(5, 5)
  unwritable(writer, "^protobuf: 0 is no field number")
  -- A child that failed is why its parent does.
  local parent = Protobuf.writer():int(1, 1):message(2, Protobuf.writer():string(1, "\xff"))
  unwritable(parent, "^protobuf: field 1: a string that is not UTF%-8")
end

local function test_encode_refuses_a_field_that_is_none()
  local function refuses(field: Protobuf.Field, pattern: string)
    local bytes, why = Protobuf.encode({ { number = 1, wire = Protobuf.VARINT, value = 1 }, field })
    assert(bytes == nil and why:find(pattern) ~= nil, why)
  end
  refuses({ number = 0, wire = Protobuf.VARINT, value = 1 }, "protobuf: 0 is no field number")
  refuses({ number = 536870912, wire = Protobuf.LEN, value = "" }, "is no field number")
  refuses({ number = 2, wire = 3, value = 1 }, "protobuf: field 2: 3 is no wire type")
  refuses({ number = 2, wire = 7, value = 1 }, "7 is no wire type")
  refuses({ number = 2, wire = -1, value = 1 }, "%-1 is no wire type")
  refuses({ number = 2, wire = Protobuf.VARINT, value = "x" }, "field 2: wire type 0 holds no bytes")
  refuses({ number = 2, wire = Protobuf.LEN, value = 1 }, "field 2: a length%-delimited field holds bytes")
  refuses({ number = 2, wire = Protobuf.FIXED32, value = -1 << 32 }, "does not fit 32 bits")
end

local function test_encode_writes_each_wire_type()
  local fields: {Protobuf.Field} = {
    { number = 1, wire = Protobuf.VARINT, value = -1 },
    { number = 2, wire = Protobuf.FIXED64, value = 1 },
    { number = 3, wire = Protobuf.LEN, value = "ab" },
    { number = 4, wire = Protobuf.FIXED32, value = 4294967295 },
    { number = 5, wire = Protobuf.FIXED32, value = -1 },
  }
  local hex = "08ffffffffffffffffff011101000000000000001a02616225ffffffff2dffffffff"
  assert(encoded(fields) == hex)
  assert(Protobuf.encode({}) == "")
  local back = decoded(hex):fields()
  assert(#back == 5 and assert(back[5]).value == 4294967295 and assert(back[3]).value == "ab")
end

local function test_varint_writes_the_fewest_bytes()
  assert(Protobuf.varint(0) == "\x00" and Protobuf.varint(1) == "\x01" and Protobuf.varint(127) == "\x7f")
  assert(Protobuf.varint(128) == "\x80\x01" and Protobuf.varint(300) == "\xac\x02")
  assert(Protobuf.varint(16383) == "\xff\x7f" and Protobuf.varint(16384) == "\x80\x80\x01")
  assert(Protobuf.varint(math.maxinteger) == ("\xff"):rep(8) .. "\x7f")
  assert(Protobuf.varint(-1) == ("\xff"):rep(9) .. "\x01")
  assert(Protobuf.varint(math.mininteger) == ("\x80"):rep(9) .. "\x01")
end

local function test_read_varint_reads_one_and_says_where_it_ends()
  local function reads(data: string, at: integer?, value: integer, after: integer)
    local read = assert(Protobuf.read_varint(data, at))
    assert(read.value == value and read.next == after, ("%q: %d, %d"):format(data, read.value, read.next))
  end
  reads("\x00", nil, 0, 2)
  reads("\xac\x02rest", nil, 300, 3)
  reads("xx\xac\x02", 3, 300, 5)
  reads(("\xff"):rep(9) .. "\x01", 1, -1, 11)
  reads(("\x80"):rep(9) .. "\x01", 1, math.mininteger, 11)
  reads("\x81\x80\x00", 1, 1, 4)
  for _, value in ipairs({ 0, 1, 127, 128, 1 << 35, math.maxinteger, -1, math.mininteger, -12345 }) do
    reads(Protobuf.varint(value), 1, value, #Protobuf.varint(value) + 1)
  end
end

local function test_read_varint_refuses_and_never_raises()
  local function refuses(data: string, at: integer?, why: string)
    local ok, read, read_why = pcall(Protobuf.read_varint, data, at)
    assert(ok and read == nil and read_why == why, tostring(read_why))
  end
  refuses("", nil, "protobuf: the bytes end inside a varint")
  refuses("\x80", nil, "protobuf: the bytes end inside a varint")
  refuses(("\xff"):rep(9), nil, "protobuf: the bytes end inside a varint")
  refuses(("\xff"):rep(10), nil, "protobuf: a varint is longer than 10 bytes")
  refuses(("\xff"):rep(10) .. "\x01", nil, "protobuf: a varint is longer than 10 bytes")
  refuses("\x01", 2, "protobuf: the bytes end inside a varint")
  refuses("\x01", 100, "protobuf: the bytes end inside a varint")
  refuses("\x01", math.maxinteger, "protobuf: the bytes end inside a varint")
  refuses("\x01", 0, "protobuf: 0 is no position")
  refuses("\x01", -1, "protobuf: -1 is no position")
end

local function test_a_message_read_from_the_middle_of_bytes_reads_none_outside_it()
  -- An embedded message whose last field's length would reach into the bytes after it.
  local inner = "\x12\x05ab"
  local outer = assert(Protobuf.writer():bytes(1, inner):bytes(2, "cdefgh"):encode())
  local read, why = message_in(outer):message(1)
  assert(read == nil and why:find("the length of field 2 passes the end of the bytes", 1, true) ~= nil, why)
  -- And whose last varint would.
  outer = assert(Protobuf.writer():bytes(1, "\x08\x80"):int(2, 1):encode())
  read, why = message_in(outer):message(1)
  assert(read == nil and why:find("the bytes end inside a varint", 1, true) ~= nil, why)
  outer = assert(Protobuf.writer():bytes(1, "\x0d\x01\x02"):bytes(2, "cdefgh"):encode())
  read, why = message_in(outer):message(1)
  assert(read == nil and why:find("the bytes end inside the 4 bytes of field 1", 1, true) ~= nil, why)
end

local function test_a_read_of_a_message_does_not_change_it()
  local message = decoded("82010208018a01020102")
  local before = encoded(message:fields())
  local fields = message:fields()
  local _, _ = message:message(16)
  local _, _ = message:repeated_int(17)
  assert(#fields == 2 and encoded(message:fields()) == before)
end

local function test_wires_names_the_wire_types_a_number_has_and_fields_keeps_what_it_is_asked_for()
  local bytes = assert(Protobuf.writer():int(1, 5):bytes(1, "abc"):fixed32(2, 7):bytes(3, "kept"):encode())
  local message = assert(Protobuf.decode(bytes))
  assert(message:wires(1) == (1 << Protobuf.VARINT) | (1 << Protobuf.LEN))
  assert(message:wires(2) == 1 << Protobuf.FIXED32 and message:wires(9) == 0)
  local kept = message:fields(function(number: integer, wire: integer): boolean
    return number == 3 or wire == Protobuf.VARINT
  end)
  assert(#kept == 2)
  local first, second = assert(kept[1]), assert(kept[2])
  assert(first.number == 1 and first.value == 5 and second.number == 3 and second.value == "kept")
  assert(#message:fields() == 4, "with no `keep`, every field is answered")
end
