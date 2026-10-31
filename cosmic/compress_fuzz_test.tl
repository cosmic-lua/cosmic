--- Fuzz properties for [`cosmic.compress`]'s zstd codec: decoding any
--- bytes is total, gives no update more than it was asked for, and
--- answers the same however the input is split; and what the encoder
--- writes, at any level and in any chunks, decodes to what went in.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Compress = require("cosmic.compress")
local Fuzz = require("build.fuzz")

--- `plain` through a fresh zstd encoder at `level`, whole.
local function packed(plain: string, level: integer): string
  local enc = assert(Compress.zstd_encoder(level))
  return assert(enc:update(plain)) .. assert(enc:finish())
end

--- Decodes `input` in pieces of `step` bytes, at most `max_bytes` an
--- update, draining each piece: the output and "", or what came out
--- before the failure and why. Raises when an update gives more than
--- `max_bytes`.
local function decode(input: string, step: integer, max_bytes: integer): string, string
  local dec = assert(Compress.zstd_decoder(1 << 23))
  local parts: {string} = {}
  local pos = 1
  repeat
    local piece = input:sub(pos, pos + step - 1)
    pos = pos + step
    while true do
      local out, trouble = dec:update(piece, max_bytes)
      if out == nil then return table.concat(parts), trouble end
      assert(#out <= max_bytes, ("%d bytes from an update limited to %d"):format(#out, max_bytes))
      parts[#parts + 1] = out
      if not dec:pending() then break end
      piece = ""
    end
  until pos > #input
  local last, trouble = dec:finish()
  if last == nil then return table.concat(parts), trouble end
  parts[#parts + 1] = last
  return table.concat(parts), ""
end

--- A zstd frame of a few dozen drawn bytes, at a drawn level, edited a
--- few times or not at all, and how to split and bound its decoding:
--- [`Fuzz.pack`] fields of the input, the step and the output limit.
local function gen_frame(src: Fuzz.Source): string
  local plain = Fuzz.bytes(src, 64) .. string.rep(Fuzz.bytes(src, 4), src:int(0, 40))
  local frame = packed(plain, src:int(1, 9))
  -- Unedited one time in four, so decoding is seen to succeed.
  if src:int(0, 3) > 0 then frame = Fuzz.mutate(src, frame, 4) end
  return Fuzz.pack({ frame, tostring(src:int(1, 16)), tostring(src:int(1, 64)) })
end

local function test_decoding_any_bytes_is_total_bounded_and_split_alike()
  Fuzz.run({
    name = "zstd decode total",
    gen = gen_frame,
    requires = { "decoded", "refused" },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local frame = fields[1] or ""
      local step = math.max(1, math.tointeger(tonumber(fields[2] or "1")) or 1)
      local max_bytes = math.max(1, math.tointeger(tonumber(fields[3] or "1")) or 1)
      local whole, whole_trouble = decode(frame, math.max(1, #frame), 1 << 20)
      local split, split_trouble = decode(frame, step, max_bytes)
      Fuzz.label(whole_trouble == "" and "decoded" or "refused")
      if (whole_trouble == "") ~= (split_trouble == "") then
        return false, ("whole: %q, split: %q"):format(whole_trouble, split_trouble)
      end
      if whole_trouble == "" and whole ~= split then
        return false, "the split decoding gave other bytes"
      end
      return true, ""
    end,
  })
end

local function test_what_the_encoder_writes_decodes_to_what_went_in()
  Fuzz.run({
    name = "zstd round trip",
    gen = function(src: Fuzz.Source): string
      local fields: {string} = { tostring(src:int(1, 19)) }
      repeat
        fields[#fields + 1] = Fuzz.bytes(src, 32) .. string.rep(Fuzz.bytes(src, 3), src:int(0, 30))
      until not Fuzz.more(src, #fields - 1, 6)
      return Fuzz.pack(fields)
    end,
    requires = { "round-tripped" },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local level = math.tointeger(tonumber(fields[1] or "3")) or 3
      if level < 1 or level > 19 then level = 3 end
      local enc = assert(Compress.zstd_encoder(level))
      local parts: {string} = {}
      for i = 2, #fields do parts[#parts + 1] = assert(enc:update(fields[i])) end
      parts[#parts + 1] = assert(enc:finish())
      local plain = table.concat(fields, "", 2)
      local out, trouble = decode(table.concat(parts), 7, 100)
      if trouble ~= "" then return false, trouble end
      if out ~= plain then return false, ("%d bytes in, %d out"):format(#plain, #out) end
      Fuzz.label("round-tripped")
      return true, ""
    end,
  })
end
