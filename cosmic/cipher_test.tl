--- Proves the authenticated encryption and the X25519 key agreement the
--- core exposes against the vectors of RFC 8439 and RFC 7748, and that a
--- sealed message any bit of which differs, or a peer's point of low
--- order, is refused.

local Cipher = require("cosmic.cipher")
local Codec = require("cosmic.codec")
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

--- Asserts that `sealed` does not open, and that the refusal says why.
local function refused(key: string, nonce: string, sealed: string, aad: string?, what: string)
  local plaintext, why = Cipher.open("chacha20-poly1305", key, nonce, sealed, aad)
  assert(plaintext == nil, what .. " opened")
  assert(why ~= "", what .. " was refused without a reason")
end

local record Sealed
  key: string
  nonce: string
  aad: string
  plaintext: string
  sealed: string
end

-- RFC 8439 section 2.8.2.
local sunscreen: Sealed = {
  key = unhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
  nonce = unhex("070000004041424344454647"),
  aad = unhex("50515253c0c1c2c3c4c5c6c7"),
  plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, " ..
    "sunscreen would be it.",
  sealed = unhex("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6" ..
      "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36" ..
      "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc" ..
      "3ff4def08e4b7a9de576d26586cec64b6116" ..
      "1ae10b594f09e26a7e902ecbd0600691"),
}

