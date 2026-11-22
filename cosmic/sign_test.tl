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

-- A key of small order, in any of its encodings (the sign bit set or not,
-- y reduced or not), is refused: under one, the signature whose R is the
-- neutral point and whose S is 0 would verify for every message.
local function test_a_key_of_small_order_is_refused_in_every_encoding()
  local trivial = neutral .. zero
  for _, hex in ipairs({
      "0000000000000000000000000000000000000000000000000000000000000000",
      "0100000000000000000000000000000000000000000000000000000000000000",
      "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
      "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
      "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f" }) do
    local key = bytes(hex)
    local signed = key:sub(1, 31) .. string.char(assert(key:byte(32)) | 0x80)
    for _, message in ipairs({ "", "any message" }) do
      assert(not Sign.ed25519_verify(key, message, trivial), hex)
      assert(not Sign.ed25519_verify(signed, message, trivial), hex .. " with the sign bit")
    end
  end
  -- A key of large order beside them still verifies its own signatures.
  local public, message, signature = test_2()
  assert(Sign.ed25519_verify(public, message, signature))
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

--- RFC 6979 section A.2.5: the P-256 key, in hex.
local p256_secret <const> = "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"
local p256_public <const> = "04" ..
  "60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6" ..
  "7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299"

--- RFC 6979 section A.2.5: deterministic signatures under SHA-256, R then S.
local record P256Vector
  message: string
  signature: string
end

local p256_vectors <const>: {P256Vector} = {
  {
    message = "sample",
    signature = "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716" ..
      "f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8",
  },
  {
    message = "test",
    signature = "f1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367" ..
      "019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083",
  },
}

--- P-256's group order n, in hex.
local p256_order <const> = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"

local function test_the_p256_public_point_matches_rfc_6979()
  assert(Codec.hex(Sign.p256_public(bytes(p256_secret))) == p256_public)
end

local function test_p256_signatures_match_rfc_6979()
  for _, v in ipairs(p256_vectors) do
    local signature = Sign.p256(bytes(p256_secret), v.message)
    assert(Codec.hex(signature) == v.signature, v.message .. ": " .. Codec.hex(signature))
    assert(Sign.p256_verify(bytes(p256_public), v.message, signature), v.message)
  end
end

