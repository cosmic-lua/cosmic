--- Fuzz properties for [`cosmic.cbor`]: [`Cbor.decode`] is total,
--- answering for whatever bytes it is handed and never raising, and what
--- it reads is written back as bytes that read the same.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Cbor = require("cosmic.cbor")
local Fuzz = require("build.fuzz")

--- A map of each kind of item, to mutate.
local seed <const> = "\xa6\x01\x02\x20\x58\x20" .. ("\x11"):rep(32) ..
  "\x63key\x9f\x01\xf9\x3e\x00\xf5\xff\x64text\xc1\x1a\x00\x01\x00\x00\x02\x5f\x41\x01\x42\x02\x03\xff" ..
  "\x1b\xff\xff\xff\xff\xff\xff\xff\xff\xbf\x61\x61\xf6\xff"

local function test_decode_is_total_and_reads_back(tmp: string)
  assert(Cbor.decode(seed) ~= nil)
  Fuzz.run({
    name = "decode a changed item",
    dir = tmp,
    requires = { "decoded" },
    gen = function(src: Fuzz.Source): string
      if src:int(0, 7) == 0 then return Fuzz.bytes(src, 200) end
      return Fuzz.mutate(src, seed, 4)
    end,
    starved = function(input: string)
      local item, _ = Cbor.decode(input)
      if item ~= nil then local _, _ = Cbor.decode(Cbor.encode(item)) end
    end,
    check = function(input: string): boolean, string
      local item, why = Cbor.decode(input)
      if item == nil then
        if why == "" then return false, "a refusal with no reason" end
        return true, ""
      end
      Fuzz.label("decoded")
      local written = Cbor.encode(item)
      local again, trouble = Cbor.decode(written)
      if again == nil then return false, "what was written does not read back: " .. trouble end
      if Cbor.encode(again) ~= written then
        return false, "what was written reads back as something else"
      end
      return true, ""
    end,
  })
end
