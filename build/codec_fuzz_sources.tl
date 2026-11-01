--- Inputs for the fuzz properties of `cosmic codec` (build/codec.tl): text a decoder has to judge, and the cuttings that
--- the streaming coders are fed it in. Both codec fuzz tests draw from here.
local Fuzz = require("build.fuzz")

local record Sources
  --- One text drawn from `src`: raw bytes half the time, else characters a decoder has to judge.
  text: function(src: Fuzz.Source): string
  --- A cutting of an input drawn from `src`: the sizes of chunks, empty ones included, packed one byte each so that
  --- shrinking can cut any of them.
  cuts: function(src: Fuzz.Source): string
end

--- Characters a decoder has to judge: every alphabet's, both cases of
--- hex, padding, whitespace, and the bytes at either end.
local TEXT <const> = "0123456789abcdefABCDEFxyzXYZ+/-_==\n \t\r\0\xff"

function Sources.text(src: Fuzz.Source): string
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

function Sources.cuts(src: Fuzz.Source): string
  local sizes: mut {string} = {}
  while Fuzz.more(src, #sizes, 24) do
    sizes[#sizes + 1] = string.char(src:int(0, 9))
  end
  return table.concat(sizes)
end

return Sources
