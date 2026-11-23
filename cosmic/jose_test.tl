--- Proves [`cosmic.jose`] against the examples of RFC 7515, RFC 8037 and
--- RFC 7638, and that a token is refused for each thing that makes it
--- not one to believe: an algorithm the caller or the key does not take,
--- a changed byte, a wrong issuer, audience or time.

local Codec = require("cosmic.codec")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")
local Sign = require("cosmic.sign")

--- RFC 7515 appendix A.3's ES256 key and token.
local ES_X <const> = "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU"
local ES_Y <const> = "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
local ES256_JWK: {string: Json.Value} = { kty = "EC", crv = "P-256", x = ES_X, y = ES_Y }
local ES256_TOKEN = "eyJhbGciOiJFUzI1NiJ9" ..
  ".eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ" ..
  ".DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q"

--- RFC 8037 appendix A.4's Ed25519 key and signature.
local ED_X <const> = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
local ED25519_JWK: {string: Json.Value} = { kty = "OKP", crv = "Ed25519", x = ED_X }
local ED25519_TOKEN = "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc" ..
  ".hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg"

--- RFC 7638 section 3.1's RSA key and its thumbprint.
local RSA_N <const> = "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4" ..
  "n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgd" ..
  "AZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-k" ..
  "EgU8awapJzKnqDKgw"
local RSA_JWK: {string: Json.Value} = {
  kty = "RSA",
  n = RSA_N,
  e = "AQAB",
  alg = "RS256",
  kid = "2011-04-29",
}

