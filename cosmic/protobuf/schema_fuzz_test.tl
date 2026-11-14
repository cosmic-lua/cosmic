--- Fuzz properties for [`cosmic.protobuf.schema`], whose readers take the bytes anyone sends: `decode` never
--- raises and answers a record or a reason and never both, a record it answers is written, and what was written
--- reads back and is written again as the same bytes. They hold for a record that drops what it does not
--- understand and for one that keeps it. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Protobuf = require("cosmic.protobuf")
local Schema = require("cosmic.protobuf.schema")

local enum Color
  "Red"
  "Green"
  "Blue"
end

local record Leaf
  id: integer
  label?: string
end

--- A field of every encoding, singular and repeated, and a message that holds itself.
local record Every
  int?: integer
  sint?: integer
  fixed32?: integer
  sfixed32?: integer
  fixed64?: integer
  sfixed64?: integer
  float?: number
  double?: number
  bool?: boolean
  bytes?: string
  text?: string
  color?: Color
  leaf?: Leaf
  ints: {integer}
  sints: {integer}
  floats: {number}
  doubles: {number}
  bools: {boolean}
  texts: {string}
  colors: {Color}
  leaves: {Leaf}
  kids: {Every}
  count: integer
end

--- The same numbers in a record that keeps what it does not understand.
local record Kept
  int?: integer
  text?: string
  color?: Color
  leaf?: Leaf
  ints: {integer}
  kids: {Kept}
  rest?: Schema.Unknown
end

local COLOR <const> = Schema.enum_of("Color", { Red = 0, Green = 1, Blue = -2 })
local LEAF <const> = Schema.message_of("Leaf", { id = 1, label = Schema.string(2) })
local EVERY <const> = Schema.message_of("Every", {
  int = 1, sint = Schema.sint(2), fixed32 = Schema.fixed32(3), sfixed32 = Schema.sfixed32(4), fixed64 = Schema.fixed64(5),
  sfixed64 = Schema.sfixed64(6), float = Schema.float(7), double = 8, bool = 9, bytes = 10, text = Schema.string(11),
  color = Schema.enum(12, COLOR), leaf = Schema.message(13, LEAF), ints = Schema.field(14, { packed = true }),
  sints = Schema.sint(15), floats = Schema.float(16, { packed = true }), doubles = 17,
  bools = Schema.field(18, { packed = true }), texts = Schema.string(19), colors = Schema.enum(20, COLOR, { packed = true }),
  leaves = Schema.message(21, LEAF), kids = Schema.self(22), count = Schema.field(23, { implicit = true }),
})
local KEPT <const> = Schema.message_of("Kept", {
  int = 1, text = Schema.string(11), color = Schema.enum(12, COLOR), leaf = Schema.message(13, LEAF), ints = 14,
  kids = Schema.self(22),
})

--- Integers at the edges of the format's sizes.
local EDGES <const>: {integer} = { 0, 1, -1, 127, 128, 2147483647, -2147483648, 4294967295, 4294967296,
  math.maxinteger, math.mininteger }

local function gen_integer(src: Fuzz.Source): integer
  if src:int(0, 1) == 0 then return Fuzz.pick(src, EDGES) end
  return src:int(-3, 3)
end

--- A message of the schema's numbers and a few others, each field of a wire type that may or may not be its
--- encoding's, messages `depth` deep.
local function gen_writer(src: Fuzz.Source, depth: integer): Protobuf.Writer
  local writer = Protobuf.writer()
  local count = 0
  while Fuzz.more(src, count, 8) do
    count = count + 1
    local number = src:int(1, 26)
    local kind = src:int(0, if depth > 0 then 8 else 7 end)
    if kind == 0 then
      writer:int(number, gen_integer(src))
    elseif kind == 1 then
      writer:sint(number, gen_integer(src))
    elseif kind == 2 then
      writer:fixed32(number, src:int(-2147483648, 4294967295))
    elseif kind == 3 then
      writer:fixed64(number, gen_integer(src))
    elseif kind == 4 then
      writer:double(number, gen_integer(src) / 3)
    elseif kind == 5 then
      writer:bytes(number, Fuzz.bytes(src, 6))
    elseif kind == 6 then
      writer:string(number, Fuzz.pick(src, { "", "a", "text", "caf\xc3\xa9" }))
    elseif kind == 7 then
      local values: mut {number} = {}
      while Fuzz.more(src, #values, 4) do
        local value = gen_integer(src)
        values[#values + 1] = value
      end
      writer:packed(number, Fuzz.pick(src, { "int", "sint", "fixed64", "double" }), values)
    else
      writer:message(number, gen_writer(src, depth - 1))
    end
  end
  return writer
end

local function gen_bytes(src: Fuzz.Source): string
  local kind = src:int(0, 5)
  if kind == 0 then return Fuzz.bytes(src, 40) end
  local written = assert(gen_writer(src, 3):encode())
  if kind == 1 then return Fuzz.mutate(src, written, src:int(1, 3)) end
  return written
end

--- What holds of one codec over `input`: it answers a record or a reason, and a record goes to bytes and back to
--- the same bytes.
local function settles<T>(codec: Schema.Codec<T>, input: string): boolean, string
  -- A raise fails the property: [`Fuzz.run`] runs the check protected.
  local value, why = codec:decode(input)
  if value == nil then
    if why == "" then return false, "decode answered neither a record nor a reason" end
    return true, ""
  end
  if why ~= "" then return false, "decode answered a record and a reason: " .. why end
  local bytes, trouble = codec:encode(value)
  if bytes == nil then return false, "what was read is not written: " .. trouble end
  local again, unread = codec:decode(bytes)
  if again == nil then return false, "what was written is not read: " .. unread end
  local rewritten, unwritten = codec:encode(again)
  if rewritten == nil then return false, "what was read twice is not written: " .. unwritten end
  if rewritten ~= bytes then return false, "a second round writes other bytes than the first" end
  return true, ""
end

local function test_a_record_that_drops_reads_any_bytes_and_round_trips_what_it_accepts(tmp: string)
  Fuzz.run({
    name = "protobuf schema, dropping",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      return settles(EVERY, input)
    end,
  })
end

local function test_a_record_that_keeps_reads_any_bytes_and_round_trips_what_it_accepts(tmp: string)
  Fuzz.run({
    name = "protobuf schema, keeping",
    dir = tmp,
    gen = gen_bytes,
    check = function(input: string): boolean, string
      return settles(KEPT, input)
    end,
  })
end

local function test_a_record_that_keeps_loses_no_field_it_does_not_name(tmp: string)
  Fuzz.run({
    name = "protobuf schema, unknown fields",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return (assert(gen_writer(src, 0):encode()))
    end,
    check = function(input: string): boolean, string
      local kept = KEPT:decode(input)
      if kept == nil then return true, "" end
      local bytes, why = KEPT:encode(kept)
      if bytes == nil then return false, "what was read is not written: " .. why end
      local before, after = assert(Protobuf.decode(input)), assert(Protobuf.decode(bytes))
      for _, number in ipairs({ 2, 3, 4, 5, 24, 25, 26 }) do
        if #before:repeated_bytes(number) ~= #after:repeated_bytes(number) or before:int(number) ~= after:int(number) or
            before:fixed64(number) ~= after:fixed64(number) or before:fixed32(number) ~= after:fixed32(number) then
          return false, ("field %d, which the record does not name, did not come through"):format(number)
        end
      end
      return true, ""
    end,
  })
end
