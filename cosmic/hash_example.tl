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

--- `Hash.hex_sha256` of the empty string: never a special case, since
--- SHA-256 is defined on every length, including zero.
function Example.hex_sha256_of_the_empty_string()
  local digest = Hash.hex_sha256("")
  print(digest)
  assert(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "unexpected digest: " .. digest)
end

return Example
