#!/usr/bin/env cosmic
local check = require("cosmic.check")
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

-- NIST FIPS 180-4 vectors: the canonical empty and "abc"
-- inputs, asserted byte-for-byte, not just by length.

local function test_sha256_nist_empty_vector()
  local digest = hash.sha256_hex("")
  local expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  assert(digest == expected,
    "sha256('') should match the NIST vector, got " .. digest)
end
test_sha256_nist_empty_vector()

local function test_sha256_nist_abc_vector()
  local digest = hash.sha256_hex("abc")
  local expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  assert(digest == expected,
    "sha256('abc') should match the NIST vector, got " .. digest)
end
test_sha256_nist_abc_vector()

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

-- argon2i / argon2d variants: happy-path round trips, not
-- just the invalid-variant guard below.

local function test_password_argon2i_roundtrip()
  local encoded = check.must(hash.password("pw-i", {
        variant = "argon2i", m_cost = 2048, t_cost = 1, parallelism = 1,
      }))
  assert(string.match(encoded, "^%$argon2i%$"),
    "encoded string should carry the argon2i tag, got: " .. tostring(encoded))
  assert(hash.verify_password(encoded, "pw-i") == true,
    "argon2i verify should accept the right password")
  assert(hash.verify_password(encoded, "wrong") == false,
    "argon2i verify should reject a wrong password")
end
test_password_argon2i_roundtrip()

local function test_password_argon2d_roundtrip()
  local encoded = check.must(hash.password("pw-d", {
        variant = "argon2d", m_cost = 2048, t_cost = 1, parallelism = 1,
      }))
  assert(string.match(encoded, "^%$argon2d%$"),
    "encoded string should carry the argon2d tag, got: " .. tostring(encoded))
  assert(hash.verify_password(encoded, "pw-d") == true,
    "argon2d verify should accept the right password")
  assert(hash.verify_password(encoded, "wrong") == false,
    "argon2d verify should reject a wrong password")
end
test_password_argon2d_roundtrip()

local function test_password_invalid_variant()
  -- cast: deliberate invalid input past Variant enum, for runtime guard
  local bad = {variant = "invalid"} as hash.HashOptions
  local encoded, err = hash.password("password", bad)
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

-- HMAC-SHA256: RFC 4231 test vectors

local function test_hmac_sha256_rfc4231_case1()
  local key = string.rep("\x0b", 20)
  local tag = check.must(hash.hmac_sha256(key, "Hi There"))
  local hex = codec.encode_hex(tag)
  assert(hex == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
    "RFC 4231 case 1 mismatch: " .. hex)
end
test_hmac_sha256_rfc4231_case1()

local function test_hmac_sha256_rfc4231_case2()
  local tag = check.must(hash.hmac_sha256("Jefe", "what do ya want for nothing?"))
  local hex = codec.encode_hex(tag)
  assert(hex == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    "RFC 4231 case 2 mismatch: " .. hex)
end
test_hmac_sha256_rfc4231_case2()

-- digest: NIST FIPS 180 / RFC 1321 / RFC 7693 "abc" vectors

local function test_digest_known_answers()
  local vectors: {hash.Algo: string} = {
    sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    sha512 = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
    .. "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
    sha384 = "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
    .. "8086072ba1e7cc2358baeca134c825a7",
    sha224 = "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7",
    sha1 = "a9993e364706816aba3e25717850c26c9cd0d89d",
    md5 = "900150983cd24fb0d6963f7d28e17f72",
    blake2b256 = "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319",
  }
  for algo, expected in pairs(vectors) do
    local d, err = hash.digest(algo, "abc")
    assert(d, "digest(" .. algo .. ") should succeed: " .. tostring(err))
    local hex = codec.encode_hex(d)
    assert(hex == expected, "digest(" .. algo .. ", 'abc') mismatch: " .. hex)
  end
end
test_digest_known_answers()

