--- Fuzz properties for [`cosmic.codec`]: every decoder takes back what its
--- encoder writes, and every decoder is total -- whatever text it is
--- handed, it returns bytes or a failure and never raises. What a
--- decoder accepts it accepts exactly: the bytes encode back to the
--- text they came from. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (cosmic/fuzz.tl).

local Codec = require("cosmic.codec")
local type Failure = require("cosmic.failure")
local Fuzz = require("cosmic.fuzz")

local record Pair
  name: string
  encode: function(string): string
  decode: function(string): (string) | (nil, Failure)
end

local PAIRS <const>: {Pair} = {
  { name = "hex", encode = Codec.hex, decode = Codec.unhex },
  { name = "base64", encode = Codec.base64, decode = Codec.unbase64 },
  { name = "base64url", encode = Codec.base64url, decode = Codec.unbase64url },
}

--- Characters a decoder has to judge: every alphabet's, both cases of
--- hex, padding, whitespace, and the bytes at either end.
local TEXT <const> = "0123456789abcdefABCDEFxyzXYZ+/-_==\n \0\xff"

local function gen_text(src: Fuzz.Source): string
  if src:int(0, 1) == 0 then
    return Fuzz.bytes(src, 64)
  end
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 64) do
    local at = src:int(1, #TEXT)
    out[#out + 1] = TEXT:sub(at, at)
  end
  return table.concat(out)
end

local function test_every_decoder_takes_back_what_its_encoder_writes(tmp: string)
  for _, p in ipairs(PAIRS) do
    Fuzz.run({
      name = p.name .. " round trip",
      dir = tmp,
      gen = function(src: Fuzz.Source): string
        return Fuzz.bytes(src, 300)
      end,
      check = function(input: string): boolean, string
        local text = p.encode(input)
        local back, why = p.decode(text)
        if back ~= input then
          return false, ("%q decoded to %q: %s"):format(text, tostring(back), tostring(why))
        end
        return true, ""
      end,
    })
  end
end

local function test_every_decoder_is_total_and_exact(tmp: string)
  for _, p in ipairs(PAIRS) do
    Fuzz.run({
      name = p.name .. " decoder total",
      dir = tmp,
      gen = function(src: Fuzz.Source): string
        local text = gen_text(src)
        if src:int(0, 2) == 0 then
          return Fuzz.mutate(src, p.encode(text), 3)
        end
        return text
      end,
      check = function(input: string): boolean, string
        local bytes, why = p.decode(input)
        if bytes == nil then
          if tostring(why) == "" then return false, "refused without a reason" end
          return true, ""
        end
        local again = p.encode(bytes)
        if p.name == "hex" then
          again = again:lower()
          input = input:lower()
        end
        if again ~= input then
          return false, ("accepted %q, which encodes back as %q"):format(input, again)
        end
        return true, ""
      end,
    })
  end
end

--- [`Codec.unbase64_lines`] judges text as [`Codec.unbase64`] judges it
--- with every CR and LF taken out: the same bytes, or a refusal of both.
local function fuzz_unbase64_lines_is_unbase64_without_line_breaks(): Fuzz.Target
  return Fuzz.target({
    name = "base64 lines",
    gen = function(src: Fuzz.Source): string
      local text = if src:int(0, 1) == 0 then Codec.base64(Fuzz.bytes(src, 200)) else gen_text(src) end
      local out: mut {string} = {}
      for i = 1, #text do
        out[#out + 1] = text:sub(i, i)
        local roll = src:int(0, 15)
        if roll == 0 then
          out[#out + 1] = "\r\n"
        elseif roll == 1 then
          out[#out + 1] = "\n"
        elseif roll == 2 then
          out[#out + 1] = "\r"
        end
      end
      return table.concat(out)
    end,
    check = function(input: string): boolean, string
      local lines, why = Codec.unbase64_lines(input)
      local flat, _ = Codec.unbase64((input:gsub("[\r\n]", "")))
      if lines ~= flat then
        return false, ("%q: lines %q (%s), flat %q"):format(input, tostring(lines), tostring(why), tostring(flat))
      end
      if lines == nil and tostring(why) == "" then return false, "refused without a reason" end
      return true, ""
    end,
  })
end
