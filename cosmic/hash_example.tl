--- Worked examples for [`cosmic.hash`], shown by `cosmic docs` under the
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

--- [`Hash.hex_sha256`] of the empty string: never a special case, since
--- SHA-256 is defined on every length, including zero.
function Example.hex_sha256_of_the_empty_string()
  local digest = Hash.hex_sha256("")
  print(digest)
  assert(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "unexpected digest: " .. digest)
end

--- A raw digest under any algorithm the core knows, as bytes:
--- [`Codec.hex`] spells it for a person.
function Example.digest()
  local raw = Hash.digest("sha1", "cosmic")
  print(#raw, Codec.hex(raw))
  assert(#raw == 20)
  assert(Hash.digest("sha256", "cosmic") == Hash.sha256("cosmic"))
end

--- SipHash: a short keyed tag, SipHash-2-4's 8 bytes by default, and the
--- 16-byte SipHash128-1-3 zig's build cache names its outputs by.
function Example.siphash()
  local key = "0123456789abcdef"
  local tag = Hash.siphash(key, "cosmic")
  print(#tag, Codec.hex(tag))
  assert(#tag == 8)
  local wide = Hash.siphash(key, "cosmic", { compression = 1, finalization = 3, size = 16 })
  assert(#wide == 16 and wide ~= Hash.siphash(key, "cosmic", { size = 16 }))
end

--- A message authentication code: only a holder of the key can make
--- the same one for the same message.
function Example.hmac()
  local code = Codec.hex(Hash.hmac("sha256", "key",
    "The quick brown fox jumps over the lazy dog"))
  print(code)
  assert(code == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8", code)
end

--- Checking a received MAC against the one computed, without a timing
--- leak: `==` stops at the first differing byte, [`Hash.equal`] does not.
function Example.equal()
  local key = "server secret"
  local expected = Hash.hmac("sha256", key, "user=7")
  assert(Hash.equal(expected, Hash.hmac("sha256", key, "user=7")))
  assert(not Hash.equal(expected, Hash.hmac("sha256", key, "user=8")))
  assert(not Hash.equal(expected, expected:sub(1, 31)))
end

return Example
