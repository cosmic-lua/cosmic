#!/usr/bin/env cosmic
local crypto = require("cosmic.crypto")
local rand = require("cosmic.rand")

-- Helper: flip one byte in a string at position pos.
local function flip_byte(s: string, pos: integer): string
  local b = s:byte(pos)
  return s:sub(1, pos - 1) .. string.char(b ~ 0xff) .. s:sub(pos + 1)
end

-- Key-based encrypt/decrypt tests

local function test_encrypt_decrypt_roundtrip()
  local key = rand.bytes(32)
  local plaintext = "hello, world!"
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt(ciphertext, key)
  assert(result, "decrypt should succeed: " .. tostring(err2))
  assert(result == plaintext, "roundtrip should recover plaintext, got: " .. tostring(result))
end
test_encrypt_decrypt_roundtrip()

local function test_encrypt_produces_different_output_each_time()
  local key = rand.bytes(32)
  local plaintext = "same plaintext"
  local c1, err1 = crypto.encrypt(plaintext, key)
  local c2, err2 = crypto.encrypt(plaintext, key)
  assert(c1, "first encrypt should succeed: " .. tostring(err1))
  assert(c2, "second encrypt should succeed: " .. tostring(err2))
  assert(c1 ~= c2, "encrypt should produce different ciphertext each call (random nonce)")
end
test_encrypt_produces_different_output_each_time()

local function test_encrypt_ciphertext_longer_than_plaintext()
  local key = rand.bytes(32)
  local plaintext = "test"
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  -- nonce(16) + mac(32) + plaintext(4) = 52
  assert(#ciphertext == 52, "ciphertext length should be 52, got " .. #ciphertext)
end
test_encrypt_ciphertext_longer_than_plaintext()

local function test_decrypt_wrong_key_fails()
  local key1 = rand.bytes(32)
  local key2 = rand.bytes(32)
  local plaintext = "secret data"
  local ciphertext, err = crypto.encrypt(plaintext, key1)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt(ciphertext, key2)
  assert(result == nil, "decrypt with wrong key should fail")
  assert(err2 and err2:find("authentication"), "error should mention authentication, got: " .. tostring(err2))
end
test_decrypt_wrong_key_fails()

local function test_decrypt_tampered_mac_fails()
  local key = rand.bytes(32)
  local plaintext = "sensitive"
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  -- Flip a byte in the MAC region (bytes 17–48)
  local tampered = flip_byte(ciphertext, 20)
  local result, err2 = crypto.decrypt(tampered, key)
  assert(result == nil, "decrypt of tampered MAC should fail")
  assert(err2 and err2:find("authentication"), "error should mention authentication, got: " .. tostring(err2))
end
test_decrypt_tampered_mac_fails()

local function test_decrypt_tampered_ciphertext_fails()
  local key = rand.bytes(32)
  local plaintext = "sensitive data here"
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  -- Flip a byte in the ciphertext region (after nonce + mac = 48 bytes)
  local tampered = flip_byte(ciphertext, 50)
  local result, err2 = crypto.decrypt(tampered, key)
  assert(result == nil, "decrypt of tampered ciphertext should fail")
  assert(err2 and err2:find("authentication"), "error should mention authentication, got: " .. tostring(err2))
end
test_decrypt_tampered_ciphertext_fails()

local function test_encrypt_empty_string()
  local key = rand.bytes(32)
  local ciphertext, err = crypto.encrypt("", key)
  assert(ciphertext, "encrypt of empty string should succeed: " .. tostring(err))
  -- nonce(16) + mac(32) + plaintext(0) = 48
  assert(#ciphertext == 48, "empty ciphertext should be 48 bytes, got " .. #ciphertext)
  local result, err2 = crypto.decrypt(ciphertext, key)
  assert(result, "decrypt of empty string should succeed: " .. tostring(err2))
  assert(result == "", "roundtrip of empty string should return empty string")
end
test_encrypt_empty_string()

local function test_decrypt_truncated_ciphertext_fails()
  local key = rand.bytes(32)
  local result, err = crypto.decrypt("short", key)
  assert(result == nil, "decrypt of truncated ciphertext should fail")
  assert(err and err:find("too short"), "error should mention too short, got: " .. tostring(err))
end
test_decrypt_truncated_ciphertext_fails()

local function test_encrypt_large_data()
  local key = rand.bytes(32)
  -- 1 KB of data (crosses multiple 32-byte keystream blocks)
  local plaintext = string.rep("A", 1024)
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(ciphertext, "encrypt of large data should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt(ciphertext, key)
  assert(result, "decrypt of large data should succeed: " .. tostring(err2))
  assert(result == plaintext, "roundtrip of large data should recover plaintext")
end
test_encrypt_large_data()

-- Password-based encrypt/decrypt tests
-- Use reduced Argon2 parameters for test speed by testing the API shape;
-- the actual KDF is exercised end-to-end.

local function test_encrypt_with_password_roundtrip()
  local plaintext = "my secret password vault entry"
  local password = "correct horse battery staple"
  local ciphertext, err = crypto.encrypt_with_password(plaintext, password)
  assert(ciphertext, "encrypt_with_password should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt_with_password(ciphertext, password)
  assert(result, "decrypt_with_password should succeed: " .. tostring(err2))
  assert(result == plaintext, "roundtrip should recover plaintext, got: " .. tostring(result))
end
test_encrypt_with_password_roundtrip()

local function test_encrypt_with_password_different_output_each_time()
  local plaintext = "same plaintext"
  local password = "same password"
  local c1, err1 = crypto.encrypt_with_password(plaintext, password)
  local c2, err2 = crypto.encrypt_with_password(plaintext, password)
  assert(c1, "first encrypt_with_password should succeed: " .. tostring(err1))
  assert(c2, "second encrypt_with_password should succeed: " .. tostring(err2))
  assert(c1 ~= c2, "encrypt_with_password should produce different ciphertext each call")
end
test_encrypt_with_password_different_output_each_time()

local function test_decrypt_with_password_wrong_password_fails()
  local plaintext = "secret"
  local ciphertext, err = crypto.encrypt_with_password(plaintext, "correct")
  assert(ciphertext, "encrypt_with_password should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt_with_password(ciphertext, "wrong")
  assert(result == nil, "decrypt_with_password with wrong password should fail")
  assert(err2, "should return an error message")
end
test_decrypt_with_password_wrong_password_fails()

local function test_decrypt_with_password_truncated_fails()
  local result, err = crypto.decrypt_with_password("short", "password")
  assert(result == nil, "decrypt_with_password of truncated ciphertext should fail")
  assert(err and err:find("too short"), "error should mention too short, got: " .. tostring(err))
end
test_decrypt_with_password_truncated_fails()
