--- Proves [`cosmic.sign`]'s Ed25519 against the test vectors of RFC 8032
--- section 7.1, and that a signature, a message or a key changed by a
--- bit, or malformed, is refused with false rather than a raise.

local Codec = require("cosmic.codec")
local Sign = require("cosmic.sign")

local record Vector
  name: string
  seed: string
  public: string
  message: string
  signature: string
end

--- RFC 8032 section 7.1, in hex: TEST 1, 2, 3, 1024 and SHA(abc).
local vectors: {Vector} = {
  {
    name = "TEST 1",
    seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    public = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    message = "",
    signature = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" ..
      "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
  },
  {
    name = "TEST 2",
    seed = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
    public = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
    message = "72",
    signature = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da" ..
      "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
  },
  {
    name = "TEST 3",
    seed = "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
    public = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
    message = "af82",
    signature = "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac" ..
      "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
  },
  {
    name = "TEST 1024",
    seed = "f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5",
    public = "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
    message = "08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98" ..
      "fa6e264bf09efe12ee50f8f54e9f77b1e355f6c50544e23fb1433ddf73be84d8" ..
      "79de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d" ..
      "658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc" ..
      "1a858efcb8550ee3a5e1998bd177e93a7363c344fe6b199ee5d02e82d522c4fe" ..
      "ba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e" ..
      "06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbef" ..
      "efd75499da96bd68a8a97b928a8bbc103b6621fcde2beca1231d206be6cd9ec7" ..
      "aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed1" ..
      "85ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2" ..
      "d17ba70eb6248e594e1a2297acbbb39d502f1a8c6eb6f1ce22b3de1a1f40cc24" ..
      "554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270" ..
      "88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc" ..
      "2732e69485bbc9c90bfbd62481d9089beccf80cfe2df16a2cf65bd92dd597b07" ..
      "07e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128ba" ..
      "b27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51a" ..
      "ddd3b75a2b1ae0784504df543af8969be3ea7082ff7fc9888c144da2af58429e" ..
      "c96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7" ..
      "51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c" ..
      "42f58c30c04aafdb038dda0847dd988dcda6f3bfd15c4b4c4525004aa06eeff8" ..
      "ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34df" ..
      "f7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08" ..
      "d78ff4ef5d63653a65040cf9bfd4aca7984a74d37145986780fc0b16ac451649" ..
      "de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4" ..
      "88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a3" ..
      "2ef5b52a1ecc820e308aa342721aac0943bf6686b64b2579376504ccc493d97e" ..
      "6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5f" ..
      "b93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b5" ..
      "0d334ba77c225bc307ba537152f3f1610e4eafe595f6d9d90d11faa933a15ef1" ..
      "369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d" ..
      "b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c" ..
      "0618983f8741c5ef68d3a101e8a3b8cac60c905c15fc910840b94c00a0b9d0",
    signature = "0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350" ..
      "aa5371b1508f9f4528ecea23c436d94b5e8fcd4f681e30a6ac00a9704a188a03",
  },
  {
    name = "TEST SHA(abc)",
    seed = "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
    public = "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
    message = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" ..
      "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
    signature = "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b589" ..
      "09351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704",
  },
}

local function bytes(hex: string): string
  return (assert(Codec.unhex(hex)))
end

--- `data` with bit `bit` (0 the lowest) of its byte at `at` (1-based) flipped.
local function flipped(data: string, at: integer, bit: integer): string
  local byte = assert(data:byte(at), "at is within data")
  return data:sub(1, at - 1) .. string.char(byte ~ (1 << bit)) .. data:sub(at + 1)
end

--- TEST 2's key, message and signature, as bytes.
local function test_2(): string, string, string
  local v = assert(vectors[2])
  return bytes(v.public), bytes(v.message), bytes(v.signature)
end

--- The neutral point's encoding, a y of 1, and a scalar of 0.
local neutral <const> = "\1" .. string.rep("\0", 31)
local zero <const> = string.rep("\0", 32)

local function test_public_keys_match_rfc_8032()
  for _, v in ipairs(vectors) do
    local public = Sign.ed25519_public(bytes(v.seed))
    assert(Codec.hex(public) == v.public, v.name .. ": " .. Codec.hex(public))
  end
end

local function test_signatures_match_rfc_8032()
  for _, v in ipairs(vectors) do
    local signature = Sign.ed25519(bytes(v.seed), bytes(v.message))
    assert(Codec.hex(signature) == v.signature, v.name .. ": " .. Codec.hex(signature))
  end
end

local function test_the_vectors_of_rfc_8032_verify()
  for _, v in ipairs(vectors) do
    assert(Sign.ed25519_verify(bytes(v.public), bytes(v.message), bytes(v.signature)), v.name)
  end
end