local function test_a_new_p256_secret_signs_and_verifies()
  local secret = Sign.p256_secret()
  assert(#secret == 32 and secret ~= Sign.p256_secret())
  local public = Sign.p256_public(secret)
  assert(#public == 65 and public:byte(1) == 4)
  local signature = Sign.p256(secret, "a\0b")
  assert(#signature == 64)
  assert(Sign.p256_verify(public, "a\0b", signature))
  assert(not Sign.p256_verify(public, "a", signature))
  assert(not Sign.p256_verify(Sign.p256_public(Sign.p256_secret()), "a\0b", signature))
end

local function test_a_flipped_bit_of_a_p256_signature_key_or_message_is_refused()
  local public, signature = bytes(p256_public), bytes(assert(p256_vectors[1]).signature)
  for at = 1, 64 do
    assert(not Sign.p256_verify(public, "sample", flipped(signature, at, at % 8)), "signature byte " .. tostring(at))
  end
  for at = 2, 65 do
    assert(not Sign.p256_verify(flipped(public, at, at % 8), "sample", signature), "key byte " .. tostring(at))
  end
  assert(not Sign.p256_verify(public, "samplf", signature))
end

local function test_a_p256_key_or_signature_of_the_wrong_shape_answers_false()
  local public, signature = bytes(p256_public), bytes(assert(p256_vectors[1]).signature)
  local keys = {
    "", public:sub(1, 64), public .. "\0", public:sub(2), "\2" .. public:sub(2, 33),
    -- 65 bytes that are no uncompressed point: another prefix, or the zero point.
    "\0" .. public:sub(2), "\2" .. public:sub(2), "\5" .. public:sub(2), "\4" .. string.rep("\0", 64),
  }
  for i, key in ipairs(keys) do
    assert(not Sign.p256_verify(key, "sample", signature), "key " .. tostring(i))
  end
  for _, sig in ipairs({ "", signature:sub(1, 63), signature .. "\0" }) do
    assert(not Sign.p256_verify(public, "sample", sig), "a signature of " .. tostring(#sig) .. " bytes")
  end
  -- R or S of 0, and of the group order: no valid signature has either.
  local r, s = signature:sub(1, 32), signature:sub(33)
  for _, sig in ipairs({ zero .. s, r .. zero, bytes(p256_order) .. s, r .. bytes(p256_order) }) do
    assert(not Sign.p256_verify(public, "sample", sig))
  end
end

local function test_a_p256_secret_of_the_wrong_length_or_out_of_range_raises()
  for _, secret in ipairs({ "", string.rep("s", 31), string.rep("s", 33) }) do
    local derived, why = pcall(Sign.p256_public, secret)
    assert(not derived and tostring(why):find("sign: a P-256 secret is 32 bytes", 1, true) ~= nil, tostring(why))
    local signed, trouble = pcall(Sign.p256, secret, "message")
    assert(not signed and tostring(trouble):find("sign: a P-256 secret is 32 bytes", 1, true) ~= nil,
      tostring(trouble))
  end
  for _, secret in ipairs({ zero, bytes(p256_order), string.rep("\xff", 32) }) do
    local derived, why = pcall(Sign.p256_public, secret)
    assert(not derived and tostring(why):find("sign: not a P-256 secret", 1, true) ~= nil, tostring(why))
    local signed, trouble = pcall(Sign.p256, secret, "message")
    assert(not signed and tostring(trouble):find("sign: not a P-256 secret", 1, true) ~= nil, tostring(trouble))
  end
  -- n - 1, the largest secret there is, is taken.
  local largest = bytes(p256_order:sub(1, 62) .. "50")
  assert(Sign.p256_verify(Sign.p256_public(largest), "m", Sign.p256(largest, "m")))
end

--- A 2048-bit RSA key (e = 65537) as a DER RSAPrivateKey, in hex, and
--- what OpenSSL (through Python's cryptography) makes of it: its DER
--- RSAPublicKey and the PKCS #1 v1.5 SHA-256 signature of "sample".
local rsa_secret <const> =
  "308204a40201000282010100ace8cd693715afe1442b16ad8a62cf0d67b110d401c69afebc598483342d54f72d074d54" ..
  "9e1ff8773998bf74c26d23f3dc5d618dcc3ace56b01a6a898d7209e7ce029343a3dcce8733ad23a937d084c76a5b9382" ..
  "da785b67e71a4bc6b3871280db672a17f16bdf1beadffcee65454093f23bd114a93850527a89829bf9f6a1dfd6ad3c19" ..
  "9f7c678650d856d37e48854e001d10431e17302991865907f369b0c51ec0ee52ddb3cb620a960fdc89b4f9c2cb8383f9" ..
  "7e2dda1d015a36bcc8cbab2baf7e51ce941a7c0e2bbaa43b66cecccc51c08feb1ca083dbc57162ab4a6757cea0c2aa09" ..
  "4fe11fcd803d7823a1350e296db9755e16332594597ec59cce69adb902030100010282010054b7a39cff7e42b44e6006" ..
  "3674ed40a142c2c089ff6cbd983dd466569a83f3733fbeaa26e16aaca44db607683fb295c0efa15920ce85a97f53bd3d" ..
  "a1b389c24caee5181e35f503c3be90003ef2b7d9b692e7d7786f6e34eacd9256ba3e4fd9c304bca125260642443d6a0d" ..
  "55088d4bbcb11c99ae53d2e197e7ade42e63e4711e988e887ed7a8938f5d5a803a010f056035461800061e244c313d8b" ..
  "0258ddaeedb11af169e877e20a9ad31a59eb171ff70feaf11cd1199c93d39f43f003b9c5f25d54f29e7f735babce9f6a" ..
  "2fe0e3a42ec861e4847e4ab124757135a161187dca46a05c3296f8f90810c750c2b2f8e0b0abb74c5741e7494414c69e" ..
  "3d7e766ed902818100f321034ff1a4ac1450b5c9e724640d258c77cc19eb86c3f675c16a087e710ddea8a3189b41265e" ..
  "76afcd91e62157058c0ff4c7accd758bc6774c3a531d850699ffbf3acb445df5407ce89f39140705f0a593b4859a4e49" ..
  "439c609a7a70147781c5cb618a829951d5da68e0d616ee3d308293159724c2a67993fee523b5961cb702818100b61024" ..
  "d869445f7d68f5af1f246b899fc7c51d555d602b50e5d42cd9a2cc26a0e0569c8c04b12fbbd8d50c2750e73fe35f444b" ..
  "91aae16e64711fa40cdee87d371b8eae41e966bf9b5b8767d3b9129543e2c423463bee007f33978ee10eac3dec9b5b03" ..
  "8659bec1712efadcf7a12d62ec186b2530a863e3f68304b95bccd0f90f02818100aac4f55ea18bd8922c5e838226bd5f" ..
  "be8ffb55109fadf8d693bf568ac0c507c8ed0a21ae6b04583565262ee44566aa2ec6c657b9b85667e6eec44bf33538ca" ..
  "7a40784103a4f199e1c1da627be4e549f6cd5601e6158c0749c5fcd4844b5514dbc1e22890f14a5f80a5f824743b86fa" ..
  "d3a7e347b6f1cb06c33e803ad1ea2995e1028181008bf8736b51daf81301abc8fc075309d6a68e5bd3f25aea5262afb1" ..
  "df8c72a9cc0b4d6b4396a3e68fe3cf3f6dc69c5318ea782625129c07f3fea895c63365c846a2d01a16a06b9729c8bf9c" ..
  "4a41421131c4d8884a09ef1bc0af9878877c715d9657862c7a90eabfebd57396886708eec196b061423c63b7b220de73" ..
  "e728db0c6f028180511ed3a9fd1bd05d9e8a9c5b113a946d7250b1fe3878c589fa4fe2f9b8cbb8a29db3a5e0c4a8704e" ..
  "a703b366a21d0b28c26207c514767098d0278701e07f07f43e4ccc51ddcafcb1b8efb6924834d1df492be8270b6dbe21" ..
  "1947f3537ecaa525209be6bcb7f283786a571e743c1b1d3f264c3d2a18bbc587268d92ac056f545d"
local rsa_public <const> =
  "3082010a0282010100ace8cd693715afe1442b16ad8a62cf0d67b110d401c69afebc598483342d54f72d074d549e1ff8" ..
  "773998bf74c26d23f3dc5d618dcc3ace56b01a6a898d7209e7ce029343a3dcce8733ad23a937d084c76a5b9382da785b" ..
  "67e71a4bc6b3871280db672a17f16bdf1beadffcee65454093f23bd114a93850527a89829bf9f6a1dfd6ad3c199f7c67" ..
  "8650d856d37e48854e001d10431e17302991865907f369b0c51ec0ee52ddb3cb620a960fdc89b4f9c2cb8383f97e2dda" ..
  "1d015a36bcc8cbab2baf7e51ce941a7c0e2bbaa43b66cecccc51c08feb1ca083dbc57162ab4a6757cea0c2aa094fe11f" ..
  "cd803d7823a1350e296db9755e16332594597ec59cce69adb90203010001"
local rsa_signature <const> =
  "5a54995199d9f524fabe7f4ea2a6d3f22373db421966ea0f4c64b9ef7f4ef5f351314bc8003acc942bee824b6dbae97d" ..
  "6ad87f19b132c790e1a3fed1bc7505291683b51184b1e2b0a8d03a38526bd7163dca35b0d0d1c273314a81c19935b44c" ..
  "da9adbf59518398df04cc0e274fec4cedf169ceb1fa9cc7547b8cd3c410566660c610b7ecd0d0b4a6847f8bda684e628" ..
  "b0e0af796ec6d6145339e97715d046db1c632cab1747afee009a5a5ec63ccedbe6a420c51ec691e2b0d74807fe78d295" ..
  "6bde873fd07a354b848b95cf95c718441a9dbd9fc9eceed25a83ff92b0533ab32a9260953c61f89747ce4cb1cc0c5dd0" ..
  "736c933d55f560ab80b174060735a6bf"
--- A 1024-bit RSA key, too short to take, with its public key and its
--- signature of "sample", as OpenSSL makes them.
local rsa_1024_secret <const> =
  "3082025c02010002818100e578b0d2bdbf99c1cb0440e3838e8ea8c035a36fe2002eb4fdbaca31487be3de64f87816d6" ..
  "eb07dc3adf0ca09538354ddd5b9737708650fa4bc59d580d5044287bbfa5f71bccb0a8d8a4566a430b3ed356eece5d6b" ..
  "8dc912b0755e9ac304304b79b9beba541697c6c5f4e1e4740c9079786d73304504514d40183c97589e4b9f0203010001" ..
  "0281803993baea65e9f96e82be2279f3bc85571a435b2aeb8e182a19b010a3a50850f8b06517dcc3385dd4888106ee14" ..
  "02f27d0319c42b88f46ac522d606d0dd2652b34c03763fe771653959fef00acb1e8dfdc1e24c89fe52242a5e8a4fbdf1" ..
  "525a28919d78195e41e2de4f76a3a6e34b8100e3366c0b0d57a6ed0996dc2a60f1ac61024100fb64fd9ed6e50a60a0cf" ..
  "c8c1bddb34c7996bec64d902c0cc49f9f1f4492df33514b8ac729404700966074c33044bcec018f36c346e1c0660fa4a" ..
  "676a49cd3eb5024100e9ace2348f9c6a259b660d1a1e0b580167b31b11df62745f04947c070b0cebe6d282424f5f7fac" ..
  "901113b57d84a39bdb4ecc6cb6924dcab1baa0b87308c6818302404245ec6a7c62632af819eee5cc644674bc286c6865" ..
  "a1492c51f0376ddc00e615bf41b40c7ca2f2da377083110bf7e428562b8e02006918f165ea497b06bbb9e502410082ad" ..
  "660b12ccdc278fd1f03dccd37731c1f64d8b1f2b85fca5290c7b3bd8cc0bd76974ffc25e39f88f344068a34683a08f5e" ..
  "8ee542c8323456340f327593dd5502405465e24444323c9d4b8ae8f5c4d6610b71291d48c0cfb3f0292998c7656c819e" ..
  "0891ce7a4bdadef348a7129f83200c34eccd39a2a6e485699f722acb748dcee6"
local rsa_1024_public <const> =
  "30818902818100e578b0d2bdbf99c1cb0440e3838e8ea8c035a36fe2002eb4fdbaca31487be3de64f87816d6eb07dc3a" ..
  "df0ca09538354ddd5b9737708650fa4bc59d580d5044287bbfa5f71bccb0a8d8a4566a430b3ed356eece5d6b8dc912b0" ..
  "755e9ac304304b79b9beba541697c6c5f4e1e4740c9079786d73304504514d40183c97589e4b9f0203010001"
local rsa_1024_signature <const> =
  "95eaec596b4ae17ce9a54981a03ae6ef926038f857e11897a61f4658dbc76e21dc9a0f159a6c7932adf110c36ac50c53" ..
  "7def9f35b49232579f27f5d7c26acfc7b288130794c8b4d0bafc54f4eb370f18d26526e2136e3d7eb06f39d290dd889a" ..
  "6887da2708215ccebe6f1867fe67a047c7fc05391a0c5f06400deec8c16fc7bd"

--- A 4096-bit RSA key, the most there is, with its public key and its
--- signature of "sample", as OpenSSL makes them.
local rsa_4096_secret <const> =
  "308209280201000282020100e93cfc1a3fda2e4e9b8f34445028b184b314ba4889676693a07951585f0cc1fcaa6887e9" ..
  "cba30918b9c65cde29b35ca50ea4876bf86818cb5f1faf46fbf1bb203247190428578de86f8d8276188888302f418e61" ..
  "c7e7319e5d2efaea0ed7d7ac6f30b0c9c5efa384fd6443a04a0519c6b069997cc39df9692f7015e9654e62d62bd3d108" ..
  "f7253d20d42462842580c689f43fd85c832a61ce90c884baa7c94a48c598c20ff2837122a8ff36dc8eb71cba93e92f1b" ..
  "3c3a5399f911537806371a1118d7337cb1c2f84947e8b1b4ff68870c42411747aa50fe1387d1cbfddf36fc026c9d407c" ..
  "180e8c68b486e11283e0177a1d143e5687f751664e82c82ef08edfe9d05c4dcae154d436e8a7cffdd255db3adc403d3a" ..
  "09539f7649e66350455f05d6d2a671cac50eaaadb79977c1dddceab7197a6804090ac7d5756fde9ef06a1b6887009870" ..
  "2f8aa878b25fe89cf1728473ffdfa9605c81e58ae2f7a68e3a918549cae1da8a0ddf3cda2bc846225b8208ccf2785489" ..
  "31e7ba1a77a56c07f4c2103fdb2d6de1cffb10a8b9035bac807fcb931a58e41f6fab2905fac7a68aa177e14a876e5c38" ..
  "6d9cabd268aee55046a989f265d0f320939bf97bf580edffcbce910f1c38f09d4b2d6edda7e8d8e780b1be2f5ca5e1db" ..
  "06407cb639ea0da461441438a1d0bd11a44268a202550ea9a3099b1e148bbea985b50dfe3fe411f23a939e9b02030100" ..
  "010282020032b7b32e5612309da1500b928b47be0a5812bacb492db5ed8628bb5a9718a41a384810bdf32d19ae49bf6b" ..
  "b457a70c0f4c56d4a7d2d57806c9418f90c4fa74b1749d674033318ec72b72bf1ac50cf3685eee4772d5d05d46cd8688" ..
  "c35ac4eebe2d538e2de21fd113fb31d14ecaa9bf4828565e2cf630a4ea8d89370a909ff1f81681b1e3dc3239cfa8b1dc" ..
  "c6558d621edf80fea0675950f9651c65585d61f5084c0782b38b0db00d546862daa522065a400da5d3ab4e179dd4be42" ..
  "c347beb5a9601873b6bac4e5ceb197550541c0ce1509573423be526c5d7cdc4f1a7e6e6b706f83e660d5ae5c33ec85a3" ..
  "edadc58df55cdb690ed1f422bc377852e57a23e7667b44eb8bd6834296c3d4d2b900e3fe1f0b1caa8f71f797a6359345" ..
  "2a59cdf9f22b2f419c67ee5157cbc8660c3762092064fb0e0389e0c3e941f0433f48b84b9f7fbd5fd636ea2d17a1e1d7" ..
  "987f9d7d5bc8368ca1184f03b28388ad8356fec80e634e7c0282e66c37e49aa5f45ab4485ef53f2feb12ad49ecc295fd" ..
  "eb150d5f88eeadc334a09f20e011c95a91fee71cd497fe2cd51fb15ae9683ef5f705fb97c54dc4c313f41d2ebb7af53b" ..
  "a29b93834fc92a82230254787a0cd9ff24cec5db3203df414c41e20e71421ee7bf81463082d248a0529ebd375c17e70d" ..
  "3f1f6d4fe7a1463f8aca8c2f2fd75df2c01ea7e087d34a5599ec5e225655572f64c80b5ec10282010100f6a95a1ab49f" ..
  "b589088bbf9cea70773e1a96f4c860286fe80cce7267edec74c823d75da67d0063fcd7944e736fbc20c54eec46bae86d" ..
  "fd66c1397fe18cff4a7f485e44b6c705a9a56752a11fa7bda511a07a604818b50fb319de2644ee316ebafd0bdfe733fc" ..
  "59ad19e3e90b50b71c64d5de3b2fcb5909c99bb9ab8441f8b5dd5137d1335eaa1b2de57ad6843567ffc894e43b89fe35" ..
  "fb664018039e9defee985f871b974484040eb2b93ce7ad6ee057d2586ffe4fd8f5312574f18e1be8d7175b952a9c8c52" ..
  "179204b2cb08d3294f11dbd49428ff59d6c462f15b31a5774a89e0a91653ad515c5eda829ef2b831c636f5af32c4c583" ..
  "e2cc722bbfe93edcb4a10282010100f21188aa4377371bfc2d1e974553385a5c632d3eb9716e3765f85d983035833d9e" ..
  "991a01025369ceccde0eba21ebf7704eab76fac59a67c6911eba00d7aae77a26a30d9e97cf8ff9a0c8aae04cbe1b3bf9" ..
  "5b2cc12903ada17a2e8dbda3c8c783c491a3befbdb5294b92d8501548a3c2935bb016624e4cbb10b953ae1aab1d89790" ..
  "52f4081a326969e484f0604ba5db7f218bc7e8313aa44bccdbd2bdcfeda9a3bd4518eac110fcd414cb7c8b5188b772cb" ..
  "c378184957013aa3b631195c7f8823908bd3293b7ba48d2d424595f150b6f3a23437eb46a82b3abb44d7a13ab92a61cb" ..
  "85a88e4065393e2b6fbdf1ebaffc2409dbf0094a147c6f8cea719da47f8dbb02820100792ff5741f804449c2681ec972" ..
  "a9b4fc4f4611980d1e70f4daade7a9c64ca187df8c2597f1dc6a43c48b3a0c1f3e97ff38ea7f49bf7ea2bc847cc2a6c7" ..
  "867a4c94fab3d9f56883d41f328ab529cdd43717d8684ba3cff999ae40e61e81c4c9b9972fe95f07bc9936a1fcc6f7e7" ..
  "3d3ff70ed8b3cda4a3e75a256790ac575961c90de955a05e8746f942c11a7a345f175dae41803b2929ce8d8b3a013542" ..
  "35aacd344a063548d56fc4e4ec7bcefbf7f8c34d366437d77529ea6e93c9465fd2033397ac6f16211f083396995d85c5" ..
  "718b46a3f20aa525e836cba02d22f7fe6ae0b5632ad02c66800dd910949291800bfc6dee4198b8f2adfc952416f8a019" ..
  "6188610282010100e9df52e0dd69d2ceb0e78ec4abefe964341a85de32208b51eeacf5105293810709b1f5d3bfc1835a" ..
  "8fc88306063c0ac670db6c8a805bdba39715ceb37daadb15c33a89b00e10359402699dde3387009d031fb9afadc6a5fc" ..
  "7b257b401b7ba277867507753fb3f8a743f9dca51a5eac1d4c922e99d74f4e14f191ee5f95215a97a492e0beeb408564" ..
  "0faaf8eab06bc013a5ff7cd6b2a96b8ee890019dedc43abfbddf82615cc2e2e2ac6ca5199d5eaf8eb39b58ee6dfd276c" ..
  "d63af259046b1ac6f1a28613322b152268f5bc714fc2a1dfe578fa05d0302e04026652c6ad0bb50ce32b715c6e8eddad" ..
  "591e0eb02afbce69ab34d946c051e69f87d00291421b127d0282010006323d0cd4293b8c47568cc4ed5f47b46581e138" ..
  "430e459ef533c0e2f60e89b0d13ae8386f5cc70f059752ce91f6639a42daf10d2a8c1efd32c7b24c70323dea0ba68411" ..
  "aed7ab887023823d191e383daa6ce9716318ac39d8691b9e4dec8aa77d903db7ee03944fba06080ed493d9337a395b03" ..
  "ec219050abaa2880f98246b06e96407be7bff38e032f508cf1bfcc0b73afbe409cc5f1b9aa6b3383655df055edab5e53" ..
  "0bce5762c1e69e4f96414b1acbeb65a3db6e17c04da6f8ee1463039a6c06df433b4fb9901b3a3f188c17ce333c415622" ..
  "31fe53519de12f55a397bbb0ee9768bf470ac0d579477094415a178220797a4ccb98bfe87fc2ea4127d391d2"
local rsa_4096_public <const> =
  "3082020a0282020100e93cfc1a3fda2e4e9b8f34445028b184b314ba4889676693a07951585f0cc1fcaa6887e9cba309" ..
  "18b9c65cde29b35ca50ea4876bf86818cb5f1faf46fbf1bb203247190428578de86f8d8276188888302f418e61c7e731" ..
  "9e5d2efaea0ed7d7ac6f30b0c9c5efa384fd6443a04a0519c6b069997cc39df9692f7015e9654e62d62bd3d108f7253d" ..
  "20d42462842580c689f43fd85c832a61ce90c884baa7c94a48c598c20ff2837122a8ff36dc8eb71cba93e92f1b3c3a53" ..
  "99f911537806371a1118d7337cb1c2f84947e8b1b4ff68870c42411747aa50fe1387d1cbfddf36fc026c9d407c180e8c" ..
  "68b486e11283e0177a1d143e5687f751664e82c82ef08edfe9d05c4dcae154d436e8a7cffdd255db3adc403d3a09539f" ..
  "7649e66350455f05d6d2a671cac50eaaadb79977c1dddceab7197a6804090ac7d5756fde9ef06a1b68870098702f8aa8" ..
  "78b25fe89cf1728473ffdfa9605c81e58ae2f7a68e3a918549cae1da8a0ddf3cda2bc846225b8208ccf278548931e7ba" ..
  "1a77a56c07f4c2103fdb2d6de1cffb10a8b9035bac807fcb931a58e41f6fab2905fac7a68aa177e14a876e5c386d9cab" ..
  "d268aee55046a989f265d0f320939bf97bf580edffcbce910f1c38f09d4b2d6edda7e8d8e780b1be2f5ca5e1db06407c" ..
  "b639ea0da461441438a1d0bd11a44268a202550ea9a3099b1e148bbea985b50dfe3fe411f23a939e9b0203010001"
local rsa_4096_signature <const> =
  "349bf73e4d9770ff5035e657981f68c47c9527183d25467d153b251f5f54b90916d5555827944dfb5d9b36e9a363cd6d" ..
  "4f5d4eedc1272b4500ef267ff0bd7c3e1ea5fed47b744869a1d91de03f57f387ff72803afdeb787f7524e249c83b6ff0" ..
  "d08cdab88dd586745c53b3ba60c2bbd4797a546c2dc3cefca9ea07a1664c5f371e5938ce7c544c6315d0733f43172123" ..
  "b0d6245f7db558f99f4b2c1e12236848f7db8e865330b7337035dbc3e803777aeeaab0045217416c5ece5736957696a0" ..
  "710f869ecd6c68fd14286e52243ff23a1d2fab9740b82d38c9c46abcb0fe2635e8926ba1605245b88ca3620d731e8660" ..
  "9ce526168c4d2bbbbde3e39ead0f9710da4dd23b5fc77db427e92b9a4891b36e0d3398fa8c8fb786a555fb0550346d2c" ..
  "b32d49d1d8f18587b90cee1b12e7f9b779b97ae1bb33e09b8b56cab4a3d4378cff6715686ca6d3b4138adf269ebe054d" ..
  "bd044ed1e69a2db92715ad15e9df2fd8a0103b1fc1f7fc354923291a29ddf685a51383ded29e0631b5c52763d8020b34" ..
  "186972b93df27ea959a41b7f46fc480ae411ee7f90b81fe0c6821ee6287418e49840e01058e9f63d7d8925290108ff80" ..
  "029bb2def22387169c4b3237b235c04bd51e156b833dfb7fa96f8cdc9a8659f4a6db09e0be96fcbf5b348a697f8cbffc" ..
  "2f4dae273b9248cfc33d57ff5c7b6ee70282a99ec0aa153d7a79d6cc37d69957"

local function test_the_rsa_public_key_and_signature_match_openssl()
  assert(Codec.hex(Sign.rsa_public(bytes(rsa_secret))) == rsa_public)
  local signature = Sign.rsa(bytes(rsa_secret), "sample")
  assert(Codec.hex(signature) == rsa_signature, Codec.hex(signature))
  assert(Sign.rsa_verify(bytes(rsa_public), "sample", signature))
end

local function test_a_4096_bit_rsa_key_signs_in_512_bytes_as_openssl_does()
  assert(Codec.hex(Sign.rsa_public(bytes(rsa_4096_secret))) == rsa_4096_public)
  local signature = Sign.rsa(bytes(rsa_4096_secret), "sample")
  assert(#signature == 512 and Codec.hex(signature) == rsa_4096_signature, Codec.hex(signature))
  assert(Sign.rsa_verify(bytes(rsa_4096_public), "sample", signature))
  assert(not Sign.rsa_verify(bytes(rsa_4096_public), "sample", bytes(rsa_signature)))
end

local function test_a_new_rsa_secret_signs_and_verifies()
  local secret = Sign.rsa_secret()
  local public = Sign.rsa_public(secret)
  -- A 2048-bit modulus: a DER SEQUENCE of a 257-byte INTEGER and e.
  assert(public:sub(1, 8) == "\x30\x82\x01\x0a\x02\x82\x01\x01", Codec.hex(public:sub(1, 8)))
  assert(public:sub(-5) == "\x02\x03\x01\x00\x01", "e is 65537")
  local signature = Sign.rsa(secret, "a\0b")
  assert(#signature == 256)
  assert(Sign.rsa_verify(public, "a\0b", signature))
  assert(not Sign.rsa_verify(public, "a", signature))
  assert(not Sign.rsa_verify(bytes(rsa_public), "a\0b", signature))
end

local function test_a_new_rsa_secret_of_other_bits_than_2048_3072_or_4096_raises()
  for _, bits in ipairs({ 0, 1024, 2047, 2049, 8192 }) do
    local drawn, why = pcall(Sign.rsa_secret, bits)
    assert(not drawn and tostring(why):find("sign: a new RSA key is 2048, 3072 or 4096 bits", 1, true) ~= nil,
      tostring(why))
  end
end

local function test_a_flipped_bit_of_an_rsa_signature_key_or_message_is_refused()
  local public, signature = bytes(rsa_public), bytes(rsa_signature)
  for at = 1, #signature, 17 do
    assert(not Sign.rsa_verify(public, "sample", flipped(signature, at, at % 8)), "signature byte " .. tostring(at))
  end
  -- The modulus, bytes 10 to 265: a SEQUENCE header, an INTEGER header and a zero go before it.
  for at = 10, 265, 17 do
    assert(not Sign.rsa_verify(flipped(public, at, at % 8), "sample", signature), "key byte " .. tostring(at))
  end
  assert(not Sign.rsa_verify(public, "samplf", signature))
end

local function test_an_rsa_key_or_signature_of_the_wrong_shape_answers_false()
  local public, signature = bytes(rsa_public), bytes(rsa_signature)
  for i, key in ipairs({ "", "not a key", public:sub(1, 200), public .. "\0", string.rep("\0", 270),
      string.rep("k", 100000), bytes(rsa_secret) }) do
    assert(not Sign.rsa_verify(key, "sample", signature), "key " .. tostring(i))
  end
  for _, sig in ipairs({ "", signature:sub(1, 255), signature .. "\0", "\0" .. signature, string.rep("s", 100000) }) do
    assert(not Sign.rsa_verify(public, "sample", sig), "a signature of " .. tostring(#sig) .. " bytes")
  end
  -- A key of 1024 bits is refused, though its signature is good.
  assert(not Sign.rsa_verify(bytes(rsa_1024_public), "sample", bytes(rsa_1024_signature)))
end

local function test_an_rsa_secret_that_is_none_or_of_too_few_bits_raises()
  for _, secret in ipairs({ "", "not a key", bytes(rsa_public), bytes(rsa_secret):sub(1, 600),
      bytes(rsa_secret) .. "\0" }) do
    local derived, why = pcall(Sign.rsa_public, secret)
    assert(not derived and tostring(why):find("sign: not an RSA secret", 1, true) ~= nil, tostring(why))
    local signed, trouble = pcall(Sign.rsa, secret, "message")
    assert(not signed and tostring(trouble):find("sign: not an RSA secret", 1, true) ~= nil, tostring(trouble))
  end
  local derived, why = pcall(Sign.rsa_public, bytes(rsa_1024_secret))
  assert(not derived and tostring(why):find("sign: an RSA key is from 2048 to 4096 bits", 1, true) ~= nil,
    tostring(why))
  local signed, trouble = pcall(Sign.rsa, bytes(rsa_1024_secret), "message")
  assert(not signed and tostring(trouble):find("sign: an RSA key is from 2048 to 4096 bits", 1, true) ~= nil,
    tostring(trouble))
end