local function test_digest_raw_bytes_length()
  local lengths: {hash.Algo: number} = {
    sha256 = 32, sha512 = 64, sha384 = 48, sha224 = 28,
    sha1 = 20, md5 = 16, blake2b256 = 32,
  }
  for algo, len in pairs(lengths) do
    local d = hash.digest(algo, "")
    assert(d and #d == len,
      "digest(" .. algo .. ") should return " .. len .. " raw bytes")
  end
end
test_digest_raw_bytes_length()

local function test_digest_matches_sha256_convenience()
  local d = hash.digest("sha256", "hello")
  assert(d == hash.sha256("hello"), "digest('sha256') should match sha256()")
end
test_digest_matches_sha256_convenience()

local function test_digest_unknown_algo()
  local d, err = hash.digest("md4" as hash.Algo, "abc") -- cast: deliberate invalid input
  assert(d == nil, "digest should return nil for unknown algorithm")
  assert(err and err:match("unknown hash algorithm"),
    "error should name the problem, got: " .. tostring(err))
end
test_digest_unknown_algo()

-- hmac: RFC 4231 test vectors

local function test_hmac_rfc4231_case2_sha256()
  local tag, err = hash.hmac("sha256", "Jefe", "what do ya want for nothing?")
  assert(tag, "hmac should succeed: " .. tostring(err))
  local hex = codec.encode_hex(tag)
  assert(hex == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    "RFC 4231 case 2 (sha256) mismatch: " .. hex)
end
test_hmac_rfc4231_case2_sha256()

local function test_hmac_rfc4231_case2_sha512()
  local tag, err = hash.hmac("sha512", "Jefe", "what do ya want for nothing?")
  assert(tag, "hmac should succeed: " .. tostring(err))
  local hex = codec.encode_hex(tag)
  assert(hex == "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554"
    .. "9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737",
    "RFC 4231 case 2 (sha512) mismatch: " .. hex)
end
test_hmac_rfc4231_case2_sha512()

local function test_hmac_rfc2202_case1_sha1()
  -- RFC 2202 section 3 case 1
  local tag = check.must(hash.hmac("sha1", string.rep("\x0b", 20), "Hi There"))
  local hex = codec.encode_hex(tag)
  assert(hex == "b617318655057264e28bc0b6fb378c8ef146be00",
    "RFC 2202 case 1 (sha1) mismatch: " .. hex)
end
test_hmac_rfc2202_case1_sha1()

local function test_hmac_matches_hmac_sha256_convenience()
  local tag = hash.hmac("sha256", "key", "message")
  assert(tag == check.must(hash.hmac_sha256("key", "message")),
    "hmac('sha256') should match hmac_sha256()")
end
test_hmac_matches_hmac_sha256_convenience()

local function test_hmac_sha256_empty_key_rejected()
  -- hmac_sha256 delegates to hmac("sha256", ...), which refuses an
  -- empty key rather than silently returning a plain digest.
  local tag, err = hash.hmac_sha256("", "data")
  assert(tag == nil, "hmac_sha256 should return nil for empty key")
  assert(err and err:match("key"), "error should mention the key, got: " .. tostring(err))
end
test_hmac_sha256_empty_key_rejected()

local function test_hmac_unknown_algo()
  -- cast: deliberate invalid input
  local tag, err = hash.hmac("md4" as hash.Algo, "key", "data")
  assert(tag == nil, "hmac should return nil for unknown algorithm")
  assert(err and err:match("unknown hash algorithm"),
    "error should name the problem, got: " .. tostring(err))
end
test_hmac_unknown_algo()

local function test_hmac_empty_key_rejected()
  -- The C binding treats an empty key as "no key" and silently computes
  -- a plain digest; the wrapper must refuse rather than return a
  -- non-HMAC value.
  local tag, err = hash.hmac("sha256", "", "data")
  assert(tag == nil, "hmac should return nil for empty key")
  assert(err and err:match("key"), "error should mention the key, got: " .. tostring(err))
end
test_hmac_empty_key_rejected()

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
