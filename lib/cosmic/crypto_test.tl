#!/usr/bin/env cosmic
local crypto = require("cosmic.crypto")
local rand = require("cosmic.rand")

-- encrypt/decrypt roundtrip

local function test_encrypt_decrypt_roundtrip()
  local key = rand.bytes(32)
  local plaintext = "hello, world"
  local ct, err = crypto.encrypt(plaintext, key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, key)
  assert(pt, "decrypt should succeed: " .. tostring(err2))
  assert(pt == plaintext, "roundtrip should recover plaintext, got: " .. tostring(pt))
end
test_encrypt_decrypt_roundtrip()

local function test_encrypt_decrypt_empty_plaintext()
  local key = rand.bytes(32)
  local ct, err = crypto.encrypt("", key)
  assert(ct, "encrypt empty should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, key)
  assert(pt ~= nil, "decrypt empty should succeed: " .. tostring(err2))
  assert(pt == "", "decrypt empty should return empty string, got: " .. tostring(pt))
end
test_encrypt_decrypt_empty_plaintext()

local function test_encrypt_decrypt_binary_data()
  local key = rand.bytes(32)
  local plaintext = rand.bytes(100)
  local ct, err = crypto.encrypt(plaintext, key)
  assert(ct, "encrypt binary should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, key)
  assert(pt, "decrypt binary should succeed: " .. tostring(err2))
  assert(pt == plaintext, "roundtrip should recover binary plaintext")
end
test_encrypt_decrypt_binary_data()

-- wrong key fails decryption

local function test_decrypt_wrong_key_fails()
  local key1 = rand.bytes(32)
  local key2 = rand.bytes(32)
  local ct, err = crypto.encrypt("secret", key1)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, key2)
  assert(pt == nil, "decrypt with wrong key should fail")
  assert(err2 and err2:match("authentication failed"), "error should say authentication failed, got: " .. tostring(err2))
end
test_decrypt_wrong_key_fails()

-- key length validation

local function test_encrypt_short_key_fails()
  local ct, err = crypto.encrypt("hello", "tooshort")
  assert(ct == nil, "encrypt with short key should fail")
  assert(err and err:match("32 bytes"), "error should mention 32 bytes, got: " .. tostring(err))
end
test_encrypt_short_key_fails()

local function test_encrypt_long_key_fails()
  local ct, err = crypto.encrypt("hello", rand.bytes(33))
  assert(ct == nil, "encrypt with 33-byte key should fail")
  assert(err and err:match("32 bytes"), "error should mention 32 bytes, got: " .. tostring(err))
end
test_encrypt_long_key_fails()

local function test_decrypt_wrong_key_length_fails()
  local key = rand.bytes(32)
  local ct, err = crypto.encrypt("hello", key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, "short")
  assert(pt == nil, "decrypt with short key should fail")
  assert(err2 and err2:match("32 bytes"), "error should mention 32 bytes, got: " .. tostring(err2))
end
test_decrypt_wrong_key_length_fails()

-- ciphertext tampering detected

local function test_tampered_ciphertext_fails()
  local key = rand.bytes(32)
  local ct, err = crypto.encrypt("tamper me", key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  -- Flip last byte of ciphertext
  local tampered = ct:sub(1, -2) .. string.char((string.byte(ct, -1) ~ 0xff) as integer)
  local pt, err2 = crypto.decrypt(tampered, key)
  assert(pt == nil, "decrypt tampered ciphertext should fail")
  assert(err2 and err2:match("authentication failed"), "error should say authentication failed, got: " .. tostring(err2))
end
test_tampered_ciphertext_fails()

local function test_tampered_tag_fails()
  local key = rand.bytes(32)
  local ct, err = crypto.encrypt("tamper tag", key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  -- Flip a byte in the tag area (bytes 17-48)
  local tampered = ct:sub(1, 16) .. string.char((string.byte(ct, 17) ~ 0x01) as integer) .. ct:sub(18)
  local pt, err2 = crypto.decrypt(tampered, key)
  assert(pt == nil, "decrypt with tampered tag should fail")
  assert(err2 and err2:match("authentication failed"), "error should say authentication failed, got: " .. tostring(err2))
end
test_tampered_tag_fails()

local function test_too_short_ciphertext_fails()
  local key = rand.bytes(32)
  local pt, err = crypto.decrypt("tooshort", key)
  assert(pt == nil, "decrypt too-short blob should fail")
  assert(err and err:match("too short"), "error should say too short, got: " .. tostring(err))
end
test_too_short_ciphertext_fails()

-- non-deterministic encryption

local function test_encrypt_nondeterministic()
  local key = rand.bytes(32)
  local ct1, err1 = crypto.encrypt("same plaintext", key)
  local ct2, err2 = crypto.encrypt("same plaintext", key)
  assert(ct1, "first encrypt should succeed: " .. tostring(err1))
  assert(ct2, "second encrypt should succeed: " .. tostring(err2))
  assert(ct1 ~= ct2, "encrypt should produce different ciphertext each time (different nonce)")
end
test_encrypt_nondeterministic()

-- ciphertext length

local function test_ciphertext_length()
  local key = rand.bytes(32)
  local plaintext = "hello"
  local ct, err = crypto.encrypt(plaintext, key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  -- nonce(16) + tag(32) + plaintext
  local expected_len = 16 + 32 + #plaintext
  assert(#ct == expected_len, "ciphertext length should be " .. expected_len .. ", got " .. #ct)
end
test_ciphertext_length()

-- encrypt_with_password / decrypt_with_password roundtrip

local function test_password_encrypt_decrypt_roundtrip()
  local plaintext = "password vault secret"
  local password = "master password 123"
  local ct, err = crypto.encrypt_with_password(plaintext, password)
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt_with_password(ct, password)
  assert(pt, "decrypt_with_password should succeed: " .. tostring(err2))
  assert(pt == plaintext, "roundtrip should recover plaintext, got: " .. tostring(pt))
end
test_password_encrypt_decrypt_roundtrip()

-- wrong password fails decryption

local function test_password_wrong_password_fails()
  local ct, err = crypto.encrypt_with_password("secret", "correct password")
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt_with_password(ct, "wrong password")
  assert(pt == nil, "decrypt_with_password with wrong password should fail")
  assert(err2 ~= nil, "should return an error, got nil")
end
test_password_wrong_password_fails()

-- password encryption is non-deterministic

local function test_password_encrypt_nondeterministic()
  local ct1, err1 = crypto.encrypt_with_password("same", "pass")
  local ct2, err2 = crypto.encrypt_with_password("same", "pass")
  assert(ct1, "first encrypt_with_password should succeed: " .. tostring(err1))
  assert(ct2, "second encrypt_with_password should succeed: " .. tostring(err2))
  assert(ct1 ~= ct2, "encrypt_with_password should use different salt each time")
end
test_password_encrypt_nondeterministic()
