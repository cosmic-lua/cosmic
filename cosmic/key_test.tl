--- Proves that [`Key.read`] reads back what a key's `pem` writes, and
--- the keys OpenSSL writes (made here by Python's cryptography): their
--- thumbprints were computed there too. Proves too that each algorithm
--- signs and checks, and what [`Key.secret`] and [`Key.public`] refuse.

local Codec = require("cosmic.codec")
local Der = require("cosmic.internal.der")
local Key = require("cosmic.key")
local Rand = require("cosmic.rand")
local rsa_fixture = require("build.rsa_fixture")

--- A P-256 key as `openssl ecparam -genkey` writes it: the curve's own
--- block, then SEC 1.
local EC_SEC1 <const> = [[
-----BEGIN EC PARAMETERS-----
BggqhkjOPQMBBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIMTl9rJTmoXSYVpXrMOjtUegeHfUtKfaCvuYVlUQ89AjoAoGCCqGSM49
AwEHoUQDQgAE1GPP+ZLt+uT4h5lqLuPWI94Cidzq1+D4KoHLEBtDi4lBfKP5ZRl8
gMNXxGZC7fcICRv8entym2BDgtf6nnoxRA==
-----END EC PRIVATE KEY-----
]]

--- The same P-256 key as PKCS #8, as `openssl genpkey` writes it.
local EC_PKCS8 <const> = [[
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgxOX2slOahdJhWles
w6O1R6B4d9S0p9oK+5hWVRDz0COhRANCAATUY8/5ku365PiHmWou49Yj3gKJ3OrX
4PgqgcsQG0OLiUF8o/llGXyAw1fEZkLt9wgJG/x6e3KbYEOC1/qeejFE
-----END PRIVATE KEY-----
]]

local EC_THUMBPRINT <const> = "T_0H08vI5oGhm3VasxryndtsIvruFS31Vys8Eviid20"

--- A 2048-bit RSA key as PKCS #8.
local RSA_PKCS8 <const> = [[
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCX0Tm5JkN0k8pv
hPzkP4Vk9QnP5B4jzZaCKHEMPYE4UcFY2ygL+yihRI+L7Uiw3uxlHGedogjI2N6O
ACCpBU9DybbDkd5O4E3/QpUfpvbTFtwSJ8aefZd7hEZatrXbnp1PQ+bMNg5vGIXj
NIlyht1mLVeVCVXKTkhAQc/2Kzob3AjSCHdLp9eH66EEaqmViuZAAaGWVFTOK9Ug
JMRWVH8VKYpXCDhCJVwML7amXLGDNg81c2yPOwvzryCqTsO7XpzYiBRix9JSpPgQ
LeLdho5DwDVlQu4XKJjI2IFlfY0TFBwYoh5uQOJDaZOi+E6hUtCJxaUrX2m5jlB7
a8Y8RWEbAgMBAAECggEAM1gm6gfXU3NySPIUp0sWXbUDuwP+74PlzaJIzWd1rurz
dY41BoxMSvJJi/zVkz/pei63mlfFGcxCxIqlgRRTIO10+sJ4CXwR1O0bSweoPW7j
Qd6i7VIza6oqMx7M9Xg44qhnw5PaoNcN3PAVNh8HfLmD/9sW4SNFiznWz/4Bmo70
MOQlNASMGbLdovX0b992//MeQeyOmq7t8tNM23jySSZ+INNuknNSJ8L25CgO+7ew
hZgrkC4yKj2sXjLv9oXl1LV+NZV5NfYCEvaVrhiswbMT5QefuPJJJ67XeE/deVTB
J5cnxu4E5CWIaXlGvvp0S++1k4DZksIlGzFPbffuPQKBgQDGSso4rqaG7HSL+nEQ
Ox8bklh5xPnQ+RB0cX+ljQiGSGLrpFO8BT34PW3UYcSVwO5Uw2oH3X81E64442Ug
AyEhyhJnak0qB/kmop57HW+dYmaw8YhpVfP/GKXbTzNtqgrp9krhP3Qep6o/Pd8x
k/kosEAvdRbh+Wk6hZtQ9O2XpQKBgQDD//Q/l9nXZJjnCY1n1Cu2ugp/HjQiTSyy
A63TrGsSsx1DykQuF4p1FGiDkujXYTTKEET9UVWeK8d4xAEZ+wkRh1aW+/uBfAQZ
oJqDxMBwW+0M3LNX1gBLhKp6cBZBDZ1yL7w17DL6V4ixE+wqA5sAnNrZTKpJ4blW
XuQyFs+5vwKBgDbyInbyblKU0va2vv2wZD5PnxSe8FpnqZeam7RUEDildkO1lT5U
dYeD/hsLvF2CyIfUXl0vk0Ax4+T/ndXxCA1E4TSm0BsFepSqGyAiV/tUeQAu7Y3C
s4nMWqkamTWaGMwb40PnQVX9P7+mdWJXjoMn06FS4LRdWDtPKmqUdAHBAoGBAKn4
D9cKF3aLnXFVvlPZEeOPKEUeazWH2YeyWw7iSaRYwbsk78VM0tw/S3c2ckc82+uS
+lD3NJlK+9uFljLymOWjiPq8IFoksuWKehRlDkEh5sstpTU5tt3GeZReGV5msS/x
p3TXlUm1mSt+zGGO6N86JyskKdSSNAhrl9a8I32/AoGAfGporzCSmNckBLe5aSDE
RHJMCr1pYWnuDScah26w6MwQrYwHwxoB+BG4K8LN9VYW3Nk+PtEHC6/YXmPqu1un
TXZ0SrdyTl5YyNvDwkN0lPwnCqilQa7SPpvEVHFojKPrjJOJWsiOmsK8Kfcw/taG
SsMKmsInazqzphrfY16bfys=
-----END PRIVATE KEY-----
]]

local RSA_THUMBPRINT <const> = "2XVnaP0k_4hDUhexPgtKdBF8nTbtTp5EfRecqF9DmPQ"

--- Keys that are refused: on P-384, Ed25519, encrypted, and RSA of 1024 bits.
local P384 <const> = [[
-----BEGIN EC PRIVATE KEY-----
MIGkAgEBBDBRprzVZqKZkMxJivIQRtISjqspP3I7CO2+xuXsAUv3327/NsF7AkdF
DHAgUut1YDWgBwYFK4EEACKhZANiAAQd3F6+u0uQpIzyxyOWzw6LJjBwmX4umQmS
t/OPThMW5S45CKMVYBmRbE6fglQfYKkOYH6IDw3nH3SNsY/eqF6DBI13PLMlaSj6
EdbTTZJvzUOYq9UwwqT/u3pq7JdNGtk=
-----END EC PRIVATE KEY-----
]]

local ED25519 <const> = [[
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIAecSSm1SRTnCaLAtrjR1pfzrYnUgpWZMvi96uz6HrR+
-----END PRIVATE KEY-----
]]

local ENCRYPTED <const> = [[
-----BEGIN EC PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-256-CBC,67A48D461F773D443247E8C375EFCE91

ch4OV4paxICFXHTiTwrgDMqknVjiOFKA/KGv9OFM0wIBwjXmau6UMqskh0J1N8+c
dgDYQuxv7JY8+LAaUFG2j5u9dW44UxEvnADMp49pO8f9inWtDgwvifzk+2t5jcao
LB1Ky+AmTEU03T9F5u8Nqr5IHInLTY/8nkldkbKEfVk=
-----END EC PRIVATE KEY-----
]]

local RSA_1024 <const> = [[
-----BEGIN RSA PRIVATE KEY-----
MIICWwIBAAKBgQDt7nFnrsAv+8723QJj9Q2PkpmWwGo3Cbi9sHpFuCjcnzZWWYnj
TUbkEMk3UmuYp02Mjz/BKDmmWTE3ZLrlgsyfkI1qzoh2tG5rKIJVwo1uxUZD/Hsh
RUQIWGISizPfw6MMnrEEqQe5AsdVsrfK7nrYb+XETFj0d8aKcdTwl0pcWQIDAQAB
AoGAbZnR+Y3hD/lxu/vQtxTR+1nvkCbwhove4tphaK5NfFuG3z39q4wUZMhquCYq
VDZ1HZN7LdIGxF7/seGfykt3UAITKjxBqaThEV0qerg7xNEonG33m8k1ZuG6Spmx
oBRykgXQe8VFJq3pdZSxbRq+m2fRFD0lmLhn2yJydQwpS9ECQQD6YCgjpaintWjw
rWBkSyzpCcz86s3hwRFQRaHWBYziGTab8w1hQQZQmZJy6rtbwrTez+kta4vY5RhS
yKEmRCFlAkEA80a5E9E1vMj3PjxLrd0zpgmWwCrqpXvS+ViaObp/oynFhcLHDqXO
DTnz3yn1wBbZisFYPW5WniWAPwmrOzU55QJAGgFYyfMP5HN0NeNcKq6gOIg7EV32
Cme6O6Mv3wHukyFZSbNiBWLym/aHfoYg9bPwg2AG8R/Fg76v2xFZo5bZ/QJAT8DW
ue1zLYHAtFF2CfijjwJDvpoTNM8kOgRXAyfl4iq2i4RwV5f5thJSpc2OuDuFc9yw
vernUI9AvOnBjfaEFQJAAd5+rPpMHRxHPHa2vtne1DZZKHItucBFTfazNkppIQVf
P05l4cbAifQRObUT/Mszap2CHuUZ1Fm91VUWnXWhww==
-----END RSA PRIVATE KEY-----
]]

--- The RFC 7638 thumbprint of [`ED25519`], as OpenSSL's public key
--- spells its JWK.
local ED25519_THUMBPRINT <const> = "O5sbJHJyWbc2hSNSFbSol4xuL-idru6gnl1uQAdUWIQ"

local function test_each_algorithm_signs_and_checks()
  for _, key in ipairs({ Key.generate("ed25519"), Key.generate("p256"), assert(Key.secret("rsa", rsa_fixture.FIRST)) }) do
    local signature = key:sign("message")
    assert(key.public:verify("message", signature), key.alg)
    assert(not key.public:verify("other", signature), key.alg)
    assert(not key.public:verify("message", "short"), key.alg)
    local read = assert(Key.read(key:pem()))
    assert(read.alg == key.alg and read.public.bytes == key.public.bytes and read:pem() == key:pem(), key.alg)
    assert(#key.public:thumbprint() == 43, key.alg)
  end
end

local function test_a_key_prints_its_algorithm_alone()
  local key = Key.generate("p256")
  assert(tostring(key) == "Key.Secret (p256)", tostring(key))
  assert(tostring(key.public) == "Key.Public (p256)", tostring(key.public))
end

local function test_a_p256_key_reads_back_from_its_own_pem()
  local key = Key.generate("p256")
  local pem = key:pem()
  assert(pem:find("^%-%-%-%-%-BEGIN EC PRIVATE KEY%-%-%-%-%-\n") ~= nil, pem)
  local read = assert(Key.read(pem))
  assert(read.public:thumbprint() == key.public:thumbprint() and read.public:spki() == key.public:spki())
  assert(read:pem() == pem)
end

local function test_an_rsa_key_reads_back_from_its_own_pem()
  local key = assert(Key.secret("rsa", rsa_fixture.FIRST))
  local pem = key:pem()
  assert(pem:find("^%-%-%-%-%-BEGIN RSA PRIVATE KEY%-%-%-%-%-\n") ~= nil, pem)
  for line in pem:gmatch("[^\n]+") do assert(#line <= 64, line) end
  local read = assert(Key.read(pem))
  assert(read.public:thumbprint() == key.public:thumbprint() and read:pem() == pem)
end

local function test_openssls_p256_keys_read_as_sec_1_and_as_pkcs_8()
  local sec1 = assert(Key.read(EC_SEC1))
  assert(sec1.public:thumbprint() == EC_THUMBPRINT, sec1.public:thumbprint())
  local pkcs8 = assert(Key.read(EC_PKCS8))
  assert(pkcs8.public:thumbprint() == EC_THUMBPRINT)
  -- What it writes back is the SEC 1 block OpenSSL wrote.
  assert(sec1:pem() == EC_SEC1:match("%-%-%-%-%-BEGIN EC PRIVATE KEY.*$"))
end

local function test_openssls_rsa_key_reads_as_pkcs_8()
  local key = assert(Key.read("some words first\n" .. RSA_PKCS8))
  assert(key.alg == "rsa" and key.public:thumbprint() == RSA_THUMBPRINT, key.public:thumbprint())
end

local function test_openssls_ed25519_key_reads_as_pkcs_8_and_writes_back_the_same()
  local key = assert(Key.read(ED25519))
  assert(key.alg == "ed25519" and key.public:thumbprint() == ED25519_THUMBPRINT, key.public:thumbprint())
  assert(key:pem() == ED25519)
end

local function test_a_key_that_is_none_or_one_not_taken_is_refused()
  local cases: {{string}} = {
    { "", "key: no private key in the text" },
    { "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n", "key: no private key in the text" },
    { "-----BEGIN EC PRIVATE KEY-----\nnot base64\n-----END EC PRIVATE KEY-----\n", "is not base64" },
    { "-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n", "no SEC 1 ECPrivateKey" },
    { "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n", "no PKCS #8 PrivateKeyInfo" },
    { "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n", "key: not an RSA secret" },
    { P384, "key: an EC key is on P-256, not another curve" },
    { ENCRYPTED, "key: the key is encrypted" },
    { "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n", "key: the key is encrypted" },
    { RSA_1024, "key: an RSA key is from 2048 to 4096 bits" },
  }
  for i, case in ipairs(cases) do
    local text, expected = assert(case[1]), assert(case[2])
    local key, why = Key.read(text)
    assert(key == nil, "refused")
    assert(why.message:find(expected, 1, true) ~= nil, tostring(i) .. ": " .. why.message)
  end
end

local function test_a_p256_secret_out_of_range_is_refused()
  -- SEC 1 around a secret of 32 zero bytes, which no key has.
  local zero = "-----BEGIN EC PRIVATE KEY-----\n" ..
    "MDECAQEEIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAoGCCqGSM49AwEH\n" ..
    "-----END EC PRIVATE KEY-----\n"
  local key, why = Key.read(zero)
  assert(key == nil, "refused")
  assert(why.message:find("key: not a P-256 secret", 1, true) ~= nil, why.message)
end

local function test_a_p256_secret_shorter_than_32_bytes_is_read_as_its_value()
  -- SEC 1 asks for 32 bytes, but some writers drop the leading zeros.
  local short = "\1" .. assert(Rand.entropy(30))
  local der = "\x30\x24\x02\x01\x01\x04\x1f" .. short
  local key = assert(Key.read("-----BEGIN EC PRIVATE KEY-----\n" .. Codec.base64(der) ..
      "\n-----END EC PRIVATE KEY-----\n"))
  assert(key.public:thumbprint() == assert(Key.secret("p256", "\0" .. short)).public:thumbprint())
end

local function test_a_key_with_crlf_line_endings_is_read()
  local key = assert(Key.read((EC_SEC1:gsub("\n", "\r\n"))))
  assert(key.public:thumbprint() == EC_THUMBPRINT)
end

local function test_secret_refuses_bytes_sign_refuses()
  local function refused(alg: Key.Alg, bytes: string, expected: string)
    local key, why = Key.secret(alg, bytes)
    assert(key == nil, "refused")
    assert(why.message:find(expected, 1, true) ~= nil, why.message)
  end
  refused("ed25519", "short", "key: ")
  refused("p256", string.rep("\0", 32), "key: not a P-256 secret")
  refused("rsa", "not der", "key: not an RSA secret")
end

local function test_public_reads_bytes_from_anyone_and_refuses_a_wrong_shape()
  local key = Key.generate("ed25519")
  local public = assert(Key.public("ed25519", key.public.bytes))
  assert(public:verify("message", key:sign("message")))
  local function refused(alg: Key.Alg, bytes: string, expected: string)
    local read, why = Key.public(alg, bytes)
    assert(read == nil, "refused")
    assert(why.message:find(expected, 1, true) ~= nil, why.message)
  end
  refused("ed25519", "short", "32 bytes, not 5")
  refused("p256", string.rep("\5", 65), "start with 0x04")
  refused("rsa", "not der", "a SEQUENCE of n and e")
end

local function test_the_jwk_of_each_algorithm_matches_sign()
  local p256 = Key.generate("p256")
  local jwk = p256.public:jwk()
  assert(jwk["kty"] == "EC" and jwk["crv"] == "P-256")
  assert(Codec.unbase64url(assert(jwk["x"])) == p256.public.bytes:sub(2, 33))
  local ed = Key.generate("ed25519")
  assert(#ed.public.bytes == 32 and ed.public.bytes ~= ed.secret)
  local rsa = assert(Key.secret("rsa", rsa_fixture.FIRST))
  assert(rsa.public:jwk()["e"] == "AQAB")
end

local function test_generate_refuses_bits_but_for_rsa()
  local ok, why = pcall(Key.generate, "p256", { bits = 2048 })
  assert(not ok and tostring(why):find("bits is the size of an RSA key", 1, true) ~= nil, tostring(why))
  local refused, raised = pcall(Key.generate, "rsa", { bits = 1024 })
  assert(not refused and tostring(raised):find("key: ", 1, true) ~= nil, tostring(raised))
end

local function test_an_rsa_jwk_is_its_modulus_and_exponent_with_no_zero_in_front()
  local key = assert(Key.secret("rsa", rsa_fixture.FIRST))
  local n = assert(Codec.unbase64url(assert(key.public:jwk()["n"])))
  assert(#n == 256 and (n:byte(1) or 0) >= 0x80, "n is the 2048-bit modulus, with no zero in front")
  assert(Der.sequence(Der.unsigned(n), Der.unsigned("\1\0\1")) == key.public.bytes)
end

--- RFC 7638 section 3.1: the thumbprint of its RSA key, from the members
--- `e`, `kty` and `n` in that order.
local function test_an_rsa_thumbprint_matches_rfc_7638()
  local n = assert(Codec.unbase64url(
    "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4" ..
      "n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0z" ..
      "gdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csF" ..
      "Cur-kEgU8awapJzKnqDKgw"))
  local key = assert(Key.public("rsa", Der.sequence(Der.unsigned(n), Der.unsigned("\1\0\1"))))
  assert(key:thumbprint() == "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs", key:thumbprint())
end

local function test_a_p256_point_of_another_length_is_refused()
  local key = Key.generate("p256")
  local read, why = Key.public("p256", key.public.bytes:sub(1, 64))
  assert(read == nil, "refused")
  assert(why.message:find("65 bytes", 1, true) ~= nil, why.message)
end

--- RFC 8410 section 4: an Ed25519 SubjectPublicKeyInfo is the OID
--- 1.3.101.112 alone, then the 32 bytes.
local function test_an_ed25519_spki_is_rfc_8410s()
  local key = Key.generate("ed25519")
  assert(key.public:spki() == "\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00" .. key.public.bytes)
end

local function test_an_ed25519_pkcs_8_key_whose_seed_is_no_octet_string_is_refused()
  -- PrivateKeyInfo { 0, { 1.3.101.112 }, OCTET STRING { INTEGER 5 } }.
  local der = "\x30\x0f\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x03\x02\x01\x05"
  local key, why = Key.read("-----BEGIN PRIVATE KEY-----\n" .. Codec.base64(der) .. "\n-----END PRIVATE KEY-----\n")
  assert(key == nil, "refused")
  assert(why.message:find("an ed25519 private key is an OCTET STRING of its secret", 1, true) ~= nil, why.message)
end
