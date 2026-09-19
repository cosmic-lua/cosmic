--- Worked examples for `cosmic.hash`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Hash = require("cosmic.hash")

local Example = {}

--- The hexadecimal SHA-256 of a short string.
function Example.hex_sha256()
  local digest = Hash.hex_sha256("cosmic")
  print(digest)
  assert(digest == "01307b41e7ff0bb31cca03fb7ff5bea9fdb3dd83afaca63d588a0c07e7ae98b8",
    "unexpected digest: " .. digest)
end

return Example
