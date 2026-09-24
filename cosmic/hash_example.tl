--- Worked examples for `cosmic.hash`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
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

--- A raw digest under any algorithm the core knows, as bytes:
--- `Codec.hex` spells it for a person.
function Example.digest()
  local raw = Hash.digest("sha1", "cosmic")
  print(#raw, Codec.hex(raw))
  assert(#raw == 20)
  assert(Hash.digest("sha256", "cosmic") == Hash.sha256("cosmic"))
end

--- A message authentication code: only a holder of the key can make
--- the same one for the same message.
function Example.hmac()
  local code = Codec.hex(Hash.hmac("sha256", "key",
    "The quick brown fox jumps over the lazy dog"))
  print(code)
  assert(code == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8", code)
end

return Example