local function test_es256_example_verifies()
  local key = assert(Jose.key(ES256_JWK))
  assert(key.alg == "ES256" and #key.public == 65)
  local jws = assert(Jose.verify(ES256_TOKEN, { key }))
  assert(jws.alg == "ES256")
  assert(jws.payload:find('"iss":"joe"', 1, true) ~= nil)
end

local function test_ed25519_example_verifies()
  local key = assert(Jose.key(ED25519_JWK))
  local jws = assert(Jose.verify(ED25519_TOKEN, { key }))
  assert(jws.payload == "Example of Ed25519 signing")
end

local function test_thumbprint_examples()
  local key = assert(Jose.key(RSA_JWK))
  assert(key.kid == "2011-04-29")
  assert(Jose.thumbprint(key) == "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs")
  -- RFC 8037 appendix A.3.
  assert(Jose.thumbprint((assert(Jose.key(ED25519_JWK)))) == "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k")
end

local function test_a_changed_byte_is_refused()
  local key = assert(Jose.key(ES256_JWK))
  local head, body, tail = ES256_TOKEN:match("^([^.]*)%.([^.]*)%.([^.]*)$")
  local payload = assert(Codec.unbase64url(assert(body)))
  local changed = Codec.base64url((payload:gsub("joe", "jim")))
  local jws, why = Jose.verify(assert(head) .. "." .. changed .. "." .. assert(tail), { key })
  assert(jws == nil and tostring(why):find("does not check", 1, true) ~= nil, why)
end

--- A token whose header says `alg`, with `payload` and no signature
--- that checks.
local function forged(header: {string: Json.Value}, payload: string): string
  return Codec.base64url((assert(Json.encode(header)))) .. "." .. Codec.base64url(payload) .. "."
end

local function test_none_and_hmac_are_refused()
  local key = assert(Jose.key(ES256_JWK))
  for _, alg in ipairs({ "none", "None", "NONE", "HS256", "none " }) do
    local jws, why = Jose.verify(forged({ alg = alg }, "{}"), { key })
    assert(jws == nil and tostring(why):find("not allowed", 1, true) ~= nil, why)
  end
  local jws, why = Jose.verify(forged({ alg = "ES256", kid = 7 }, "{}"), { key })
  assert(jws == nil and tostring(why):find("kid", 1, true) ~= nil, why)
end

local function test_an_algorithm_the_caller_does_not_allow_is_refused()
  local key = assert(Jose.key(ES256_JWK))
  local jws, why = Jose.verify(ES256_TOKEN, { key }, { algs = { "RS256" } })
  assert(jws == nil and tostring(why):find("not allowed", 1, true) ~= nil, why)
end

--- A token signed with one algorithm is not checked against a key of
--- another, though the caller allows both: the key's type fixes its
--- algorithm.
local function test_a_key_checks_only_its_own_algorithm()
  local seed = assert(Rand.entropy(32))
  local ed = Jose.signer("EdDSA", seed)
  local es = Jose.signer("ES256", Sign.p256_secret())
  local token = Jose.sign(ed, { sub = "ada" })
  local jws, why = Jose.verify(token, { es.key })
  assert(jws == nil and tostring(why):find("no key signs with EdDSA", 1, true) ~= nil, why)
  assert(Jose.verify(token, { es.key, ed.key }))
end

local function test_crit_is_refused()
  local signer = Jose.signer("ES256", Sign.p256_secret())
  local token = Jose.sign(signer, { sub = "ada" }, { crit = Json.array({ "exp" }), exp = 1 })
  local jws, why = Jose.verify(token, { signer.key })
  assert(jws == nil and tostring(why):find("crit", 1, true) ~= nil, why)
end

local function test_kid_picks_the_key()
  local one = Jose.signer("ES256", Sign.p256_secret(), "one")
  local two = Jose.signer("ES256", Sign.p256_secret(), "two")
  local token = Jose.sign(two, { sub = "ada" })
  assert(Jose.verify(token, { one.key, two.key }))
  local jws, why = Jose.verify(token, { one.key })
  assert(jws == nil and tostring(why):find('id "two"', 1, true) ~= nil, why)
end

local function test_rs256_signs_and_verifies()
  local signer = Jose.signer("RS256", Sign.rsa_secret(), "r")
  local token = Jose.sign(signer, { sub = "ada" })
  local key = assert(Jose.key(signer.jwk))
  assert(key.alg == "RS256")
  assert(Jose.verify(token, { key }))
  assert(Jose.thumbprint(key) == Jose.thumbprint(signer.key))
end

local function test_keys_refused_by_jwk()
  local function refused(jwk: {string: Json.Value}, says: string)
    local key, why = Jose.key(jwk)
    assert(key == nil and tostring(why):find(says, 1, true) ~= nil, why)
  end
  refused({ kty = "EC", crv = "P-384", x = "AA", y = "AA" }, "P-256")
  refused({ kty = "EC", crv = "P-256", x = "AA", y = "AA" }, "32 bytes")
  refused({ kty = "EC", crv = "P-256", x = ES_X, y = ES_Y, d = "AA" }, "private")
  refused({ kty = "EC", crv = "P-256", x = ES_X, y = ES_Y, alg = "RS256" }, "cannot sign")
  refused({ kty = "RSA", n = "AQAB", e = "AQAB" }, "2048")
  local n = RSA_N
  local modulus = assert(Codec.unbase64url(n))
  refused({ kty = "RSA", n = Codec.base64url("\0" .. modulus), e = "AQAB" }, "leading zero")
  refused({ kty = "RSA", n = Codec.base64url(modulus:sub(1, -2) .. "\2"), e = "AQAB" }, "even")
  for _, e in ipairs({ "AQ", "Ag", "AAE", "AQAA" }) do
    refused({ kty = "RSA", n = n, e = e }, "")
  end
  refused({ kty = "EC", crv = "P-256", x = ES_X, y = ES_Y, kid = 7 }, "kid")
  refused({ kty = "EC", crv = "P-256", x = ES_X, y = ES_Y, use = true }, "use")
  refused({ kty = "EC", crv = "P-256", x = ES_X, y = ES_Y, alg = 5 }, "alg")
  refused({ kty = "oct", k = "AA" }, "not taken")
  refused({ kty = "OKP", crv = "X25519", x = ED_X }, "Ed25519")
  refused({ kty = "OKP", crv = "Ed25519", x = "AA==" }, "base64url")
end

local function test_keys_leaves_out_what_does_not_sign()
  local set: {string: Json.Value} = {
    keys = Json.array({
      ES256_JWK,
      { kty = "oct", k = "AA" },
      { kty = "OKP", crv = "Ed25519", x = ED_X, use = "enc" },
      "not a key",
    }),
  }
  local keys = assert(Jose.keys(set))
  assert(#keys == 1 and keys[1].alg == "ES256")
  local none, why = Jose.keys({ nothing = true })
  assert(none == nil and tostring(why):find("no keys", 1, true) ~= nil, why)
end

local function test_decode_refuses_what_is_no_token()
  for _, text in ipairs({ "", "a.b", "a.b.c.d", "!!.e30.", "e30.e30.", "W10.e30.", ("a"):rep(70000) .. ".e30." }) do
    local jws, why = Jose.decode(text)
    assert(jws == nil and tostring(why) ~= "", text)
  end
end

--- A provider's signer, and a token of its claims less `drop` with
--- `with` laid over.
local signer = Jose.signer("ES256", Sign.p256_secret(), "k")
local NOW <const> = 1700000000
local function token(with: {string: Json.Value}, drop?: string): string
  local claims: mut {string: Json.Value} = {
    iss = "https://id.example.com",
    sub = "ada",
    aud = "client",
    exp = NOW + 300,
    iat = NOW,
  }
  for name, value in pairs(with) do claims[name] = value end
  if drop ~= nil then claims[drop] = nil end
  return Jose.sign(signer, claims)
end
local OPTS: Jose.JwtOptions = { issuer = "https://id.example.com", audience = "client", now = NOW }

local function test_verify_jwt_takes_a_good_token()
  local claims = assert(Jose.verify_jwt(token({}), { signer.key }, OPTS))
  assert(claims.sub == "ada" and claims.aud[1] == "client" and claims.exp == NOW + 300 and claims.iat == NOW)
  local many = assert(Jose.verify_jwt(token({ aud = Json.array({ "other", "client" }) }), { signer.key }, OPTS))
  assert(#many.aud == 2)
  assert(Jose.verify_jwt(token({ exp = NOW + 0.5 }), { signer.key }, OPTS))
end

local function test_verify_jwt_refuses()
  local function refused(t: string, says: string, opts?: Jose.JwtOptions)
    local claims, why = Jose.verify_jwt(t, { signer.key }, opts or OPTS)
    assert(claims == nil and tostring(why):find(says, 1, true) ~= nil, why)
  end
  refused(token({ iss = "https://evil.example.com" }), "issuer")
  refused(token({}, "iss"), "issuer")
  refused(token({ aud = "other" }), "audience")
  refused(token({}, "aud"), "audience")
  refused(token({ aud = Json.array({ "client", 7 }) }), "no string")
  refused(token({ exp = NOW - 61 }), "expired")
  refused(token({ exp = NOW - 1 }), "expired", { issuer = OPTS.issuer, audience = "client", now = NOW, leeway = 0 })
  refused(token({}, "exp"), "no exp")
  refused(token({ exp = "soon" }), "no number")
  refused(token({ nbf = NOW + 61 }), "not valid yet")
  refused(token({ iat = NOW + 61 }), "issued in the future")
  refused(token({ iat = NOW + 1 }), "issued in the future",
    { issuer = OPTS.issuer, audience = "client", now = NOW, leeway = 0 })
  refused(token({ sub = 7 }), "no sub")
  refused(token({}, "sub"), "no sub")
  refused(token({ sub = "" }), "no sub")
  refused(token({ exp = NOW }), "expired", { issuer = OPTS.issuer, audience = "client", now = NOW, leeway = 0 })
  refused(token({ nbf = NOW + 1 }), "not valid yet", { issuer = OPTS.issuer, audience = "client", now = NOW, leeway = 0 })
  refused(Jose.sign(signer, { iss = "x" }, { typ = "JWT" }), "typ",
    { issuer = "x", audience = "client", now = NOW, typ = "at+jwt" })
end

--- A token is taken within the leeway of its times, either side.
local function test_verify_jwt_takes_the_leeway()
  assert(Jose.verify_jwt(token({ exp = NOW - 30 }), { signer.key }, OPTS))
  assert(Jose.verify_jwt(token({ nbf = NOW + 30 }), { signer.key }, OPTS))
  assert(Jose.verify_jwt(token({ iat = NOW + 30 }), { signer.key }, OPTS))
  assert(Jose.verify_jwt(token({ exp = NOW + 1 }), { signer.key },
    { issuer = OPTS.issuer, audience = "client", now = NOW, leeway = 0 }))
end

--- A token past 64 KiB is refused before it is read, though it is
--- signed and its claims hold.
local function test_a_long_token_is_refused()
  local long = token({ pad = ("x"):rep(64 * 1024) })
  local claims, why = Jose.verify_jwt(long, { signer.key }, OPTS)
  assert(claims == nil and tostring(why):find("too long", 1, true) ~= nil, why)
end

local function test_verify_jwt_compares_typ_loosely()
  local t = Jose.sign(signer, { iss = "x", sub = "s", aud = "c", exp = NOW + 10 }, { typ = "application/AT+JWT" })
  assert(Jose.verify_jwt(t, { signer.key }, { issuer = "x", audience = "c", now = NOW, typ = "at+jwt" }))
end

local function test_verify_jwt_without_exp_when_asked()
  assert(Jose.verify_jwt(token({}, "exp"), { signer.key },
    { issuer = OPTS.issuer, audience = "client", now = NOW, require_exp = false }))
end
