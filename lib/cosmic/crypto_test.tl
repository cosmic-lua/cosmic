#!/usr/bin/env cosmic
local crypto = require("cosmic.crypto")

-- SHA-256 tests

local function test_sha256_returns_32_bytes()
  local hash = crypto.sha256("hello")
  assert(#hash == 32, "sha256 should return 32 bytes, got " .. #hash)
end
test_sha256_returns_32_bytes()

local function test_sha256_deterministic()
  local hash1 = crypto.sha256("test data")
  local hash2 = crypto.sha256("test data")
  assert(hash1 == hash2, "sha256 should be deterministic")
end
test_sha256_deterministic()

local function test_sha256_different_inputs_different_outputs()
  local hash1 = crypto.sha256("input1")
  local hash2 = crypto.sha256("input2")
  assert(hash1 ~= hash2, "different inputs should produce different hashes")
end
test_sha256_different_inputs_different_outputs()

local function test_sha256_empty_string()
  local hash = crypto.sha256("")
  assert(#hash == 32, "sha256 of empty string should return 32 bytes")
end
test_sha256_empty_string()

local function test_sha256_hex_returns_64_chars()
  local hash = crypto.sha256_hex("hello")
  assert(#hash == 64, "sha256_hex should return 64 characters, got " .. #hash)
end
test_sha256_hex_returns_64_chars()

local function test_sha256_hex_is_lowercase_hex()
  local hash = crypto.sha256_hex("test")
  assert(hash:match("^[0-9a-f]+$"), "sha256_hex should be lowercase hex, got " .. hash)
end
test_sha256_hex_is_lowercase_hex()

local function test_sha256_hex_known_value()
  -- SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
  local hash = crypto.sha256_hex("hello")
  local expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  assert(hash == expected, "sha256_hex('hello') should be " .. expected .. ", got " .. hash)
end
test_sha256_hex_known_value()

-- Random bytes tests

local function test_random_bytes_returns_requested_length()
  local bytes = crypto.random_bytes(16)
  assert(#bytes == 16, "random_bytes(16) should return 16 bytes, got " .. #bytes)
end
test_random_bytes_returns_requested_length()

local function test_random_bytes_different_each_call()
  local bytes1 = crypto.random_bytes(32)
  local bytes2 = crypto.random_bytes(32)
  assert(bytes1 ~= bytes2, "random_bytes should return different values each call")
end
test_random_bytes_different_each_call()

local function test_random_bytes_various_sizes()
  for _, size in ipairs({1, 8, 16, 32, 64, 128}) do
    local bytes = crypto.random_bytes(size)
    assert(#bytes == size, "random_bytes(" .. size .. ") should return " .. size .. " bytes, got " .. #bytes)
  end
end
test_random_bytes_various_sizes()

-- Password hashing tests

local function test_password_hash_returns_encoded_string()
  local encoded, err = crypto.password_hash("password123")
  assert(encoded, "password_hash should succeed: " .. tostring(err))
  assert(type(encoded) == "string", "password_hash should return a string")
  assert(#encoded > 0, "password_hash should return non-empty string")
end
test_password_hash_returns_encoded_string()

local function test_password_hash_different_each_call()
  local encoded1, err1 = crypto.password_hash("password123")
  local encoded2, err2 = crypto.password_hash("password123")
  assert(encoded1, "first password_hash should succeed: " .. tostring(err1))
  assert(encoded2, "second password_hash should succeed: " .. tostring(err2))
  assert(encoded1 ~= encoded2, "password_hash should use different salt each time")
end
test_password_hash_different_each_call()

local function test_password_verify_correct_password()
  local encoded, err = crypto.password_hash("correct_password")
  assert(encoded, "password_hash should succeed: " .. tostring(err))
  local valid = crypto.password_verify(encoded, "correct_password")
  assert(valid == true, "password_verify should return true for correct password")
end
test_password_verify_correct_password()

local function test_password_verify_wrong_password()
  local encoded, err = crypto.password_hash("correct_password")
  assert(encoded, "password_hash should succeed: " .. tostring(err))
  local valid = crypto.password_verify(encoded, "wrong_password")
  assert(valid == false, "password_verify should return false for wrong password")
end
test_password_verify_wrong_password()

local function test_password_hash_with_options()
  local encoded, err = crypto.password_hash("password", {
    m_cost = 2048,
    t_cost = 2,
    parallelism = 1,
    hash_len = 24,
  })
  assert(encoded, "password_hash with options should succeed: " .. tostring(err))
  local valid = crypto.password_verify(encoded, "password")
  assert(valid == true, "password_verify should work with custom options hash")
end
test_password_hash_with_options()

local function test_password_hash_empty_password()
  -- Empty passwords should be allowed (useful for testing, user validation should be done elsewhere)
  local encoded, err = crypto.password_hash("")
  assert(encoded, "password_hash should handle empty password: " .. tostring(err))
  local valid = crypto.password_verify(encoded, "")
  assert(valid == true, "password_verify should verify empty password")
end
test_password_hash_empty_password()

local function test_password_hash_unicode_password()
  local encoded, err = crypto.password_hash("пароль")
  assert(encoded, "password_hash should handle unicode: " .. tostring(err))
  local valid = crypto.password_verify(encoded, "пароль")
  assert(valid == true, "password_verify should verify unicode password")
end
test_password_hash_unicode_password()

local function test_password_hash_invalid_variant()
  local encoded, err = crypto.password_hash("password", { variant = "invalid" })
  assert(encoded == nil, "password_hash should fail with invalid variant")
  assert(err and err:match("invalid variant"), "error should mention invalid variant")
end
test_password_hash_invalid_variant()