local function test_a_signature_verifies_only_under_its_own_key_and_message()
  local seed, other = string.rep("s", 32), string.rep("t", 32)
  local signature = Sign.ed25519(seed, "message")
  assert(#signature == 64 and #Sign.ed25519_public(seed) == 32)
  assert(Sign.ed25519_verify(Sign.ed25519_public(seed), "message", signature))
  assert(not Sign.ed25519_verify(Sign.ed25519_public(other), "message", signature))
  assert(not Sign.ed25519_verify(Sign.ed25519_public(seed), "massage", signature))
  assert(not Sign.ed25519_verify(Sign.ed25519_public(seed), "", signature))
  assert(signature == Sign.ed25519(seed, "message"), "signing is deterministic")
end

local function test_a_message_holding_zero_bytes_is_signed_whole()
  local seed = string.rep("s", 32)
  local public = Sign.ed25519_public(seed)
  local signature = Sign.ed25519(seed, "a\0b")
  assert(Sign.ed25519_verify(public, "a\0b", signature))
  assert(not Sign.ed25519_verify(public, "a", signature))
  assert(not Sign.ed25519_verify(public, "a\0c", signature))
end

local function test_a_flipped_bit_of_the_message_is_refused()
  for _, v in ipairs(vectors) do
    local public, message, signature = bytes(v.public), bytes(v.message), bytes(v.signature)
    -- TEST 1's message is empty and has no bit to flip.
    local ends: {integer} = if #message == 0 then {} else { 1, #message } end
    for _, at in ipairs(ends) do
      for _, bit in ipairs({ 0, 7 }) do
        assert(not Sign.ed25519_verify(public, flipped(message, at, bit), signature),
          v.name .. ": byte " .. tostring(at) .. ", bit " .. tostring(bit))
      end
    end
  end
end

local function test_a_flipped_bit_of_either_half_of_the_signature_is_refused()
  local public, message, signature = test_2()
  for at = 1, 64 do
    for bit = 0, 7 do
      assert(not Sign.ed25519_verify(public, message, flipped(signature, at, bit)),
        (if at <= 32 then "R" else "S" end) .. ": byte " .. tostring(at) .. ", bit " .. tostring(bit))
    end
  end
end

local function test_a_flipped_bit_of_the_key_is_refused()
  local public, message, signature = test_2()
  for at = 1, 32 do
    for bit = 0, 7 do
      assert(not Sign.ed25519_verify(flipped(public, at, bit), message, signature),
        "byte " .. tostring(at) .. ", bit " .. tostring(bit))
    end
  end
end

local function test_a_key_or_signature_of_the_wrong_length_answers_false()
  local public, message, signature = test_2()
  for _, key in ipairs({ "", public:sub(1, 31), public .. "\0", public .. public, signature }) do
    assert(not Sign.ed25519_verify(key, message, signature), "a key of " .. tostring(#key) .. " bytes")
  end
  for _, sig in ipairs({ "", signature:sub(1, 63), signature .. "\0", signature:sub(1, 32), public }) do
    assert(not Sign.ed25519_verify(public, message, sig), "a signature of " .. tostring(#sig) .. " bytes")
  end
  assert(not Sign.ed25519_verify("", "", ""))
end

-- Adding the group order L to S leaves S·B where it was, so a check that
-- did not hold S below L would take this second signature of the message.
local function test_an_s_of_the_group_order_or_more_is_refused()
  local public, message, signature = test_2()
  local r = signature:sub(1, 32)
  local s_plus_l = bytes("f52db7415978abc61b2c2eb6aeebfca0387b2eaeb4302aeeb00d291612bb0c10")
  local l = bytes("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010")
  assert(Sign.ed25519_verify(public, message, signature))
  assert(not Sign.ed25519_verify(public, message, r .. s_plus_l), "S + L")
  assert(not Sign.ed25519_verify(public, message, r .. l), "L")
  assert(not Sign.ed25519_verify(public, message, r .. string.rep("\xff", 32)), "2^256 - 1")
  -- Under the neutral key S·B alone decides, and L·B is the neutral point.
  assert(not Sign.ed25519_verify(neutral, message, neutral .. l), "L under the neutral key")
end

-- No x satisfies the curve's equation at a y of 2.
local function test_a_key_or_an_r_that_is_no_point_is_refused()
  local public, message, signature = test_2()
  local no_point = "\2" .. string.rep("\0", 31)
  assert(not Sign.ed25519_verify(no_point, message, signature), "the key")
  assert(not Sign.ed25519_verify(public, message, no_point .. signature:sub(33)), "R")
  assert(not Sign.ed25519_verify(no_point, message, neutral .. zero), "the key, under a signature the neutral key takes")
end

-- [`Sign.ed25519_verify`]'s documented reach past a strict reading of
-- RFC 8032: a key of small order, and encodings the RFC refuses to
-- decode.
local function test_a_key_of_small_order_and_a_point_not_in_canonical_form_are_accepted()
  local trivial = neutral .. zero
  for _, message in ipairs({ "", "any message", "another" }) do
    assert(Sign.ed25519_verify(neutral, message, trivial), "the neutral key")
  end
  -- y = 2^255 - 18, which is 1 modulo the field's prime.
  local unreduced = bytes("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
  assert(Sign.ed25519_verify(unreduced, "any message", trivial), "a key whose y is not reduced")
  assert(Sign.ed25519_verify(neutral, "any message", unreduced .. zero), "an R whose y is not reduced")
  -- y = 1 and so x = 0, with the sign bit set.
  local negative_zero = "\1" .. string.rep("\0", 30) .. "\x80"
  assert(Sign.ed25519_verify(negative_zero, "any message", trivial), "a key whose x is 0 and sign bit is set")
  -- Still held to the equation: an S of 1 moves the sum off the neutral point.
  assert(not Sign.ed25519_verify(neutral, "any message", neutral .. "\1" .. string.rep("\0", 31)))
end

local function test_a_seed_of_the_wrong_length_raises()
  for _, seed in ipairs({ "", string.rep("s", 31), string.rep("s", 33), string.rep("s", 64) }) do
    local derived, why = pcall(Sign.ed25519_public, seed)
    assert(not derived and tostring(why):find("sign: an Ed25519 seed is 32 bytes", 1, true) ~= nil, tostring(why))
    local signed, trouble = pcall(Sign.ed25519, seed, "message")
    assert(not signed and tostring(trouble):find("sign: an Ed25519 seed is 32 bytes", 1, true) ~= nil,
      tostring(trouble))
  end
end
