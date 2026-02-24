#!/usr/bin/env cosmic
local crypto = require("cosmic.crypto")
local rand = require("cosmic.rand")

-- Helpers

local function make_key(): string
  return rand.bytes(32)
end

-- encrypt/decrypt roundtrip

local function test_encrypt_decrypt_roundtrip()
  local key = make_key()
  local plaintext = "hello, world!"
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt(ciphertext, key)
  assert(result, "decrypt should succeed: " .. tostring(err2))
  assert(result == plaintext, "roundtrip mismatch: got " .. tostring(result))
end
test_encrypt_decrypt_roundtrip()

-- Different ciphertext each call (random nonce)

local function test_encrypt_different_ciphertext_each_call()
  local key = make_key()
  local plaintext = "same plaintext"
  local c1, err1 = crypto.encrypt(plaintext, key)
  local c2, err2 = crypto.encrypt(plaintext, key)
  assert(c1, "first encrypt should succeed: " .. tostring(err1))
  assert(c2, "second encrypt should succeed: " .. tostring(err2))
  assert(c1 ~= c2, "ciphertext should differ each call due to random nonce")
end
test_encrypt_different_ciphertext_each_call()

-- Tampered MAC should fail authentication

local function test_decrypt_fails_tampered_mac()
  local key = make_key()
  local ciphertext, err = crypto.encrypt("secret", key)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  -- Flip a byte in the last 32 bytes (MAC)
  local tampered = ciphertext:sub(1, -2) .. string.char(ciphertext:byte(-1) ~ 0xff)
  local result, err2 = crypto.decrypt(tampered, key)
  assert(result == nil, "decrypt should fail on tampered MAC")
  assert(err2 and err2:match("authentication failed"), "expected authentication error, got: " .. tostring(err2))
end
test_decrypt_fails_tampered_mac()

-- Tampered ciphertext body should fail authentication

local function test_decrypt_fails_tampered_ciphertext()
  local key = make_key()
  local plaintext = "secret data here"
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  -- Flip a byte in the ciphertext body (between nonce and MAC)
  -- Position 17 is the first byte of ciphertext body
  local pos = 17
  local flipped = string.char(ciphertext:byte(pos) ~ 0x01)
  local tampered = ciphertext:sub(1, pos - 1) .. flipped .. ciphertext:sub(pos + 1)
  local result, err2 = crypto.decrypt(tampered, key)
  assert(result == nil, "decrypt should fail on tampered ciphertext")
  assert(err2 and err2:match("authentication failed"), "expected authentication error, got: " .. tostring(err2))
end
test_decrypt_fails_tampered_ciphertext()

-- Wrong key size for encrypt

local function test_encrypt_requires_32_byte_key()
  local result, err = crypto.encrypt("data", "short_key")
  assert(result == nil, "encrypt should fail with wrong key size")
  assert(err and err:match("32 bytes"), "error should mention 32 bytes, got: " .. tostring(err))
end
test_encrypt_requires_32_byte_key()

-- Wrong key size for decrypt

local function test_decrypt_requires_32_byte_key()
  local result, err = crypto.decrypt("some data padded to 48 bytes for this testXXXXXX", "bad")
  assert(result == nil, "decrypt should fail with wrong key size")
  assert(err and err:match("32 bytes"), "error should mention 32 bytes, got: " .. tostring(err))
end
test_decrypt_requires_32_byte_key()

-- Too-short ciphertext for decrypt

local function test_decrypt_too_short_input()
  local key = make_key()
  local result, err = crypto.decrypt("short", key)
  assert(result == nil, "decrypt should fail with too-short input")
  assert(err and err:match("too short"), "error should mention too short, got: " .. tostring(err))
end
test_decrypt_too_short_input()

-- Exactly 48 bytes (empty plaintext) should succeed

local function test_encrypt_empty_plaintext()
  local key = make_key()
  local ciphertext, err = crypto.encrypt("", key)
  assert(ciphertext, "encrypt of empty string should succeed: " .. tostring(err))
  assert(#ciphertext == 48, "empty plaintext should produce 48-byte output, got " .. #ciphertext)
  local result, err2 = crypto.decrypt(ciphertext, key)
  assert(result, "decrypt should succeed: " .. tostring(err2))
  assert(result == "", "expected empty string, got: " .. tostring(result))
end
test_encrypt_empty_plaintext()

-- Wrong key for decrypt

local function test_decrypt_wrong_key()
  local key1 = make_key()
  local key2 = make_key()
  local ciphertext, err = crypto.encrypt("secret", key1)
  assert(ciphertext, "encrypt should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt(ciphertext, key2)
  assert(result == nil, "decrypt with wrong key should fail")
  assert(err2 and err2:match("authentication failed"), "expected authentication error, got: " .. tostring(err2))
end
test_decrypt_wrong_key()

-- Password-based encrypt/decrypt roundtrip

local function test_encrypt_with_password_roundtrip()
  local plaintext = "password-protected secret"
  local password = "hunter2"
  local ciphertext, err = crypto.encrypt_with_password(plaintext, password)
  assert(ciphertext, "encrypt_with_password should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt_with_password(ciphertext, password)
  assert(result, "decrypt_with_password should succeed: " .. tostring(err2))
  assert(result == plaintext, "roundtrip mismatch: got " .. tostring(result))
end
test_encrypt_with_password_roundtrip()

-- Wrong password should fail authentication

local function test_decrypt_with_password_wrong_password()
  local ciphertext, err = crypto.encrypt_with_password("secret", "correct_password")
  assert(ciphertext, "encrypt_with_password should succeed: " .. tostring(err))
  local result, err2 = crypto.decrypt_with_password(ciphertext, "wrong_password")
  assert(result == nil, "decrypt_with_password with wrong password should fail")
  assert(err2 ~= nil, "expected error, got nil")
end
test_decrypt_with_password_wrong_password()

-- Password ciphertext size

local function test_encrypt_with_password_output_size()
  local plaintext = "hello"
  local ciphertext, err = crypto.encrypt_with_password(plaintext, "pass")
  assert(ciphertext, "encrypt_with_password should succeed: " .. tostring(err))
  -- salt(16) + nonce(16) + plaintext(5) + mac(32) = 69
  assert(#ciphertext == 69, "expected 69 bytes, got " .. #ciphertext)
end
test_encrypt_with_password_output_size()
