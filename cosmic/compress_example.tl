--- Worked examples for [`cosmic.compress`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Compress = require("cosmic.compress")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

local Example = {}

--- Bytes compressed whole into a gzip stream, and expanded back.
function Example.deflate()
  local text = string.rep("cosmic ", 100)
  local packed = assert(Compress.deflate("gzip", text))
  print(#text, #packed)
  assert(#packed < #text)
  local back = assert(Compress.inflate("gzip", packed))
  assert(back == text)
end

--- A bound on what `inflate` may produce, for a body from outside: a
--- small input can expand past any memory, and past `max_bytes` it fails.
function Example.inflate()
  local packed = assert(Compress.deflate("zlib", string.rep("a", 10000)))
  local back, why = Compress.inflate("zlib", packed, 100)
  print(why)
  assert(back == nil and why ~= "")
end

--- A zstd stream written a chunk at a time and read back through a
--- decoder that holds each update's output to a bound.
function Example.zstd_encoder()
  local enc = assert(Compress.zstd_encoder(9))
  local parts: mut {string} = {}
  for _ = 1, 100 do parts[#parts + 1] = assert(enc:update("cosmic zstd ")) end
  parts[#parts + 1] = assert(enc:finish())
  local packed = table.concat(parts)
  local dec = assert(Compress.zstd_decoder())
  local first = assert(dec:update(packed, 256))
  local out: mut {string} = { first }
  while dec:pending() do out[#out + 1] = assert(dec:update("", 256)) end
  out[#out + 1] = assert(dec:finish())
  print(#packed, #table.concat(out))
  assert(table.concat(out) == string.rep("cosmic zstd ", 100))
end

return Example
