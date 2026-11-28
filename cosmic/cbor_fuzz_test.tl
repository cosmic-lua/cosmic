--- Fuzz properties for [`cosmic.cbor`]: [`Cbor.decode`] is total,
--- handling whatever bytes it is handed and never raising, and what
--- it reads is written back as bytes that read the same.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (cosmic/fuzz.tl).

local type Bench = require("cosmic.bench")
local Cbor = require("cosmic.cbor")
local Fuzz = require("cosmic.fuzz")

--- A map of each kind of item, to mutate.
local seed <const> = "\xa6\x01\x02\x20\x58\x20" .. ("\x11"):rep(32) ..
  "\x63key\x9f\x01\xf9\x3e\x00\xf5\xff\x64text\xc1\x1a\x00\x01\x00\x00\x02\x5f\x41\x01\x42\x02\x03\xff" ..
  "\x1b\xff\xff\xff\xff\xff\xff\xff\xff\xbf\x61\x61\xf6\xff"

local function fuzz_decode_is_total_and_reads_back(): Fuzz.Target
  local seeded, seed_why = Cbor.decode(seed)
  assert(seeded ~= nil, tostring(seed_why))
  return Fuzz.target({
    name = "decode a changed item",
    requires = { "decoded" },
    gen = function(src: Fuzz.Source): string
      if src:int(0, 7) == 0 then return Fuzz.bytes(src, 200) end
      return Fuzz.mutate(src, seed, 4)
    end,
    starved = function(input: string): string
      local item, why = Cbor.decode(input)
      if item == nil then return "refused: " .. tostring(why) end
      local written = Cbor.encode(item)
      local _, again_why = Cbor.decode(written)
      return (written:gsub("\n", "\\n")) .. "\n" .. tostring(again_why)
    end,
    check = function(input: string): boolean, string
      local item, why = Cbor.decode(input)
      if item == nil then
        if tostring(why) == "" then return false, "a refusal with no reason" end
        return true, ""
      end
      Fuzz.label("decoded")
      local written = Cbor.encode(item)
      local again, trouble = Cbor.decode(written)
      if again == nil then
        return false, "what was written does not read back: " .. tostring(trouble)
      end
      if Cbor.encode(again) ~= written then
        return false, "what was written reads back as something else"
      end
      return true, ""
    end,
  })
end

--- Times decoding the inputs the property is checked on, most of them
--- changed items: the corpus and a run's first 256 draws.
local function bench_decode_changed_items(b: Bench.B)
  local inputs = Fuzz.inputs(fuzz_decode_is_total_and_reads_back(), 256)
  local bytes = 0
  for _, input in ipairs(inputs) do bytes = bytes + #input end
  b.bytes = bytes
  b.reset()
  for _ = 1, b.n do
    for _, input in ipairs(inputs) do local _, _ = Cbor.decode(input) end
  end
end
