--- Proves X25519 key agreement through [`cosmic.key`] against the test
--- vectors of RFC 7748, and that a peer's point of low order and a key of
--- another length are refused.

local Codec = require("cosmic.codec")
local Key = require("cosmic.key")
local Test = require("cosmic.test")

local function unhex(hex: string): string
  return (assert(Codec.unhex(hex)))
end

--- `s` with bit `bit` (0 is the lowest bit of the first byte) inverted.
local function flipped(s: string, bit: integer): string
  local at = bit // 8 + 1
  local byte = assert(s:byte(at))
  return s:sub(1, at - 1) .. string.char(byte ~ (1 << (bit % 8))) .. s:sub(at + 1)
end

--- The public key of the X25519 key `private`.
local function public_of(private: string): string
  return assert(Key.secret("x25519", private)).public.bytes
end

--- The base point: the u-coordinate 9.
local base <const> = "\9" .. string.rep("\0", 31)

--- The secret of `private` and `peer`, which must be one.
local function shared(private: string, peer: string): string
  return (assert(assert(Key.secret("x25519", private)):agree(assert(Key.public("x25519", peer)))))
end

--- The second vector's u-coordinate has its top bit set, which RFC 7748
--- has an implementation ignore.
local function test_x25519_matches_rfc_7748_section_5_2()
  assert(Codec.hex(shared(unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
    unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"))) ==
      "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
  assert(Codec.hex(shared(unhex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
    unhex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"))) ==
      "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957")
end

--- RFC 7748 section 5.2's iteration: each round's result is the next
--- scalar, and the scalar the next u-coordinate.
local function test_x25519_matches_rfc_7748_after_one_and_a_thousand_rounds()
  local k, u = base, base
  for round = 1, 1000 do
    k, u = shared(k, u), k
    if round == 1 then
      assert(Codec.hex(k) == "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079")
    end
  end
  assert(Codec.hex(k) == "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51")
end

local function test_x25519_matches_rfc_7748_section_6_1()
  local alice = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  local bob = unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
  local alice_public = public_of(alice)
  local bob_public = public_of(bob)
  assert(Codec.hex(alice_public) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
  assert(Codec.hex(bob_public) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
  local secret = shared(alice, bob_public)
  assert(Codec.hex(secret) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
  assert(shared(bob, alice_public) == secret)
end

--- The public key is the agreement with the base point, and the bits
--- RFC 7748 clamps (the low three and the top two) are no part of a key.
local function test_a_private_key_is_clamped()
  local private = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  local public = public_of(private)
  assert(public == shared(private, base))
  for _, bit in ipairs({ 0, 1, 2, 254, 255 }) do
    assert(public_of(flipped(private, bit)) == public, "bit " .. tostring(bit))
  end
  assert(public_of(flipped(private, 3)) ~= public)
end

--- The u-coordinates of low order, in the order listed: 0 (the point of
--- order 2), 1 (order 4), the two of the points of order 8, p - 1 (order
--- 4, on the twist), and p and p + 1, which are 0 and 1 again, since a
--- u-coordinate is taken modulo p = 2^255 - 19. Each is tried with the
--- top bit set too, which is ignored. Every private key takes each to
--- the all-zero secret.
local function test_x25519_refuses_a_point_of_low_order()
  local private = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  for _, hex in ipairs({
      "0000000000000000000000000000000000000000000000000000000000000000",
      "0100000000000000000000000000000000000000000000000000000000000000",
      "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
      "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
      "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f" }) do
    for _, point in ipairs({ unhex(hex), flipped(unhex(hex), 255) }) do
      local secret, why = assert(Key.secret("x25519", private)):agree(assert(Key.public("x25519", point)))
      assert(secret == nil, Codec.hex(point) .. " answered a secret")
      assert(why.message:find("key: ", 1, true) == 1, Codec.hex(point) .. " was refused without a reason")
    end
  end
end

local function test_a_key_of_another_length_is_refused()
  for _, short in ipairs({ "", string.rep("k", 31), string.rep("k", 33) }) do
    local secret, why = Key.secret("x25519", short)
    assert(secret == nil, "a secret of " .. tostring(#short) .. " bytes")
    assert(why.message:find("key: ", 1, true) == 1, why.message)
    local public, trouble = Key.public("x25519", short)
    assert(public == nil, "a public key of " .. tostring(#short) .. " bytes")
    assert(trouble.message:find("an X25519 public key is 32 bytes", 1, true) ~= nil, trouble.message)
  end
end

local function test_an_x25519_key_signs_nothing_and_agrees_only_with_another()
  local key = Key.generate("x25519")
  Test.raises(function() key:sign("message") end, "an X25519 key signs nothing")
  assert(not key.public:verify("message", string.rep("s", 64)))
  local ed = Key.generate("ed25519")
  Test.raises(function() local _, _ = key:agree(ed.public) end, "agree takes two X25519 keys")
  Test.raises(function() local _, _ = ed:agree(key.public) end, "agree takes two X25519 keys")
end

local function test_an_x25519_key_reads_back_from_its_own_pem_and_has_an_rfc_8410_spki()
  local key = Key.generate("x25519")
  local read = assert(Key.read(key:pem()))
  assert(read.alg == "x25519" and read.public.bytes == key.public.bytes)
  assert(key.public:spki() == "\x30\x2a\x30\x05\x06\x03\x2b\x65\x6e\x03\x21\x00" .. key.public.bytes)
  assert(key.public:jwk()["crv"] == "X25519")
end

local function test_an_x25519_pkcs_8_key_whose_secret_is_no_octet_string_is_refused()
  -- PrivateKeyInfo { 0, { 1.3.101.110 }, OCTET STRING { INTEGER 5 } }.
  local der = "\x30\x0f\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x03\x02\x01\x05"
  local key, why = Key.read("-----BEGIN PRIVATE KEY-----\n" .. Codec.base64(der) .. "\n-----END PRIVATE KEY-----\n")
  assert(key == nil, "refused")
  assert(why.message:find("an x25519 private key is an OCTET STRING of its secret", 1, true) ~= nil, why.message)
end
