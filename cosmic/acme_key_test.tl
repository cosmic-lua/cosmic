--- Proves that [`Acme.read_key`] reads back what [`Acme.Key`]'s `pem`
--- writes, and the keys OpenSSL writes (made here by Python's
--- cryptography): their thumbprints were computed there too.

local Acme = require("cosmic.acme")
local Codec = require("cosmic.codec")
local Rand = require("cosmic.rand")
local Sign = require("cosmic.sign")
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

local function test_a_p256_key_reads_back_from_its_own_pem()
  local key = Acme.p256_key(Sign.p256_secret())
  local pem = assert(key.pem)
  assert(pem:find("^%-%-%-%-%-BEGIN EC PRIVATE KEY%-%-%-%-%-\n") ~= nil, pem)
  local read = assert(Acme.read_key(pem))
  assert(Acme.thumbprint(read) == Acme.thumbprint(key) and read.spki == key.spki)
  assert(read.pem == pem)
end

local function test_an_rsa_key_reads_back_from_its_own_pem()
  local key = Acme.rsa_key(rsa_fixture.FIRST)
  local pem = assert(key.pem)
  assert(pem:find("^%-%-%-%-%-BEGIN RSA PRIVATE KEY%-%-%-%-%-\n") ~= nil, pem)
  for line in pem:gmatch("[^\n]+") do assert(#line <= 64, line) end
  local read = assert(Acme.read_key(pem))
  assert(Acme.thumbprint(read) == Acme.thumbprint(key) and read.pem == pem)
end

local function test_openssls_p256_keys_read_as_sec_1_and_as_pkcs_8()
  local sec1, why = Acme.read_key(EC_SEC1)
  assert(sec1 ~= nil, why)
  assert(Acme.thumbprint(sec1) == EC_THUMBPRINT, Acme.thumbprint(sec1))
  local pkcs8, trouble = Acme.read_key(EC_PKCS8)
  assert(pkcs8 ~= nil, trouble)
  assert(Acme.thumbprint(pkcs8) == EC_THUMBPRINT)
  -- What it writes back is the SEC 1 block OpenSSL wrote.
  assert(sec1.pem == EC_SEC1:match("%-%-%-%-%-BEGIN EC PRIVATE KEY.*$"))
end

local function test_openssls_rsa_key_reads_as_pkcs_8()
  local key, why = Acme.read_key("some words first\n" .. RSA_PKCS8)
  assert(key ~= nil, why)
  assert(key.alg == "RS256" and Acme.thumbprint(key) == RSA_THUMBPRINT, Acme.thumbprint(key))
end

local function test_a_key_that_is_none_or_one_not_taken_is_refused()
  local cases: {{string}} = {
    { "", "acme: no private key in the text" },
    { "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n", "acme: no private key in the text" },
    { "-----BEGIN EC PRIVATE KEY-----\nnot base64\n-----END EC PRIVATE KEY-----\n", "is not base64" },
    { "-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n", "no SEC 1 ECPrivateKey" },
    { "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n", "no PKCS #8 PrivateKeyInfo" },
    { "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n", "acme: not an RSA secret" },
    { P384, "acme: an EC key is on P-256, not another curve" },
    { ED25519, "acme: a private key is P-256 or RSA, not another algorithm" },
    { ENCRYPTED, "acme: the key is encrypted" },
    { "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n", "acme: the key is encrypted" },
    { RSA_1024, "acme: an RSA key is from 2048 to 4096 bits" },
  }
  for i, case in ipairs(cases) do
    local text, expected = assert(case[1]), assert(case[2])
    local key, why = Acme.read_key(text)
    assert(key == nil and why:find(expected, 1, true) ~= nil, tostring(i) .. ": " .. why)
  end
end

local function test_a_p256_secret_out_of_range_is_refused()
  -- SEC 1 around a secret of 32 zero bytes, which no key has.
  local zero = "-----BEGIN EC PRIVATE KEY-----\n" ..
    "MDECAQEEIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAoGCCqGSM49AwEH\n" ..
    "-----END EC PRIVATE KEY-----\n"
  local key, why = Acme.read_key(zero)
  assert(key == nil and why:find("acme: not a P-256 secret", 1, true) ~= nil, why)
end

local function test_a_p256_secret_shorter_than_32_bytes_is_read_as_its_value()
  -- SEC 1 asks for 32 bytes, but some writers drop the leading zeros.
  local short = "\1" .. assert(Rand.entropy(30))
  local der = "\x30\x24\x02\x01\x01\x04\x1f" .. short
  local key, why = Acme.read_key("-----BEGIN EC PRIVATE KEY-----\n" .. Codec.base64(der) ..
      "\n-----END EC PRIVATE KEY-----\n")
  assert(key ~= nil, why)
  assert(Acme.thumbprint(key) == Acme.thumbprint(Acme.p256_key("\0" .. short)))
end

local function test_a_key_with_crlf_line_endings_is_read()
  local key, why = Acme.read_key((EC_SEC1:gsub("\n", "\r\n")))
  assert(key ~= nil, why)
  assert(Acme.thumbprint(key) == EC_THUMBPRINT)
end
