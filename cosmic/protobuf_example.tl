--- Worked examples for [`cosmic.protobuf`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
local Protobuf = require("cosmic.protobuf")

local record Example end

--- A message is written a field at a time, each by the method of its type and under its number. The `.proto`
--- file this one follows would say `string name = 1; int32 id = 2; repeated string emails = 3;`.
function Example.writer()
  local person = Protobuf.writer():string(1, "Ada"):int(2, 150):string(3, "ada@example.com"):string(3, "a@example.org")
  local bytes = assert(person:encode())
  print(Codec.hex(bytes))
  assert(Codec.hex(bytes:sub(1, 8)) == "0a03416461109601")
end

--- Reading says what each field is, since the bytes do not: the same method names, by the same numbers. A field
--- that is not there is nil, which is where a caller puts the default its `.proto` file gives.
function Example.decode()
  local bytes = assert(Protobuf.writer():string(1, "Ada"):int(2, 150):string(3, "ada@example.com"):encode())
  local person = assert(Protobuf.decode(bytes))
  local name = person:string(1) or ""
  local id = person:int(2) or 0
  local active = person:bool(4) == true
  local emails = person:repeated_bytes(3)
  print(name, id, active, #emails, emails[1])
  assert(name == "Ada" and id == 150 and not active and emails[1] == "ada@example.com")
end

--- An embedded message is a writer handed to `message`, and is read back with `message`. A repeated number is
--- packed into one field, and `repeated_double` reads it whether the writer packed it or not.
function Example.embedded()
  local point = Protobuf.writer():sint(1, -3):sint(2, 4)
  local shape = Protobuf.writer():string(1, "probe"):message(2, point):packed(3, "double", { 0.5, 1.5, 2.5 })
  local bytes = assert(shape:encode())

  local read = assert(Protobuf.decode(bytes))
  local at = assert(read:message(2))
  local samples = assert(read:repeated_double(3))
  print(read:string(1), at:sint(1), at:sint(2), #samples, samples[3])
  assert(at:sint(1) == -3 and at:sint(2) == 4 and #samples == 3 and samples[3] == 2.5)
end

--- A message with no field of the number has an empty message there, so a chain of `message` reads needs one
--- test, at the value.
function Example.absent_message()
  local read = assert(Protobuf.decode(""))
  local inner = assert(read:message(5))
  print(read:has(5), #inner:fields(), inner:int(1))
  assert(not read:has(5) and inner:int(1) == nil)
end

--- A `uint64` above 2^63 - 1 is the negative integer of the same bits: `math.ult` orders it and `%x` prints it.
function Example.unsigned()
  local bytes = assert(Protobuf.writer():int(1, -1):fixed64(2, math.mininteger):encode())
  local read = assert(Protobuf.decode(bytes))
  local all_ones, top_bit = assert(read:int(1)), assert(read:fixed64(2))
  print(("%x %x"):format(all_ones, top_bit), math.ult(top_bit, all_ones))
  assert(all_ones == -1 and math.ult(1, all_ones) and math.ult(top_bit, all_ones))
end

--- Every field of a message is listed, the ones the reader has no name for too, so a program that changes one
--- field passes the rest on: here field 2 is dropped and what is left is written as it was read.
function Example.fields()
  local names: {integer: string} = {
    [Protobuf.VARINT] = "varint",
    [Protobuf.FIXED64] = "8 bytes",
    [Protobuf.LEN] = "bytes",
    [Protobuf.FIXED32] = "4 bytes",
  }
  local bytes = assert(Protobuf.writer():int(1, 7):string(2, "secret"):double(3, 0.5):fixed32(9, 1):encode())
  local kept: mut {Protobuf.Field} = {}
  for _, field in ipairs(assert(Protobuf.decode(bytes)):fields()) do
    print(field.number, names[field.wire])
    if field.number ~= 2 then kept[#kept + 1] = field end
  end
  local passed_on = assert(Protobuf.encode(kept))
  local read = assert(Protobuf.decode(passed_on))
  assert(read:int(1) == 7 and not read:has(2) and read:double(3) == 0.5 and read:fixed32(9) == 1)
end

--- A field made by hand: the wire type says which of an integer and bytes its value is.
function Example.encode()
  local bytes = assert(Protobuf.encode({
    { number = 1, wire = Protobuf.VARINT, value = 150 },
    { number = 2, wire = Protobuf.LEN, value = "hi" },
  }))
  print(Codec.hex(bytes))
  assert(Codec.hex(bytes) == "08960112026869")
  local refused, why = Protobuf.encode({ { number = 1, wire = Protobuf.LEN, value = 150 } })
  print(why)
  assert(refused == nil and why ~= "")
end

--- Bytes that are no message are a failure to handle, never a raise: here the last field says it holds five
--- bytes and two follow.
function Example.decode_refuses()
  local message, why = Protobuf.decode("\x08\x01\x12\x05ab")
  print(why)
  assert(message == nil and why == "protobuf: byte 3: the length of field 2 passes the end of the bytes")
end

--- Bytes from a peer are held to bounds: how many fields a message may hold and how deep messages may nest.
--- Past either the answer is nil and why. A reader that walks whatever it is sent, as this one follows field 1
--- down, is stopped by the depth and not by its stack.
function Example.bounds()
  print(Protobuf.default_fields, Protobuf.default_depth)
  local flood = ("\x08\x01"):rep(1000)
  local refused, why = Protobuf.decode(flood, { max_fields = 100 })
  print(why)
  assert(refused == nil and why == "protobuf: the message holds more than 100 fields")

  local nest = ""
  for _ = 1, 50 do
    nest = assert(Protobuf.writer():bytes(1, nest):encode())
  end
  local at = assert(Protobuf.decode(nest, { max_depth = 10 }))
  local depth = 1
  local stopped = ""
  while at:has(1) do
    local inner, inner_why = at:message(1)
    if inner == nil then
      stopped = inner_why
      break
    end
    at = inner
    depth = depth + 1
  end
  print(depth, stopped)
  assert(depth == 10 and stopped == "protobuf: field 1 nests deeper than 10 messages")
end

--- A stream of messages has each behind its length as a varint. The reader takes whole messages from what has
--- arrived so far and keeps the rest: a length or a message the bytes end inside waits for more. The length is
--- the peer's word, any 64 bits, so it is held to a limit before anything waits for that many bytes.
function Example.stream()
  local limit = 1 << 20
  local sent = ""
  for id = 1, 3 do
    local message = assert(Protobuf.writer():int(1, id * 100):encode())
    sent = sent .. Protobuf.varint(#message) .. message
  end

  local buffered = ""
  local ids: mut {integer} = {}
  -- The bytes arrive four at a time.
  for start = 1, #sent, 4 do
    buffered = buffered .. sent:sub(start, start + 3)
    while true do
      local length = Protobuf.read_varint(buffered)
      -- A varint is 10 bytes at most, so a failure with 10 or more to read is no wait for the rest of one.
      if length == nil then
        assert(#buffered < 10, "the stream is not framed")
        break
      end
      -- As an unsigned number: a length above 2^63 - 1 is negative here.
      assert(math.ult(length.value, limit + 1), "a message over the limit")
      local last = length.next + length.value - 1
      if last > #buffered then break end
      local message = assert(Protobuf.decode(buffered:sub(length.next, last)))
      ids[#ids + 1] = assert(message:int(1))
      buffered = buffered:sub(last + 1)
    end
  end
  print(table.concat(ids, " "))
  assert(#ids == 3 and ids[3] == 300 and buffered == "")
end

return Example
