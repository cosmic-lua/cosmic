#!/usr/bin/env cosmic
-- Tests for cosmic.crypto symmetric encryption module.
local crypto = require("cosmic.crypto")
local rand = require("cosmic.rand")

-- Generate a 32-byte key for tests
local test_key = rand.bytes(32)

local function test_encrypt_decrypt_roundtrip()
  local plaintext = "hello, world!"
  local ct, err = crypto.encrypt(plaintext, test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, test_key)
  assert(pt, "decrypt should succeed: " .. tostring(err2))
  assert(pt == plaintext, "roundtrip should recover plaintext, got: " .. tostring(pt))
end
test_encrypt_decrypt_roundtrip()

local function test_encrypt_different_nonce_each_time()
  local plaintext = "same input"
  local ct1, err1 = crypto.encrypt(plaintext, test_key)
  local ct2, err2 = crypto.encrypt(plaintext, test_key)
  assert(ct1, "first encrypt should succeed: " .. tostring(err1))
  assert(ct2, "second encrypt should succeed: " .. tostring(err2))
  assert(ct1 ~= ct2, "two encryptions of the same plaintext should differ")
end
test_encrypt_different_nonce_each_time()

local function test_decrypt_wrong_key_fails()
  local ct, err = crypto.encrypt("secret", test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local wrong_key = rand.bytes(32)
  local pt, err2 = crypto.decrypt(ct, wrong_key)
  assert(pt == nil, "decrypt with wrong key should fail")
  assert(err2 and err2:match("authentication"), "error should mention authentication, got: " .. tostring(err2))
end
test_decrypt_wrong_key_fails()

local function test_decrypt_tampered_ciphertext_fails()
  local ct, err = crypto.encrypt("secret data", test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  -- Flip a byte in the ciphertext area (byte 22 is start of ciphertext)
  local tampered = ct:sub(1, 21) .. string.char(ct:byte(22) ~ 0xFF) .. ct:sub(23)
  local pt, err2 = crypto.decrypt(tampered, test_key)
  assert(pt == nil, "decrypt of tampered ciphertext should fail")
  assert(err2 ~= nil, "should return an error message")
end
test_decrypt_tampered_ciphertext_fails()

local function test_decrypt_tampered_tag_fails()
  local ct, err = crypto.encrypt("secret data", test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  -- Flip the last byte (part of the 32-byte tag)
  local tampered = ct:sub(1, #ct - 1) .. string.char(ct:byte(#ct) ~ 0xFF)
  local pt, err2 = crypto.decrypt(tampered, test_key)
  assert(pt == nil, "decrypt of tampered tag should fail")
  assert(err2 and err2:match("authentication"), "error should mention authentication, got: " .. tostring(err2))
end
test_decrypt_tampered_tag_fails()

local function test_encrypt_empty_plaintext()
  local ct, err = crypto.encrypt("", test_key)
  assert(ct, "encrypt of empty string should succeed: " .. tostring(err))
  -- Wire format: 16 nonce + 4 len + 0 ciphertext + 32 tag = 52 bytes
  assert(#ct == 52, "empty plaintext blob should be 52 bytes, got: " .. #ct)
  local pt, err2 = crypto.decrypt(ct, test_key)
  assert(pt, "decrypt should succeed: " .. tostring(err2))
  assert(pt == "", "decrypted empty plaintext should be empty string")
end
test_encrypt_empty_plaintext()

local function test_encrypt_large_plaintext()
  -- 200 bytes: spans multiple 32-byte keystream blocks
  local plaintext = string.rep("A", 200)
  local ct, err = crypto.encrypt(plaintext, test_key)
  assert(ct, "encrypt of large plaintext should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, test_key)
  assert(pt, "decrypt should succeed: " .. tostring(err2))
  assert(pt == plaintext, "roundtrip should recover large plaintext")
end
test_encrypt_large_plaintext()

local function test_blob_too_short_fails()
  local short = "too short"
  local pt, err = crypto.decrypt(short, test_key)
  assert(pt == nil, "decrypt of too-short blob should fail")
  assert(err and err:match("short"), "error should mention short, got: " .. tostring(err))
end
test_blob_too_short_fails()

local function test_encrypt_requires_key()
  local pt, err = crypto.encrypt("data", "")
  assert(pt == nil, "encrypt with empty key should fail")
  assert(err ~= nil, "should return an error")
end
test_encrypt_requires_key()

local function test_decrypt_length_mismatch_fails()
  local ct, err = crypto.encrypt("hello", test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  -- Truncate the blob by a few bytes (removes part of the tag)
  local truncated = ct:sub(1, #ct - 5)
  local pt, err2 = crypto.decrypt(truncated, test_key)
  assert(pt == nil, "decrypt of truncated blob should fail")
  assert(err2 ~= nil, "should return an error message")
end
test_decrypt_length_mismatch_fails()

-- Password-based tests use low m_cost to keep test time reasonable
local function test_encrypt_with_password_roundtrip()
  local plaintext = "my secret data"
  local password = "correct horse battery staple"
  -- Use low cost for testing speed
  local ct, err = crypto.encrypt_with_password(plaintext, password)
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt_with_password(ct, password)
  assert(pt, "decrypt_with_password should succeed: " .. tostring(err2))
  assert(pt == plaintext, "password roundtrip should recover plaintext, got: " .. tostring(pt))
end
test_encrypt_with_password_roundtrip()

local function test_decrypt_with_password_wrong_password_fails()
  local ct, err = crypto.encrypt_with_password("secret", "correct_password")
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  local pt, err2 = crypto.decrypt_with_password(ct, "wrong_password")
  assert(pt == nil, "decrypt with wrong password should fail")
  assert(err2 ~= nil, "should return an error message")
end
test_decrypt_with_password_wrong_password_fails()

local function test_decrypt_with_password_blob_too_short()
  local short = string.rep("\0", 10)
  local pt, err = crypto.decrypt_with_password(short, "password")
  assert(pt == nil, "decrypt_with_password of too-short blob should fail")
  assert(err and err:match("short"), "error should mention short, got: " .. tostring(err))
end
test_decrypt_with_password_blob_too_short()
