#!/usr/bin/env cosmic
local codec = require("cosmic.codec")
local hash = require("cosmic.hash")

-- SHA-256 tests

local function test_sha256_returns_32_bytes()
  local digest = hash.sha256("hello")
  assert(#digest == 32, "sha256 should return 32 bytes, got " .. #digest)
end
test_sha256_returns_32_bytes()

local function test_sha256_deterministic()
  local hash1 = hash.sha256("test data")
  local hash2 = hash.sha256("test data")
  assert(hash1 == hash2, "sha256 should be deterministic")
end
test_sha256_deterministic()

local function test_sha256_different_inputs_different_outputs()
  local hash1 = hash.sha256("input1")
  local hash2 = hash.sha256("input2")
  assert(hash1 ~= hash2, "different inputs should produce different hashes")
end
test_sha256_different_inputs_different_outputs()

local function test_sha256_empty_string()
  local digest = hash.sha256("")
  assert(#digest == 32, "sha256 of empty string should return 32 bytes")
end
test_sha256_empty_string()

local function test_sha256_hex_returns_64_chars()
  local digest = hash.sha256_hex("hello")
  assert(#digest == 64, "sha256_hex should return 64 characters, got " .. #digest)
end
test_sha256_hex_returns_64_chars()

local function test_sha256_hex_is_lowercase_hex()
  local digest = hash.sha256_hex("test")
  assert(digest:match("^[0-9a-f]+$"), "sha256_hex should be lowercase hex, got " .. digest)
end
test_sha256_hex_is_lowercase_hex()

local function test_sha256_hex_known_value()
  -- SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
  local digest = hash.sha256_hex("hello")
  local expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  assert(digest == expected, "sha256_hex('hello') should be " .. expected .. ", got " .. digest)
end
test_sha256_hex_known_value()

-- Password hashing tests

local function test_password_returns_encoded_string()
  local encoded, err = hash.password("password123")
  assert(encoded, "password should succeed: " .. tostring(err))
  assert(type(encoded) == "string", "password should return a string")
  assert(#encoded > 0, "password should return non-empty string")
end
test_password_returns_encoded_string()

local function test_password_different_each_call()
  local encoded1, err1 = hash.password("password123")
  local encoded2, err2 = hash.password("password123")
  assert(encoded1, "first password should succeed: " .. tostring(err1))
  assert(encoded2, "second password should succeed: " .. tostring(err2))
  assert(encoded1 ~= encoded2, "password should use different salt each time")
end
test_password_different_each_call()

local function test_verify_password_correct()
  local encoded, err = hash.password("correct_password")
  assert(encoded, "password should succeed: " .. tostring(err))
  local valid = hash.verify_password(encoded, "correct_password")
  assert(valid == true, "verify_password should return true for correct password")
end
test_verify_password_correct()

local function test_verify_password_wrong()
  local encoded, err = hash.password("correct_password")
  assert(encoded, "password should succeed: " .. tostring(err))
  local valid = hash.verify_password(encoded, "wrong_password")
  assert(valid == false, "verify_password should return false for wrong password")
end
test_verify_password_wrong()

local function test_password_with_options()
  local encoded, err = hash.password("password", {
      m_cost = 2048,
      t_cost = 2,
      parallelism = 1,
      hash_len = 24,
    })
  assert(encoded, "password with options should succeed: " .. tostring(err))
  local valid = hash.verify_password(encoded, "password")
  assert(valid == true, "verify_password should work with custom options hash")
end
test_password_with_options()

local function test_password_empty()
  -- Empty passwords should be allowed (useful for testing, user validation should be done elsewhere)
  local encoded, err = hash.password("")
  assert(encoded, "password should handle empty password: " .. tostring(err))
  local valid = hash.verify_password(encoded, "")
  assert(valid == true, "verify_password should verify empty password")
end
test_password_empty()

local function test_password_unicode()
  local encoded, err = hash.password("пароль")
  assert(encoded, "password should handle unicode: " .. tostring(err))
  local valid = hash.verify_password(encoded, "пароль")
  assert(valid == true, "verify_password should verify unicode password")
end
test_password_unicode()

local function test_password_invalid_variant()
  local encoded, err = hash.password("password", {variant = "invalid"})
  assert(encoded == nil, "password should fail with invalid variant")
  assert(err and err:match("invalid variant"), "error should mention invalid variant")
end
test_password_invalid_variant()

-- FIX 1: verify_password should return false+error on malformed hash
local function test_verify_password_malformed_hash()
  local ok, err = hash.verify_password("not-a-hash", "password")
  assert(ok == false, "verify_password should return false for malformed hash, got: " .. tostring(ok))
  assert(err ~= nil, "verify_password should return error message for malformed hash")
end
test_verify_password_malformed_hash()

local function test_verify_password_returns_two_values_on_mismatch()
  local encoded = hash.password("correct")
  local ok, err = hash.verify_password(encoded, "wrong")
  assert(ok == false, "verify_password should return false for wrong password")
  assert(err == nil, "verify_password should NOT return error for clean mismatch (wrong password)")
end
test_verify_password_returns_two_values_on_mismatch()

-- FIX 2: default m_cost should be 19456 (OWASP minimum 19 MiB)
local function test_password_default_mcost_is_19456()
  local encoded, err = hash.password("password", {t_cost = 1})
  if not encoded then error("password with default m_cost should succeed: " .. tostring(err)) end
  assert(string.match(encoded, "m=19456"), "default m_cost should be 19456, encoded string: " .. encoded)
end
test_password_default_mcost_is_19456()

-- HMAC-SHA256 (issue #531): RFC 4231 test vectors

local function test_hmac_sha256_rfc4231_case1()
  local key = string.rep("\x0b", 20)
  local tag = hash.hmac_sha256(key, "Hi There")
  local hex = codec.encode_hex(tag)
  assert(hex == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
    "RFC 4231 case 1 mismatch: " .. hex)
end
test_hmac_sha256_rfc4231_case1()

local function test_hmac_sha256_rfc4231_case2()
  local tag = hash.hmac_sha256("Jefe", "what do ya want for nothing?")
  local hex = codec.encode_hex(tag)
  assert(hex == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    "RFC 4231 case 2 mismatch: " .. hex)
end
test_hmac_sha256_rfc4231_case2()

-- Constant-time comparison

local function test_constant_time_equal()
  assert(hash.constant_time_equal("", ""), "empty strings are equal")
  assert(hash.constant_time_equal("abc", "abc"), "equal strings compare equal")
  assert(not hash.constant_time_equal("abc", "abd"), "differing last byte")
  assert(not hash.constant_time_equal("abc", "xbc"), "differing first byte")
  assert(not hash.constant_time_equal("abc", "abcd"), "different lengths")
  local d1 = hash.sha256("a")
  local d2 = hash.sha256("a")
  local d3 = hash.sha256("b")
  assert(hash.constant_time_equal(d1, d2), "identical digests compare equal")
  assert(not hash.constant_time_equal(d1, d3), "different digests compare unequal")
end
test_constant_time_equal()