local function test_seal_matches_rfc_8439_section_2_8_2()
  local v = sunscreen
  local sealed = Cipher.seal("chacha20-poly1305", v.key, v.nonce, v.plaintext, v.aad)
  assert(Codec.hex(sealed) == Codec.hex(v.sealed))
  assert(#sealed == #v.plaintext + Cipher.tag_length)
end

local function test_open_matches_rfc_8439_section_2_8_2()
  local v = sunscreen
  local plaintext, why = Cipher.open("chacha20-poly1305", v.key, v.nonce, v.sealed, v.aad)
  assert(plaintext == v.plaintext, why)
  assert(why == "")
end

local function test_open_matches_rfc_8439_appendix_a_5()
  local key = unhex("1c9240a5eb55d38af333888604f6b5f0473917c1402b80099dca5cbc207075c0")
  local nonce = unhex("000000000102030405060708")
  local aad = unhex("f33388860000000000004e91")
  local sealed = unhex("64a0861575861af460f062c79be643bd5e805cfd345cf389f108670ac76c8cb2" ..
      "4c6cfc18755d43eea09ee94e382d26b0bdb7b73c321b0100d4f03b7f355894cf" ..
      "332f830e710b97ce98c8a84abd0b948114ad176e008d33bd60f982b1ff37c855" ..
      "9797a06ef4f0ef61c186324e2b3506383606907b6a7c02b0f9f6157b53c867e4" ..
      "b9166c767b804d46a59b5216cde7a4e99040c5a40433225ee282a1b0a06c523e" ..
      "af4534d7f83fa1155b0047718cbc546a0d072b04b3564eea1b422273f548271a" ..
      "0bb2316053fa76991955ebd63159434ecebb4e466dae5a1073a6727627097a10" ..
      "49e617d91d361094fa68f0ff77987130305beaba2eda04df997b714d6c6f2c29" ..
      "a6ad5cb4022b02709b" ..
      "eead9d67890cbb22392336fea1851f38")
  local plaintext, why = Cipher.open("chacha20-poly1305", key, nonce, sealed, aad)
  assert(plaintext == "Internet-Drafts are draft documents valid for a maximum of six months and may be " ..
      "updated, replaced, or obsoleted by other documents at any time. It is inappropriate to use " ..
      "Internet-Drafts as reference material or to cite them other than as /\u{201c}work in progress./\u{201d}", why)
end

local function test_an_empty_plaintext_seals_to_its_tag_alone()
  local v = sunscreen
  local sealed = Cipher.seal("chacha20-poly1305", v.key, v.nonce, "")
  assert(Codec.hex(sealed) == "a0784d7a4716f3feb4f64e7f4b39bf04")
  local plaintext, why = Cipher.open("chacha20-poly1305", v.key, v.nonce, sealed)
  assert(plaintext == "", why)
end

local function test_an_absent_aad_is_an_empty_one()
  local v = sunscreen
  local absent = Cipher.seal("chacha20-poly1305", v.key, v.nonce, "message")
  assert(absent == Cipher.seal("chacha20-poly1305", v.key, v.nonce, "message", ""))
  assert(absent ~= Cipher.seal("chacha20-poly1305", v.key, v.nonce, "message", "\0"))
  assert(Cipher.open("chacha20-poly1305", v.key, v.nonce, absent, "") == "message")
  assert(Cipher.open("chacha20-poly1305", v.key, v.nonce, Cipher.seal("chacha20-poly1305", v.key, v.nonce, "message", "")) ==
      "message")
end

--- A message whose every input is short enough to try each bit of: one
--- inverted anywhere in the ciphertext, the tag, the aad, the nonce or
--- the key must refuse the whole message.
local function test_open_refuses_every_single_bit_flip()
  local v = sunscreen
  local sealed = Cipher.seal("chacha20-poly1305", v.key, v.nonce, "a secret", v.aad)
  assert(Cipher.open("chacha20-poly1305", v.key, v.nonce, sealed, v.aad) == "a secret")
  for bit = 0, #sealed * 8 - 1 do
    refused(v.key, v.nonce, flipped(sealed, bit), v.aad, "sealed bit " .. tostring(bit))
  end
  for bit = 0, #v.aad * 8 - 1 do
    refused(v.key, v.nonce, sealed, flipped(v.aad, bit), "aad bit " .. tostring(bit))
  end
  for bit = 0, #v.nonce * 8 - 1 do
    refused(v.key, flipped(v.nonce, bit), sealed, v.aad, "nonce bit " .. tostring(bit))
  end
  for bit = 0, #v.key * 8 - 1 do
    refused(flipped(v.key, bit), v.nonce, sealed, v.aad, "key bit " .. tostring(bit))
  end
  refused(v.key, v.nonce, sealed, nil, "a missing aad")
  refused(v.key, v.nonce, sealed .. "\0", v.aad, "a longer message")
  refused(v.key, v.nonce, sealed:sub(1, -2), v.aad, "a shorter message")
end

local function test_open_refuses_what_is_shorter_than_a_tag()
  local v = sunscreen
  for length = 0, Cipher.tag_length - 1 do
    refused(v.key, v.nonce, string.rep("\0", length), nil, tostring(length) .. " bytes")
  end
end

--- ChaCha20 works in blocks of 64 bytes and Poly1305 in 16: the lengths
--- either side of a block, and a message of many.
local function test_messages_around_a_block_round_trip()
  local v = sunscreen
  local bytes: mut {string} = {}
  for i = 1, 4096 do bytes[i] = string.char((i * 7 + i // 256) % 256) end
  local long = table.concat(bytes)
  for _, length in ipairs({ 0, 1, 15, 16, 17, 63, 64, 65, 4096 }) do
    local message = long:sub(1, length)
    local sealed = Cipher.seal("chacha20-poly1305", v.key, v.nonce, message, v.aad)
    assert(#sealed == length + Cipher.tag_length, tostring(length))
    assert(length == 0 or sealed:sub(1, length) ~= message, tostring(length) .. " bytes were not encrypted")
    local opened, why = Cipher.open("chacha20-poly1305", v.key, v.nonce, sealed, v.aad)
    assert(opened == message, tostring(length) .. ": " .. why)
  end
end

local function test_seal_and_open_raise_on_a_key_or_nonce_of_another_length()
  local v = sunscreen
  local sealed = Cipher.seal("chacha20-poly1305", v.key, v.nonce, "message")
  for _, key in ipairs({ "", v.key:sub(1, 31), v.key .. "\0", v.key:sub(1, 16) }) do
    Test.raises(function() Cipher.seal("chacha20-poly1305", key, v.nonce, "message") end, "key")
    Test.raises(function() Cipher.open("chacha20-poly1305", key, v.nonce, sealed) end, "key")
  end
  for _, nonce in ipairs({ "", v.nonce:sub(1, 11), v.nonce .. "\0", v.nonce:sub(1, 8) }) do
    Test.raises(function() Cipher.seal("chacha20-poly1305", v.key, nonce, "message") end, "nonce")
    Test.raises(function() Cipher.open("chacha20-poly1305", v.key, nonce, sealed) end, "nonce")
  end
end

local function test_the_lengths_are_the_algorithms()
  assert(Cipher.key_length == 32 and Cipher.nonce_length == 12 and Cipher.tag_length == 16)
end

--- Two keys no test's vector shares: bytes 0 to 31 and 32 to 63.
local function channel_keys(): string, string
  local bytes: mut {string} = {}
  for i = 1, 64 do bytes[i] = string.char(i - 1) end
  local all = table.concat(bytes)
  return all:sub(1, 32), all:sub(33)
end

--- The two ends of one session.
local function ends(options?: Cipher.ChannelOptions): Cipher.Channel, Cipher.Channel
  local a_to_b, b_to_a = channel_keys()
  return Cipher.channel(a_to_b, b_to_a, options), Cipher.channel(b_to_a, a_to_b, options)
end

local function test_a_channels_ends_exchange_messages_in_order()
  local alice, bob = ends()
  for round = 1, 3 do
    local request = "request " .. tostring(round)
    local sealed = alice:seal(request, "to bob")
    assert(#sealed == #request + Cipher.tag_length)
    local opened, why = bob:open(sealed, "to bob")
    assert(opened == request and why == "", why)
    assert(alice:open(bob:seal("reply " .. tostring(round))) == "reply " .. tostring(round))
  end
end

local function test_a_channel_never_seals_two_messages_alike()
  local alice = ends()
  local first, second = alice:seal("same"), alice:seal("same")
  assert(first ~= second)
end

local function test_a_channel_refuses_a_replayed_message()
  local alice, bob = ends()
  local first = alice:seal("pay bob 10")
  assert(bob:open(first) == "pay bob 10")
  local again, why = bob:open(first)
  assert(again == nil and why ~= "")
end

local function test_a_channel_refuses_a_message_out_of_order_then_opens_both_in_order()
  local alice, bob = ends()
  local first, second = alice:seal("first"), alice:seal("second")
  local early, why = bob:open(second)
  assert(early == nil and why ~= "")
  assert(bob:open(first) == "first")
  assert(bob:open(second) == "second")
end

local function test_a_failed_open_leaves_the_next_genuine_message_openable()
  local alice, bob = ends()
  local sealed = alice:seal("genuine", "header")
  for _ = 1, 3 do
    assert(bob:open(flipped(sealed, 0), "header") == nil)
    assert(bob:open(sealed, "another header") == nil)
    assert(bob:open(sealed) == nil)
    assert(bob:open("") == nil)
  end
  assert(bob:open(sealed, "header") == "genuine")
  assert(bob:open(alice:seal("next")) == "next")
end

local function test_a_channel_does_not_open_what_it_sealed()
  local alice = ends()
  assert(alice:open(alice:seal("to bob")) == nil)
end

--- What Python's `cryptography` seals under one key and a nonce built by
--- hand, for the messages numbered 0, 1 and 258 of one direction and the
--- first of the other: `ChaCha20Poly1305(key).encrypt(nonce, message, aad)`.
local record ChannelVector
  options: Cipher.ChannelOptions
  first: string
  second: string
  reply: string
  later: string
end

local channel_vectors: {string: ChannelVector} = {
  -- nonce = bytes(4) + struct.pack("<Q", n)
  ["8 bytes, little-endian"] = {
    options = {},
    first = "7ed13042d9a817d4a9b9ffada55b61682a8d3073bf",
    second = "ec329030db4e3cbe8e3dbd0d2f98af1bef00da580522",
    reply = "f2062fb06a92917818bb8d65d213de30a95401d4d1",
    later = "71d48c5863273683e43234b9f5a6cd3ac818706e09",
  },
  -- nonce = n.to_bytes(12, "little")
  ["12 bytes, little-endian"] = {
    options = { counter_length = 12 },
    first = "7ed13042d9a817d4a9b9ffada55b61682a8d3073bf",
    second = "e75a1881aa8794a610a5233a47d5fb290715344cc1b5",
    reply = "f2062fb06a92917818bb8d65d213de30a95401d4d1",
    later = "d5d2200c0344c4bccffb252e633e3275afd8d6aa14",
  },
  -- nonce = n.to_bytes(12, "big")
  ["8 bytes, big-endian"] = {
    options = { byte_order = "big" },
    first = "7ed13042d9a817d4a9b9ffada55b61682a8d3073bf",
    second = "1a391fb65f6e76dd953ea8a2306e33d8ffa84cbd2f48",
    reply = "f2062fb06a92917818bb8d65d213de30a95401d4d1",
    later = "ef59b661561c58622018020de933e3e7b07cfcbae3",
  },
  ["12 bytes, big-endian"] = {
    options = { counter_length = 12, byte_order = "big" },
    first = "7ed13042d9a817d4a9b9ffada55b61682a8d3073bf",
    second = "1a391fb65f6e76dd953ea8a2306e33d8ffa84cbd2f48",
    reply = "f2062fb06a92917818bb8d65d213de30a95401d4d1",
    later = "ef59b661561c58622018020de933e3e7b07cfcbae3",
  },
}

local function test_a_channel_seals_what_python_seals_for_each_counter()
  local a_to_b, b_to_a = channel_keys()
  for name, v in pairs(channel_vectors) do
    local alice, bob = ends(v.options)
    local first, second = alice:seal("first"), alice:seal("second", "header")
    assert(Codec.hex(first) == v.first, name)
    assert(Codec.hex(second) == v.second, name)
    assert(Codec.hex(bob:seal("reply")) == v.reply, name)
    assert(bob:open(unhex(v.first)) == "first", name)
    assert(bob:open(unhex(v.second), "header") == "second", name)
    -- A resumed end counts on from the messages before it.
    local resumed = Cipher.channel(a_to_b, b_to_a, { ...v.options, sent = 258 })
    assert(Codec.hex(resumed:seal("later", "h")) == v.later, name)
    local receiver = Cipher.channel(b_to_a, a_to_b, { ...v.options, received = 258 })
    assert(receiver:open(unhex(v.later), "h") == "later", name)
  end
end

--- A counter at its end must stop the channel: counting on would wrap to
--- a nonce already used.
local function test_a_channel_refuses_to_count_past_its_last_message()
  local a_to_b, b_to_a = channel_keys()
  local last = math.maxinteger - 1
  local alice = Cipher.channel(a_to_b, b_to_a, { sent = last })
  local bob = Cipher.channel(b_to_a, a_to_b, { received = last })
  local sealed = alice:seal("last")
  -- nonce = bytes(4) + struct.pack("<Q", 2**63 - 2)
  assert(Codec.hex(sealed) == "a86de79cd7a981af0b3c62fc66a688ce65ace33a")
  for _ = 1, 2 do
    Test.raises(function() alice:seal("one more") end, "last message")
  end
  assert(bob:open(sealed) == "last")
  local forged = Cipher.seal("chacha20-poly1305", a_to_b, "\0\0\0\0" .. string.pack("<i8", math.mininteger), "wrapped")
  for _, message in ipairs({ sealed, forged }) do
    local opened, why = bob:open(message)
    assert(opened == nil and why:find("last message", 1, true) ~= nil, why)
  end
end

local function test_channel_raises_on_a_key_length_or_option_it_cannot_use()
  local a_to_b, b_to_a = channel_keys()
  for _, key in ipairs({ "", a_to_b:sub(1, 31), a_to_b .. "\0" }) do
    Test.raises(function() Cipher.channel(key, b_to_a) end, "32 bytes")
    Test.raises(function() Cipher.channel(a_to_b, key) end, "32 bytes")
  end
  for _, length in ipairs({ 0, 4, 9, 16 }) do
    Test.raises(function() Cipher.channel(a_to_b, b_to_a, { counter_length = length }) end, "counter_length")
  end
  Test.raises(function() Cipher.channel(a_to_b, b_to_a, { sent = -1 }) end, "sent")
  Test.raises(function() Cipher.channel(a_to_b, b_to_a, { received = -1 }) end, "received")
end

--- The base point: the u-coordinate 9.
local base <const> = "\9" .. string.rep("\0", 31)

--- The secret of `private` and `peer`, which must be one.
local function shared(private: string, peer: string): string
  return (assert(Cipher.x25519(private, peer)))
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
  local alice_public = Cipher.x25519_public(alice)
  local bob_public = Cipher.x25519_public(bob)
  assert(Codec.hex(alice_public) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
  assert(Codec.hex(bob_public) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
  local secret, why = Cipher.x25519(alice, bob_public)
  assert(secret ~= nil and why == "", why)
  assert(Codec.hex(secret) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
  assert(shared(bob, alice_public) == secret)
end

--- The public key is the agreement with the base point, and the bits
--- RFC 7748 clamps (the low three and the top two) are no part of a key.
local function test_a_private_key_is_clamped()
  local private = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  local public = Cipher.x25519_public(private)
  assert(public == shared(private, base))
  for _, bit in ipairs({ 0, 1, 2, 254, 255 }) do
    assert(Cipher.x25519_public(flipped(private, bit)) == public, "bit " .. tostring(bit))
  end
  assert(Cipher.x25519_public(flipped(private, 3)) ~= public)
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
      local secret, why = Cipher.x25519(private, point)
      assert(secret == nil, Codec.hex(point) .. " answered a secret")
      assert(why ~= "", Codec.hex(point) .. " was refused without a reason")
    end
  end
end

local function test_x25519_raises_on_a_key_of_another_length()
  local private = string.rep("k", 32)
  local public = Cipher.x25519_public(private)
  for _, short in ipairs({ "", private:sub(1, 31), private .. "\0" }) do
    Test.raises(function() Cipher.x25519_public(short) end, "private key")
    Test.raises(function() Cipher.x25519(short, public) end, "private key")
    Test.raises(function() Cipher.x25519(private, short) end, "public key")
  end
end
