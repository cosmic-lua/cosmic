#!/usr/bin/env cosmic
local crypto = require("cosmic.crypto")

-- Generate a fixed test key (32 bytes of 0x42)
local test_key = string.rep("\66", 32)

local function test_encrypt_decrypt_roundtrip()
  local plaintext = "hello, world!"
  local ct, err = crypto.encrypt(plaintext, test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local pt, derr = crypto.decrypt(ct, test_key)
  assert(pt, "decrypt should succeed: " .. tostring(derr))
  assert(pt == plaintext, "roundtrip should return original: got " .. tostring(pt))
end
test_encrypt_decrypt_roundtrip()

local function test_encrypt_produces_different_ciphertext()
  local plaintext = "same plaintext"
  local ct1, err1 = crypto.encrypt(plaintext, test_key)
  local ct2, err2 = crypto.encrypt(plaintext, test_key)
  assert(ct1, "first encrypt should succeed: " .. tostring(err1))
  assert(ct2, "second encrypt should succeed: " .. tostring(err2))
  assert(ct1 ~= ct2, "nonce randomness: same plaintext should produce different ciphertexts")
end
test_encrypt_produces_different_ciphertext()

local function test_decrypt_wrong_key_fails()
  local ct, err = crypto.encrypt("secret", test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local wrong_key = string.rep("\99", 32)
  local pt, derr = crypto.decrypt(ct, wrong_key)
  assert(pt == nil, "decrypt with wrong key should fail")
  assert(derr == "authentication failed", "error should be 'authentication failed', got: " .. tostring(derr))
end
test_decrypt_wrong_key_fails()

local function test_decrypt_tampered_fails()
  local ct, err = crypto.encrypt("secret", test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  -- Flip a bit in the middle of the ciphertext
  local mid = math.floor(#ct / 2)
  local tampered = ct:sub(1, mid - 1) .. string.char(ct:byte(mid) ~ 0xff) .. ct:sub(mid + 1)
  local pt, derr = crypto.decrypt(tampered, test_key)
  assert(pt == nil, "decrypt tampered ciphertext should fail")
  assert(derr == "authentication failed", "error should be 'authentication failed', got: " .. tostring(derr))
end
test_decrypt_tampered_fails()

local function test_decrypt_too_short_fails()
  local pt, err = crypto.decrypt("short", test_key)
  assert(pt == nil, "decrypt too-short input should fail")
  assert(err == "ciphertext too short", "error should be 'ciphertext too short', got: " .. tostring(err))
end
test_decrypt_too_short_fails()

local function test_encrypt_empty_string()
  local ct, err = crypto.encrypt("", test_key)
  assert(ct, "encrypt empty string should succeed: " .. tostring(err))
  local pt, derr = crypto.decrypt(ct, test_key)
  assert(pt, "decrypt empty string should succeed: " .. tostring(derr))
  assert(pt == "", "roundtrip of empty string should return empty string, got: " .. tostring(pt))
end
test_encrypt_empty_string()

local function test_key_length()
  local plaintext = "test"
  local ct, err = crypto.encrypt(plaintext, test_key)
  assert(ct, "encrypt should succeed: " .. tostring(err))
  local expected = 12 + #plaintext + 32
  assert(#ct == expected, "ciphertext length should be " .. expected .. ", got " .. #ct)
end
test_key_length()

local function test_encrypt_with_password_roundtrip()
  local plaintext = "password vault entry"
  local password = "correct-horse-battery-staple"
  local ct, err = crypto.encrypt_with_password(plaintext, password)
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  local pt, derr = crypto.decrypt_with_password(ct, password)
  assert(pt, "decrypt_with_password should succeed: " .. tostring(derr))
  assert(pt == plaintext, "roundtrip should return original, got: " .. tostring(pt))
end
test_encrypt_with_password_roundtrip()

local function test_decrypt_with_password_wrong_password_fails()
  local ct, err = crypto.encrypt_with_password("secret", "correct-password")
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  local pt, derr = crypto.decrypt_with_password(ct, "wrong-password")
  assert(pt == nil, "decrypt with wrong password should fail")
  assert(derr == "authentication failed", "error should be 'authentication failed', got: " .. tostring(derr))
end
test_decrypt_with_password_wrong_password_fails()

local function test_decrypt_with_password_too_short_fails()
  local pt, err = crypto.decrypt_with_password("tooshort", "password")
  assert(pt == nil, "decrypt_with_password too-short input should fail")
  assert(err == "ciphertext too short", "error should be 'ciphertext too short', got: " .. tostring(err))
end
test_decrypt_with_password_too_short_fails()

local function test_password_ciphertext_length()
  local plaintext = "test"
  local ct, err = crypto.encrypt_with_password(plaintext, "mypassword")
  assert(ct, "encrypt_with_password should succeed: " .. tostring(err))
  -- salt(16) + nonce(12) + #pt + hmac(32)
  local expected = 16 + 12 + #plaintext + 32
  assert(#ct == expected, "password ciphertext length should be " .. expected .. ", got " .. #ct)
end
test_password_ciphertext_length()
