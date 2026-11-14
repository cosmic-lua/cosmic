--- Fuzz properties for [`cosmic.protobuf`], whose decoder takes the bytes anyone sends: it never raises, it
--- answers a message or a reason and never both, every read of what it accepts answers or says why, and what it
--- accepts is written back and read again as the same fields. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Protobuf = require("cosmic.protobuf")

--- Integers at the edges of the format's sizes.
local EDGES <const>: {integer} = { 0, 1, -1, 127, 128, 16383, 16384, 2147483647, -2147483648, 4294967295, 4294967296,
  math.maxinteger, math.mininteger }

local function gen_integer(src: Fuzz.Source): integer
  if src:int(0, 1) == 0 then return Fuzz.pick(src, EDGES) end
  return src:int(-300, 300)
end

--- A few field numbers, so that a number comes more than once in a message, and the greatest.
local function gen_number(src: Fuzz.Source): integer
  return Fuzz.pick(src, { 1, 1, 2, 3, 15, 16, 2047, 536870911 })
end

local KINDS <const>: {Protobuf.Kind} = { "int", "sint", "fixed32", "fixed64", "float", "double" }

--- A message as [`Protobuf.Writer`] writes one: fields of every type, messages `depth` deep.
local function gen_writer(src: Fuzz.Source, depth: integer): Protobuf.Writer
  local writer = Protobuf.writer()
  local count = 0
  while Fuzz.more(src, count, 6) do
    count = count + 1
    local number = gen_number(src)
    local kind = src:int(0, if depth > 0 then 9 else 8 end)
    if kind == 0 then
      writer:int(number, gen_integer(src))
    elseif kind == 1 then
      writer:sint(number, gen_integer(src))
    elseif kind == 2 then
      writer:bool(number, src:int(0, 1) == 1)
    elseif kind == 3 then
      writer:fixed32(number, src:int(-2147483648, 4294967295))
    elseif kind == 4 then
      writer:fixed64(number, gen_integer(src))
    elseif kind == 5 then
      writer:float(number, gen_integer(src) / 4)
    elseif kind == 6 then
      writer:double(number, gen_integer(src) / 3)
    elseif kind == 7 then
      writer:bytes(number, Fuzz.bytes(src, 12))
    elseif kind == 8 then
      local packed = Fuzz.pick(src, KINDS)
      local values: mut {number} = {}
      while Fuzz.more(src, #values, 5) do
        local value = if packed == "fixed32" then src:int(0, 4294967295) else gen_integer(src) end
        values[#values + 1] = value
      end
      writer:packed(number, packed, values)
    else
      writer:message(number, gen_writer(src, depth - 1))
    end
  end
  return writer
end

local function gen_message(src: Fuzz.Source): string
  local bytes = assert(gen_writer(src, 3):encode())
  return bytes
end

--- Field 1 of a message, inside field 1 of a message, and so on, `levels` deep.
local function nested(levels: integer): string
  local bytes = ""
  for _ = 1, levels do
    bytes = assert(Protobuf.writer():bytes(1, bytes):encode())
  end
  return bytes
end

local DEEP <const> = nested(120)

--- "" where the two lists hold the same fields, or what differs.
local function fields_differ(got: {Protobuf.Field}, want: {Protobuf.Field}): string
  if #got ~= #want then return ("%d fields became %d"):format(#want, #got) end
  for i, field in ipairs(want) do
    local other = assert(got[i])
    if other.number ~= field.number or other.wire ~= field.wire or other.value ~= field.value then
      return ("field %d (number %d) differs"):format(i, field.number)
    end
  end
  return ""
end

--- "" where a result that may be a failure is a value and no reason, or a reason and no value; or what is wrong
--- with it.
local function shape_trouble(what: string, absent: boolean, why: string): string
  if absent and why == "" then return what .. " failed without a reason" end
  if absent and why:find("^protobuf: ") == nil then
    return what .. " failed with a reason of another shape: " .. why
  end
  if not absent and why ~= "" then return what .. " answered with a reason: " .. why end
  return ""
end

--- Every read of every number `message` holds, and of the messages inside it. "" where each answers as its
--- doc says, or what did not. `budget` bounds the messages visited, which a hostile input could otherwise
--- multiply: each length-delimited field is read as a message once merged and once by itself.
local record Walk
  mut left: integer
end

local function read_all(message: Protobuf.Message, walk: Walk): string
  local fields = message:fields()
  local numbers: mut {integer: boolean} = {}
  local last: mut {integer: Protobuf.Field} = {}
  local lens: mut {integer: integer} = {}
  for _, field in ipairs(fields) do
    numbers[field.number] = true
    last[field.number * 8 + field.wire] = field
    if field.wire == Protobuf.LEN then lens[field.number] = (lens[field.number] or 0) + 1 end
    if field.wire ~= Protobuf.VARINT and field.wire ~= Protobuf.FIXED64 and field.wire ~= Protobuf.LEN and
        field.wire ~= Protobuf.FIXED32 then
      return ("field %d has the wire type %d"):format(field.number, field.wire)
    end
    if field.number < 1 or field.number > 536870911 then
      return ("a field has the number %d"):format(field.number)
    end
  end
  for number in pairs(numbers) do
    if not message:has(number) then return ("field %d is listed and is not had"):format(number) end
    local varint, four, eight, len = last[number * 8 + Protobuf.VARINT], last[number * 8 + Protobuf.FIXED32],
      last[number * 8 + Protobuf.FIXED64], last[number * 8 + Protobuf.LEN]
    -- A read of one value answers the last field of its wire type, and nil where there is none.
    if message:int(number) ~= (if varint ~= nil then varint.value else nil end) then
      return ("int(%d) is not the last varint"):format(number)
    end
    if (message:sint(number) == nil) ~= (varint == nil) or (message:bool(number) == nil) ~= (varint == nil) then
      return ("sint(%d) or bool(%d) is there without a varint, or is not with one"):format(number, number)
    end
    if message:fixed32(number) ~= (if four ~= nil then four.value else nil end) then
      return ("fixed32(%d) is not the last 4 bytes"):format(number)
    end
    if (message:sfixed32(number) == nil) ~= (four == nil) or (message:float(number) == nil) ~= (four == nil) then
      return ("sfixed32(%d) or float(%d) is there without 4 bytes, or is not with them"):format(number, number)
    end
    if message:fixed64(number) ~= (if eight ~= nil then eight.value else nil end) then
      return ("fixed64(%d) is not the last 8 bytes"):format(number)
    end
    if (message:double(number) == nil) ~= (eight == nil) then
      return ("double(%d) is there without 8 bytes, or is not with them"):format(number)
    end
    if message:bytes(number) ~= (if len ~= nil then len.value else nil end) then
      return ("bytes(%d) is not the last length-delimited field"):format(number)
    end
    local text = message:string(number)
    if text ~= nil and (text ~= message:bytes(number) or utf8.len(text) == nil) then
      return ("string(%d) is not the bytes, or is not UTF-8"):format(number)
    end
    if #message:repeated_bytes(number) ~= (lens[number] or 0) then
      return ("repeated_bytes(%d) is not every length-delimited field"):format(number)
    end

    local ints, ints_why = message:repeated_int(number)
    local trouble = shape_trouble("repeated_int", ints == nil, ints_why)
    local sints, sints_why = message:repeated_sint(number)
    if trouble == "" then trouble = shape_trouble("repeated_sint", sints == nil, sints_why) end
    if (ints == nil) ~= (sints == nil) or ints ~= nil and sints ~= nil and #ints ~= #sints then
      return ("repeated_int(%d) and repeated_sint(%d) read other varints"):format(number, number)
    end
    if ints ~= nil and len ~= nil and #ints > 1 then Fuzz.label("read a packed field") end
    if ints == nil then Fuzz.label("refused a packed field") end
    local fours, fours_why = message:repeated_fixed32(number)
    if trouble == "" then trouble = shape_trouble("repeated_fixed32", fours == nil, fours_why) end
    local signed, signed_why = message:repeated_sfixed32(number)
    if trouble == "" then
      trouble = shape_trouble("repeated_sfixed32", signed == nil, signed_why)
    end
    local floats, floats_why = message:repeated_float(number)
    if trouble == "" then trouble = shape_trouble("repeated_float", floats == nil, floats_why) end
    if (fours == nil) ~= (floats == nil) or (fours == nil) ~= (signed == nil) or
        fours ~= nil and floats ~= nil and #fours ~= #floats then
      return ("the reads of 4 bytes of field %d disagree"):format(number)
    end
    local eights, eights_why = message:repeated_fixed64(number)
    if trouble == "" then trouble = shape_trouble("repeated_fixed64", eights == nil, eights_why) end
    local doubles, doubles_why = message:repeated_double(number)
    if trouble == "" then
      trouble = shape_trouble("repeated_double", doubles == nil, doubles_why)
    end
    if (eights == nil) ~= (doubles == nil) or eights ~= nil and doubles ~= nil and #eights ~= #doubles then
      return ("the reads of 8 bytes of field %d disagree"):format(number)
    end
    if trouble ~= "" then return ("field %d: %s"):format(number, trouble) end

    if walk.left > 0 then
      walk.left = walk.left - 1
      local inner, inner_why = message:message(number)
      trouble = shape_trouble("message", inner == nil, inner_why)
      if trouble ~= "" then return ("field %d: %s"):format(number, trouble) end
      local each, each_why = message:repeated_message(number)
      trouble = shape_trouble("repeated_message", each == nil, each_why)
      if trouble ~= "" then return ("field %d: %s"):format(number, trouble) end
      -- The parts are read by the same rules as the whole, so they fail together unless it is the fields
      -- of all of them that pass the bound.
      if inner ~= nil and each == nil then
        return ("field %d is one message and not several"):format(number)
      end
      if inner == nil then
        if inner_why:find("nests deeper", 1, true) ~= nil then
          Fuzz.label("past max_depth")
        else
          Fuzz.label("refused an embedded message")
        end
      end
      if inner ~= nil and each ~= nil then
        if #each ~= (lens[number] or 0) then
          return ("repeated_message(%d) is not every part"):format(number)
        end
        local total = 0
        for _, part in ipairs(each) do
          total = total + #part:fields()
        end
        if total ~= #inner:fields() then
          return ("message(%d) is not its parts merged"):format(number)
        end
        if total > 0 then Fuzz.label("read an embedded message") end
        local below = read_all(inner, walk)
        if below ~= "" then return ("in field %d: %s"):format(number, below) end
      end
    end
  end
  return ""
end

local function test_decode_is_total_and_what_it_reads_is_written_back(tmp: string)
  Fuzz.run({
    name = "protobuf decode",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local kind = src:int(0, 7)
      if kind == 0 then return Fuzz.bytes(src, 48) end
      if kind <= 2 then return Fuzz.mutate(src, DEEP, src:int(0, 2)) end
      -- A length-delimited field that is no packed varints: its last has no end.
      if kind == 3 then return gen_message(src) .. "\x0a\x03\x01\x02\x80" end
      return Fuzz.mutate(src, gen_message(src), if kind == 4 then 0 else 3 end)
    end,
    check = function(input: string): boolean, string
      local message, why = Protobuf.decode(input)
      local trouble = shape_trouble("decode", message == nil, why)
      if trouble ~= "" then return false, trouble end
      -- The bound on fields refuses exactly the messages past it.
      local few, few_why = Protobuf.decode(input, { max_fields = 3 })
      trouble = shape_trouble("decode under max_fields", few == nil, few_why)
      if trouble ~= "" then return false, trouble end
      if message == nil then
        if few ~= nil then return false, "refused, and read under a bound" end
        Fuzz.label("refused")
        return true, ""
      end
      Fuzz.label("read")
      local fields = message:fields()
      if (few == nil) ~= (#fields > 3) then
        return false, "max_fields is not the fields a message may hold"
      end
      if few == nil then Fuzz.label("past max_fields") end
      -- A field is two bytes at least.
      if #fields * 2 > #input then return false, "more fields than the bytes could hold" end

      trouble = read_all(message, { left = 400 })
      if trouble ~= "" then return false, trouble end

      -- What was read is written, in no more bytes, and what is written holds the same fields: reading and
      -- writing it again changes no byte.
      local bytes, encode_why = Protobuf.encode(fields)
      if bytes == nil then return false, "what was read is not written: " .. encode_why end
      if #bytes > #input then return false, "written back in more bytes than were read" end
      local again, again_why = Protobuf.decode(bytes)
      if again == nil then return false, "what was written is not read: " .. again_why end
      trouble = fields_differ(again:fields(), fields)
      if trouble ~= "" then return false, "written and read again, " .. trouble end
      local twice, twice_why = Protobuf.encode(again:fields())
      if twice ~= bytes then return false, "written twice, it differs: " .. twice_why end
      return true, ""
    end,
    requires = { "refused", "read", "past max_fields", "read an embedded message", "refused an embedded message",
      "past max_depth", "read a packed field", "refused a packed field" },
    shares = { refused = 0.1, read = 0.2, ["read an embedded message"] = 0.05 },
  })
end

local function test_what_a_writer_writes_is_read_as_written(tmp: string)
  Fuzz.run({
    name = "protobuf writer round trip",
    dir = tmp,
    gen = gen_message,
    check = function(input: string): boolean, string
      local message, why = Protobuf.decode(input)
      if message == nil then return false, "what was written is not read: " .. why end
      -- A writer writes each varint in the fewest bytes, as `encode` does, so the fields written back are the
      -- bytes.
      local bytes, encode_why = Protobuf.encode(message:fields())
      if bytes ~= input then return false, "read and written again, it differs: " .. encode_why end
      local trouble = read_all(message, { left = 400 })
      if trouble ~= "" then return false, trouble end
      return true, ""
    end,
  })
end

local function test_read_varint_is_total_and_reads_what_varint_writes(tmp: string)
  Fuzz.run({
    name = "protobuf varint",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local kind = src:int(0, 3)
      if kind == 0 then return Fuzz.bytes(src, 14) end
      local written = Protobuf.varint(gen_integer(src))
      if kind == 1 then return written end
      if kind == 2 then return written:sub(1, src:int(0, #written)) end
      -- More bytes than it needs, and more than a varint may be.
      local padded = written:sub(1, -2) .. string.char(assert(written:byte(-1)) | 0x80)
      return padded .. ("\x80"):rep(src:int(0, 10)) .. "\x00"
    end,
    check = function(input: string): boolean, string
      local read, why = Protobuf.read_varint(input)
      local trouble = shape_trouble("read_varint", read == nil, why)
      if trouble ~= "" then return false, trouble end
      if read == nil then
        Fuzz.label("refused")
        -- With fewer than 10 bytes, the only failure is the bytes ending inside it.
        if #input < 10 and (why ~= "protobuf: the bytes end inside a varint" or input:find("[\x00-\x7f]") ~= nil) then
          return false, "refused short bytes that hold a whole varint, or for another reason: " .. why
        end
        return true, ""
      end
      Fuzz.label("read")
      if read.next < 2 or read.next > 11 or read.next > #input + 1 then
        return false, ("it ends at %d of %d bytes"):format(read.next, #input)
      end
      local written = Protobuf.varint(read.value)
      if #written > read.next - 1 then
        return false, "written in more bytes than it was read from"
      end
      local back = Protobuf.read_varint(written)
      if back == nil or back.value ~= read.value or back.next ~= #written + 1 then
        return false, ("%d is not read back from what varint writes"):format(read.value)
      end
      -- Anywhere in the bytes it reads the same as from their start.
      local moved = Protobuf.read_varint("\xff\xff" .. input, 3)
      if moved == nil or moved.value ~= read.value or moved.next ~= read.next + 2 then
        return false, "read otherwise from a later position"
      end
      return true, ""
    end,
    requires = { "refused", "read" },
    shares = { refused = 0.1, read = 0.3 },
  })
end
