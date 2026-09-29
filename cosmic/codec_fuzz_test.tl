--- Fuzz properties for `cosmic.codec`: every decoder takes back what its
--- encoder writes, and every decoder is total -- whatever text it is
--- handed, it answers bytes or a failure and never raises. What a
--- decoder accepts it accepts exactly: the bytes encode back to the
--- text they came from. The incremental coders answer as the
--- whole-string ones do, the same text or bytes or the same reason,
--- however the input is cut into chunks. `FUZZ_SEED` and `FUZZ_ITERS`
--- pick the inputs (build/fuzz/init.tl).

local Codec = require("cosmic.codec")
local Fuzz = require("build.fuzz")

local record Pair
  name: Codec.Name
  encode: function(string): string
  decode: function(string): string | nil, string
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
  local out: {string} = {}
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
          return false, ("%q decoded to %q: %s"):format(text, tostring(back), why)
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
          if why == "" then return false, "refused without a reason" end
          return true, ""
        end
        if why ~= "" then return false, "accepted with a reason: " .. why end
        local again = p.encode(bytes)
        if p.name == "hex" then again = again:lower(); input = input:lower() end
        if again ~= input then
          return false, ("accepted %q, which encodes back as %q"):format(input, again)
        end
        return true, ""
      end,
    })
  end
end

--- Draws a cutting of the input: sizes of chunks, empty ones included,
--- packed one byte each so that shrinking can cut any of them.
local function gen_cuts(src: Fuzz.Source): string
  local sizes: {string} = {}
  while Fuzz.more(src, #sizes, 24) do
    sizes[#sizes + 1] = string.char(src:int(0, 9))
  end
  return table.concat(sizes)
end

--- What `coder` answers to `input` cut by the sizes `cuts` bytes give,
--- then a byte at a time: the output, or nil and the reason, and
--- whether a chunk was empty.
local function run_cut(coder: Codec.Coder, input: string, cuts: string): string | nil, string, boolean
  local out: {string} = {}
  local at, k = 1, 0
  local empty = false
  while at <= #input do
    k = k + 1
    local size = k <= #cuts and cuts:byte(k) or 1
    if size == 0 then empty = true end
    local part, why = coder:update(input:sub(at, at + size - 1))
    if part == nil then return nil, why, empty end
    out[#out + 1] = part
    at = at + size
  end
  local last, why = coder:finish()
  if last == nil then return nil, why, empty end
  out[#out + 1] = last
  return table.concat(out), "", empty
end

local function test_chunked_encoding_equals_the_whole_string(tmp: string)
  for _, p in ipairs(PAIRS) do
    Fuzz.run({
      name = p.name .. " chunked encode",
      dir = tmp,
      gen = function(src: Fuzz.Source): string
        return Fuzz.pack({ Fuzz.bytes(src, 200), gen_cuts(src) })
      end,
      check = function(input: string): boolean, string
        local fields = Fuzz.unpack(input)
        local got, why, empty = run_cut(Codec.encoder(p.name), fields[1], fields[2])
        if got ~= p.encode(fields[1]) then
          return false, ("%q cut %q gave %q: %s"):format(fields[1], fields[2], tostring(got), why)
        end
        Fuzz.label(#fields[1] % 3 == 0 and "whole groups" or "leftover")
        if empty then Fuzz.label("empty chunk") end
        return true, ""
      end,
      requires = { "whole groups", "leftover", "empty chunk" },
    })
  end
end

local function test_chunked_decoding_equals_the_whole_string(tmp: string)
  for _, p in ipairs(PAIRS) do
    Fuzz.run({
      name = p.name .. " chunked decode",
      dir = tmp,
      gen = function(src: Fuzz.Source): string
        local text = gen_text(src)
        if src:int(0, 2) == 0 then
          text = Fuzz.mutate(src, p.encode(Fuzz.bytes(src, 60)), 2)
        elseif src:int(0, 1) == 0 then
          text = p.encode(Fuzz.bytes(src, 60))
        end
        return Fuzz.pack({ text, gen_cuts(src) })
      end,
      check = function(input: string): boolean, string
        local fields = Fuzz.unpack(input)
        local want, want_why = p.decode(fields[1])
        local got, why, empty = run_cut(Codec.decoder(p.name), fields[1], fields[2])
        if got ~= want or why ~= want_why then
          return false, ("%q cut %q: %s | %s, whole %s | %s"):format(
            fields[1], fields[2], tostring(got), why, tostring(want), want_why)
        end
        Fuzz.label(want == nil and "refused" or "accepted")
        if empty then Fuzz.label("empty chunk") end
        return true, ""
      end,
      requires = { "refused", "accepted", "empty chunk" },
    })
  end
end
