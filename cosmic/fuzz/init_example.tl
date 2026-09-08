--- A byte-string property with a bounded deterministic sample.
local function Example_hex_round_trip()
  local fuzz = require("cosmic.fuzz")
  local codec = require("cosmic.codec")
  fuzz.assert_ok(fuzz.run({
        name = "example_hex_round_trip",
        iters = 8,
        gen = function(src: fuzz.Recorder): string
          return fuzz.bytes(src, 32)
        end,
        check = function(input: string): boolean, string
          local decoded, err = codec.decode_hex(codec.encode_hex(input))
          return decoded == input, err or "hex round trip changed bytes"
        end,
      }))
  print("pass")
  -- Output:
  -- pass
end

local _ = Example_hex_round_trip
