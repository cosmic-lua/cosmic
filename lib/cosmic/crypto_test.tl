--- Tests for cosmic.crypto symmetric encryption.
local crypto = require("cosmic.crypto")
local rand = require("cosmic.rand")

local function test_encrypt_decrypt_roundtrip()
  local key = rand.bytes(32)
  local plaintext = "hello, world!"
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(not err, "encrypt error: " .. tostring(err))
  assert(type(ciphertext) == "string", "expected string ciphertext")
  -- blob is nonce(16) + tag(32) + ciphertext(N) = 48 + N
  assert(#ciphertext == 48 + #plaintext, "unexpected blob length")
  local got, derr = crypto.decrypt(ciphertext, key)
  assert(not derr, "decrypt error: " .. tostring(derr))
  assert(got == plaintext, "roundtrip mismatch: got " .. tostring(got))
end

local function test_encrypt_produces_different_output()
  local key = rand.bytes(32)
  local plaintext = "same plaintext"
  local c1 = crypto.encrypt(plaintext, key)
  local c2 = crypto.encrypt(plaintext, key)
  assert(c1 ~= c2, "two encryptions of the same plaintext must differ (random nonce)")
end

local function test_decrypt_wrong_key_fails()
  local key1 = rand.bytes(32)
  local key2 = rand.bytes(32)
  local ciphertext = crypto.encrypt("secret", key1)
  local result, err = crypto.decrypt(ciphertext, key2)
  assert(result == nil, "expected nil result with wrong key")
  assert(err ~= nil, "expected error with wrong key")
  assert(err:find("authentication failed"), "expected auth failure, got: " .. tostring(err))
end

local function test_decrypt_tampered_ciphertext_fails()
  local key = rand.bytes(32)
  local blob = crypto.encrypt("important data", key)
  -- Flip the last byte of the ciphertext (after nonce+tag=48 bytes)
  local tampered = blob:sub(1, #blob - 1) .. string.char((string.byte(blob, #blob) as integer ~ 0xff) as integer)
  local result, err = crypto.decrypt(tampered, key)
  assert(result == nil, "expected nil result with tampered ciphertext")
  assert(err ~= nil, "expected error with tampered ciphertext")
  assert(err:find("authentication failed"), "expected auth failure, got: " .. tostring(err))
end

local function test_decrypt_tampered_tag_fails()
  local key = rand.bytes(32)
  local blob = crypto.encrypt("data to protect", key)
  -- Flip a byte in the tag (bytes 17-48)
  local tampered = blob:sub(1, 16) .. string.char((string.byte(blob, 17) as integer ~ 0x01) as integer) .. blob:sub(18)
  local result, err = crypto.decrypt(tampered, key)
  assert(result == nil, "expected nil result with tampered tag")
  assert(err ~= nil, "expected error with tampered tag")
  assert(err:find("authentication failed"), "expected auth failure, got: " .. tostring(err))
end

local function test_encrypt_empty_plaintext()
  local key = rand.bytes(32)
  local ciphertext, err = crypto.encrypt("", key)
  assert(not err, "encrypt error on empty plaintext: " .. tostring(err))
  assert(#ciphertext == 48, "empty plaintext blob should be exactly 48 bytes")
  local got, derr = crypto.decrypt(ciphertext, key)
  assert(not derr, "decrypt error on empty plaintext: " .. tostring(derr))
  assert(got == "", "expected empty string, got: " .. tostring(got))
end

local function test_encrypt_large_plaintext()
  local key = rand.bytes(32)
  -- 100 bytes > 3 SHA-256 blocks
  local plaintext = string.rep("A", 100)
  local ciphertext, err = crypto.encrypt(plaintext, key)
  assert(not err, "encrypt error: " .. tostring(err))
  local got, derr = crypto.decrypt(ciphertext, key)
  assert(not derr, "decrypt error: " .. tostring(derr))
  assert(got == plaintext, "large plaintext roundtrip failed")
end

local function test_encrypt_invalid_key_size()
  local short_key = "tooshort"
  local result, err = crypto.encrypt("data", short_key)
  assert(result == nil, "expected nil result with short key")
  assert(err ~= nil, "expected error with short key")
  assert(err:find("32 bytes"), "expected key size error, got: " .. tostring(err))
end

local function test_decrypt_truncated_blob_fails()
  local key = rand.bytes(32)
  local result, err = crypto.decrypt("tooshort", key)
  assert(result == nil, "expected nil result with truncated blob")
  assert(err ~= nil, "expected error with truncated blob")
  assert(err:find("too short"), "expected too short error, got: " .. tostring(err))
end

local function test_encrypt_with_password_roundtrip()
  local plaintext = "password-encrypted message"
  local password = "my-strong-passphrase"
  local blob, err = crypto.encrypt_with_password(plaintext, password)
  assert(not err, "encrypt_with_password error: " .. tostring(err))
  assert(type(blob) == "string", "expected string blob")
  -- blob is salt(16) + nonce(16) + tag(32) + ciphertext(N) = 64 + N
  assert(#blob == 64 + #plaintext, "unexpected password blob length")
  local got, derr = crypto.decrypt_with_password(blob, password)
  assert(not derr, "decrypt_with_password error: " .. tostring(derr))
  assert(got == plaintext, "password roundtrip mismatch: got " .. tostring(got))
end

local function test_decrypt_with_password_wrong_password_fails()
  local blob = crypto.encrypt_with_password("secret data", "correct-password")
  local result, err = crypto.decrypt_with_password(blob, "wrong-password")
  assert(result == nil, "expected nil result with wrong password")
  assert(err ~= nil, "expected error with wrong password")
  assert(err:find("authentication failed"), "expected auth failure, got: " .. tostring(err))
end

local function test_encrypt_with_password_empty_string()
  local blob, err = crypto.encrypt_with_password("", "passphrase")
  assert(not err, "encrypt_with_password error on empty: " .. tostring(err))
  assert(#blob == 64, "empty plaintext password blob should be 64 bytes")
  local got, derr = crypto.decrypt_with_password(blob, "passphrase")
  assert(not derr, "decrypt_with_password error on empty: " .. tostring(derr))
  assert(got == "", "expected empty string, got: " .. tostring(got))
end

test_encrypt_decrypt_roundtrip()
test_encrypt_produces_different_output()
test_decrypt_wrong_key_fails()
test_decrypt_tampered_ciphertext_fails()
test_decrypt_tampered_tag_fails()
test_encrypt_empty_plaintext()
test_encrypt_large_plaintext()
test_encrypt_invalid_key_size()
test_decrypt_truncated_blob_fails()
test_encrypt_with_password_roundtrip()
test_decrypt_with_password_wrong_password_fails()
test_encrypt_with_password_empty_string()
