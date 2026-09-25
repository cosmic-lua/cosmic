--- Worked examples for `cosmic.compress`, shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Compress = require("cosmic.compress")

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
--- small input can expand past any memory, and past `max` it fails.
function Example.inflate()
  local packed = assert(Compress.deflate("zlib", string.rep("a", 10000)))
  local back, why = Compress.inflate("zlib", packed, 100)
  print(why)
  assert(back == nil and why ~= "")
end

return Example
