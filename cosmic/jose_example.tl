--- Worked examples for [`cosmic.jose`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Clock = require("cosmic.clock")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Key = require("cosmic.key")

local record Example
end

--- Reading a key out of a provider's key set: the one key here is RFC
--- 7515's ES256 example.
function Example.keys()
  local set = assert(Json.decode_object([[
    {"keys": [{"kty": "EC", "crv": "P-256", "use": "sig", "kid": "a",
               "x": "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
               "y": "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"}]}
  ]]))
  local keys = assert(Jose.keys(set))
  local key = assert(keys[1])
  print(#keys, key.alg, key.kid)
  assert(#keys == 1 and key.alg == "ES256")
end

--- One key, from its JWK, and its RFC 7638 thumbprint.
function Example.key()
  local key = assert(Jose.key({
    kty = "OKP", crv = "Ed25519", x = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
  }))
  print(key.alg, key.public:thumbprint())
  assert(key.alg == "EdDSA")
end

--- A token signed and checked: a provider's half and a client's.
function Example.verify_jwt()
  local provider = Key.generate("p256")
  local token = Jose.sign(provider, {
    iss = "https://id.example.com", sub = "ada", aud = "my-app", exp = Clock.now_ns() // 1000000000 + 300,
  }, { typ = "JWT", kid = "2026-11" })
  local keys = assert(Jose.keys({ keys = Json.array({ Jose.jwk(provider.public, "2026-11") }) }))
  local claims = assert(Jose.verify_jwt(token, keys, {
    issuer = "https://id.example.com", audience = "my-app",
  }))
  print(claims.sub)
  assert(claims.sub == "ada")
  local refused, why = Jose.verify_jwt(token, keys, { issuer = "https://id.example.com", audience = "other" })
  assert(refused == nil and tostring(why) ~= "")
end

--- A signature over bytes that are not JSON, checked, then decoded
--- without a check to see what the header says.
function Example.verify()
  local signer = Key.generate("ed25519")
  local token = Jose.sign(signer, { hello = "world" })
  local jws = assert(Jose.verify(token, { assert(Jose.key(Jose.jwk(signer.public))) }, { algs = { "EdDSA" } }))
  print(jws.alg, jws.payload)
  assert(assert(Jose.decode(token)).alg == "EdDSA")
end

return Example
