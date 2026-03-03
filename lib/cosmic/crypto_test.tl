#!/usr/bin/env cosmic
local crypto = require("cosmic.crypto")
local rand = require("cosmic.rand")

-- Helper: make a fresh 32-byte key
local function make_key(): string
  return rand.bytes(32)
end

-- Round-trip encrypt/decrypt with a 32-byte key
local function test_encrypt_decrypt_round_trip()
  local key = make_key()
  local plain = "hello, world"
  local ct, err = crypto.encrypt(plain, key)
  assert(ct, "encrypt failed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, key)
  assert(pt, "decrypt failed: " .. tostring(err2))
  assert(pt == plain, "round-trip mismatch: got " .. tostring(pt))
end
test_encrypt_decrypt_round_trip()

-- Encrypt twice: nonce randomness means different ciphertext
local function test_encrypt_returns_different_ciphertext_each_call()
  local key = make_key()
  local plain = "same plaintext"
  local ct1, err1 = crypto.encrypt(plain, key)
  local ct2, err2 = crypto.encrypt(plain, key)
  assert(ct1, "first encrypt failed: " .. tostring(err1))
  assert(ct2, "second encrypt failed: " .. tostring(err2))
  assert(ct1 ~= ct2, "two encryptions of same plaintext should differ")
end
test_encrypt_returns_different_ciphertext_each_call()

-- Wrong key: decrypt must fail
local function test_decrypt_wrong_key_fails()
  local key1 = make_key()
  local key2 = make_key()
  local ct, err = crypto.encrypt("secret", key1)
  assert(ct, "encrypt failed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, key2)
  assert(pt == nil, "decrypt with wrong key should return nil")
  assert(err2 ~= nil, "decrypt with wrong key should return error")
end
test_decrypt_wrong_key_fails()

-- Tampered ciphertext: authentication must fail
local function test_decrypt_tampered_ciphertext_fails()
  local key = make_key()
  local ct, err = crypto.encrypt("original", key)
  assert(ct, "encrypt failed: " .. tostring(err))
  -- Flip the last byte
  local tampered = ct:sub(1, -2) .. string.char(string.byte(ct, -1) ~ 0x01)
  local pt, err2 = crypto.decrypt(tampered, key)
  assert(pt == nil, "decrypt of tampered ciphertext should return nil")
  assert(err2 ~= nil, "decrypt of tampered ciphertext should return error")
end
test_decrypt_tampered_ciphertext_fails()

-- Too-short ciphertext: must fail validation
local function test_decrypt_too_short_fails()
  local key = make_key()
  local pt, err = crypto.decrypt("short", key)
  assert(pt == nil, "decrypt of too-short data should return nil")
  assert(err ~= nil, "decrypt of too-short data should return error")
end
test_decrypt_too_short_fails()

-- Key must be exactly 32 bytes
local function test_encrypt_requires_32_byte_key()
  local pt1, err1 = crypto.encrypt("data", "tooshort")
  assert(pt1 == nil, "encrypt with short key should return nil")
  assert(err1 ~= nil, "encrypt with short key should return error")

  local pt2, err2 = crypto.encrypt("data", string.rep("x", 33))
  assert(pt2 == nil, "encrypt with long key should return nil")
  assert(err2 ~= nil, "encrypt with long key should return error")
end
test_encrypt_requires_32_byte_key()

-- Empty plaintext is valid
local function test_encrypt_empty_plaintext()
  local key = make_key()
  local ct, err = crypto.encrypt("", key)
  assert(ct, "encrypt of empty string failed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, key)
  assert(pt, "decrypt of empty string failed: " .. tostring(err2))
  assert(pt == "", "round-trip of empty string should yield empty string")
end
test_encrypt_empty_plaintext()

-- Large plaintext spans multiple keystream blocks
local function test_encrypt_large_plaintext()
  local key = make_key()
  local plain = string.rep("A", 1000)
  local ct, err = crypto.encrypt(plain, key)
  assert(ct, "encrypt of large plaintext failed: " .. tostring(err))
  local pt, err2 = crypto.decrypt(ct, key)
  assert(pt, "decrypt of large plaintext failed: " .. tostring(err2))
  assert(pt == plain, "round-trip of large plaintext mismatch")
end
test_encrypt_large_plaintext()

-- Password-based round-trip
local function test_encrypt_with_password_round_trip()
  local plain = "password-protected secret"
  local ct, err = crypto.encrypt_with_password(plain, "my password")
  assert(ct, "encrypt_with_password failed: " .. tostring(err))
  local pt, err2 = crypto.decrypt_with_password(ct, "my password")
  assert(pt, "decrypt_with_password failed: " .. tostring(err2))
  assert(pt == plain, "password round-trip mismatch: got " .. tostring(pt))
end
test_encrypt_with_password_round_trip()

-- Wrong password: must fail
local function test_decrypt_with_password_wrong_password_fails()
  local ct, err = crypto.encrypt_with_password("data", "correct")
  assert(ct, "encrypt_with_password failed: " .. tostring(err))
  local pt, err2 = crypto.decrypt_with_password(ct, "wrong")
  assert(pt == nil, "decrypt_with_password with wrong password should return nil")
  assert(err2 ~= nil, "decrypt_with_password with wrong password should return error")
end
test_decrypt_with_password_wrong_password_fails()

-- Tampered password ciphertext: must fail
local function test_decrypt_with_password_tampered_fails()
  local ct, err = crypto.encrypt_with_password("data", "password")
  assert(ct, "encrypt_with_password failed: " .. tostring(err))
  -- Flip the last byte of the ciphertext
  local tampered = ct:sub(1, -2) .. string.char(string.byte(ct, -1) ~ 0x01)
  local pt, err2 = crypto.decrypt_with_password(tampered, "password")
  assert(pt == nil, "decrypt_with_password of tampered data should return nil")
  assert(err2 ~= nil, "decrypt_with_password of tampered data should return error")
end
test_decrypt_with_password_tampered_fails()

-- Password encrypt produces different ciphertext on each call (different salt)
local function test_encrypt_with_password_different_each_call()
  local ct1, err1 = crypto.encrypt_with_password("same", "password")
  local ct2, err2 = crypto.encrypt_with_password("same", "password")
  assert(ct1, "first encrypt_with_password failed: " .. tostring(err1))
  assert(ct2, "second encrypt_with_password failed: " .. tostring(err2))
  assert(ct1 ~= ct2, "two password encryptions of same plaintext should differ")
end
test_encrypt_with_password_different_each_call()
