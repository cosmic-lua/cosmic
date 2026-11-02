--- Fuzz properties for `cosmic codec`'s streaming coders (build/codec.tl):
--- each answers as [`cosmic.codec`]'s whole-string functions do, the same
--- text or bytes or the same reason, however the input is cut into
--- chunks. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Codec = require("cosmic.codec")
local Fuzz = require("build.fuzz")
local Sources = require("build.codec_fuzz_sources")
local codec = require("build.codec")
local support = require("build.test_support_fixture")

local record Pair
  name: codec.Name
  encode: function(string): string
  decode: function(string): string?, string
end

local PAIRS <const>: {Pair} = {
  { name = "hex", encode = Codec.hex, decode = Codec.unhex },
  { name = "base64", encode = Codec.base64, decode = Codec.unbase64 },
  { name = "base64url", encode = Codec.base64url, decode = Codec.unbase64url },
}

--- What `coder` answers to `input` cut by the sizes `cuts` bytes give,
--- then a byte at a time: the output, or nil and the reason, and
--- whether a chunk was empty.
local function run_cut(coder: codec.Coder, input: string, cuts: string): string?, string, boolean
  local out: mut {string} = {}
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
        return Fuzz.pack({ Fuzz.bytes(src, 200), Sources.cuts(src) })
      end,
      check = function(input: string): boolean, string
        local fields = Fuzz.unpack(input)
        local got, why, empty = run_cut(codec.encoder(p.name), support.nth(fields, 1), support.nth(fields, 2))
        if got ~= p.encode(support.nth(fields, 1)) then
          return false, ("%q cut %q gave %q: %s"):format(fields[1], fields[2], tostring(got), why)
        end
        Fuzz.label(if #support.nth(fields, 1) % 3 == 0 then "whole groups" else "leftover" end)
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
        local text = Sources.text(src)
        if src:int(0, 2) == 0 then
          text = Fuzz.mutate(src, p.encode(Fuzz.bytes(src, 60)), 2)
        elseif src:int(0, 1) == 0 then
          text = p.encode(Fuzz.bytes(src, 60))
        end
        return Fuzz.pack({ text, Sources.cuts(src) })
      end,
      check = function(input: string): boolean, string
        local fields = Fuzz.unpack(input)
        local want, want_why = p.decode(support.nth(fields, 1))
        local got, why, empty = run_cut(codec.decoder(p.name), support.nth(fields, 1), support.nth(fields, 2))
        if got ~= want or why ~= want_why then
          return false, ("%q cut %q: %s | %s, whole %s | %s"):format(
            fields[1], fields[2], tostring(got), why, tostring(want), want_why)
        end
        Fuzz.label(if want == nil then "refused" else "accepted" end)
        if empty then Fuzz.label("empty chunk") end
        return true, ""
      end,
      requires = { "refused", "accepted", "empty chunk" },
    })
  end
end
