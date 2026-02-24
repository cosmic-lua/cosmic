#!/usr/bin/env cosmic
local crypto = require("cosmic.crypto")
local rand = require("cosmic.rand")

-- Helper: generate a valid 32-byte key
local function new_key(): string
  return rand.bytes(32)
end

local function test_encrypt_returns_bytes()
  local key = new_key()
  local ct, err = crypto.encrypt("hello world", key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  assert(type(ct) == "string", "encrypt should return a string")
  -- overhead = 1 (version) + 16 (nonce) + 32 (hmac) = 49 bytes
  assert(#ct == #"hello world" + 49, "ciphertext length should be plaintext + 49")
end
test_encrypt_returns_bytes()

local function test_encrypt_decrypt_roundtrip()
  local key = new_key()
  local plaintext = "secret message"
  local ct, err = crypto.encrypt(plaintext, key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local pt, derr = crypto.decrypt(ct, key)
  assert(pt, "decrypt should succeed: " .. tostring(derr))
  assert(pt == plaintext, "decrypted text should match original, got: " .. tostring(pt))
end
test_encrypt_decrypt_roundtrip()

local function test_encrypt_different_nonce_each_call()
  local key = new_key()
  local ct1, err1 = crypto.encrypt("same plaintext", key)
  local ct2, err2 = crypto.encrypt("same plaintext", key)
  assert(ct1, "first encrypt should succeed: " .. tostring(err1))
  assert(ct2, "second encrypt should succeed: " .. tostring(err2))
  assert(ct1 ~= ct2, "two encryptions of same plaintext should differ (different nonce)")
end
test_encrypt_different_nonce_each_call()

local function test_decrypt_wrong_key_fails()
  local key1 = new_key()
  local key2 = new_key()
  local ct, err = crypto.encrypt("secret", key1)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local pt, derr = crypto.decrypt(ct, key2)
  assert(pt == nil, "decrypt with wrong key should return nil")
  assert(derr and #derr > 0, "decrypt with wrong key should return error message")
end
test_decrypt_wrong_key_fails()

local function test_decrypt_tampered_ciphertext_fails()
  local key = new_key()
  local ct, err = crypto.encrypt("secret data", key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  -- Flip a byte in the ciphertext body (after version+nonce = 17 bytes)
  local tampered = ct:sub(1, 20) .. string.char(ct:byte(21) ~ 0xff) .. ct:sub(22)
  local pt, derr = crypto.decrypt(tampered, key)
  assert(pt == nil, "decrypt of tampered ciphertext should return nil")
  assert(derr and derr:match("authentication failed"), "error should mention authentication: " .. tostring(derr))
end
test_decrypt_tampered_ciphertext_fails()

local function test_decrypt_truncated_fails()
  local key = new_key()
  local pt, err = crypto.decrypt("tooshort", key)
  assert(pt == nil, "decrypt of truncated input should return nil")
  assert(err and #err > 0, "decrypt of truncated input should return error")
end
test_decrypt_truncated_fails()

local function test_wrong_key_length_fails()
  local short_key = "notlong"
  local ct, err = crypto.encrypt("hello", short_key)
  assert(ct == nil, "encrypt with short key should return nil")
  assert(err and err:match("32 bytes"), "error should mention 32 bytes: " .. tostring(err))

  local key = new_key()
  local ct2, err2 = crypto.encrypt("hello", key)
  assert(ct2, "encrypt should succeed: " .. tostring(err2))
  local pt, derr = crypto.decrypt(ct2, short_key)
  assert(pt == nil, "decrypt with short key should return nil")
  assert(derr and derr:match("32 bytes"), "error should mention 32 bytes: " .. tostring(derr))
end
test_wrong_key_length_fails()

local function test_encrypt_empty_plaintext()
  local key = new_key()
  local ct, err = crypto.encrypt("", key)
  assert(ct, "encrypt of empty plaintext should succeed: " .. tostring(err))
  assert(#ct == 49, "empty plaintext ciphertext should be exactly 49 bytes overhead")
  local pt, derr = crypto.decrypt(ct, key)
  assert(pt, "decrypt of empty plaintext should succeed: " .. tostring(derr))
  assert(pt == "", "decrypted empty plaintext should be empty string")
end
test_encrypt_empty_plaintext()

local function test_encrypt_large_plaintext()
  local key = new_key()
  local plaintext = string.rep("abcdefghij", 1024) -- 10240 bytes
  assert(#plaintext == 10240, "test plaintext should be 10240 bytes")
  local ct, err = crypto.encrypt(plaintext, key)
  assert(ct, "encrypt of large plaintext should succeed: " .. tostring(err))
  assert(#ct == #plaintext + 49, "large ciphertext length should be plaintext + 49")
  local pt, derr = crypto.decrypt(ct, key)
  assert(pt, "decrypt of large plaintext should succeed: " .. tostring(derr))
  assert(pt == plaintext, "decrypted large plaintext should match original")
end
test_encrypt_large_plaintext()

local function test_encrypt_with_password_roundtrip()
  local plaintext = "password vault entry"
  local password = "my-master-password"
  local ct, err = crypto.encrypt_with_password(plaintext, password)
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  assert(type(ct) == "string", "encrypt_with_password should return a string")
  -- overhead = 1 (version) + 16 (salt) + 49 (inner) = 66 bytes
  assert(#ct == #plaintext + 66, "password ciphertext length should be plaintext + 66")
  local pt, derr = crypto.decrypt_with_password(ct, password)
  assert(pt, "decrypt_with_password should succeed: " .. tostring(derr))
  assert(pt == plaintext, "decrypted text should match original, got: " .. tostring(pt))
end
test_encrypt_with_password_roundtrip()

local function test_decrypt_with_password_wrong_password_fails()
  local ct, err = crypto.encrypt_with_password("secret", "correct-password")
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  local pt, derr = crypto.decrypt_with_password(ct, "wrong-password")
  assert(pt == nil, "decrypt with wrong password should return nil")
  assert(derr and #derr > 0, "decrypt with wrong password should return error: " .. tostring(derr))
end
test_decrypt_with_password_wrong_password_fails()

local function test_decrypt_with_password_tampered_fails()
  local ct, err = crypto.encrypt_with_password("secret data", "my-password")
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  -- Flip a byte deep in the ciphertext (after version+salt+version+nonce = 1+16+1+16 = 34 bytes)
  local tampered = ct:sub(1, 40) .. string.char(ct:byte(41) ~ 0xff) .. ct:sub(42)
  local pt, derr = crypto.decrypt_with_password(tampered, "my-password")
  assert(pt == nil, "decrypt of tampered password ciphertext should return nil")
  assert(derr and #derr > 0, "tampered decrypt should return error: " .. tostring(derr))
end
test_decrypt_with_password_tampered_fails()
