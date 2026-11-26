--- JSON Web Keys, signatures and tokens: the keys a server publishes
--- (RFC 7517), the compact signatures made with them (RFC 7515) and the
--- tokens those sign (RFC 7519), as an OpenID Connect provider's ID token
--- is one. Three algorithms are here, each over [`cosmic.key`]: ES256
--- (ECDSA over P-256 with SHA-256), RS256 (RSA PKCS #1 v1.5 with
--- SHA-256) and EdDSA over Ed25519 (RFC 8037).
---
---     local keys = assert(Jose.keys(jwks))
---     local claims = assert(Jose.verify_jwt(token, keys, {
---       issuer = "https://accounts.example.com",
---       audience = "my-client-id",
---     }))
---     print(claims.sub)
---
--- A token is checked before anything in it is believed: its header
--- names the algorithm, and the algorithm must be one the caller allows
--- and the key's own. `none`, a shared-secret HMAC and a header with
--- `crit` members are refused, so a token cannot choose to be checked
--- more weakly than the key's owner signs. Each function that reads a
--- key or a token takes bytes from anyone: what is not a key or a token
--- is refused with a reason, and nothing raises.
---
--- [`Jose.sign`] makes tokens under a [`Key.Secret`] of [`cosmic.key`],
--- and [`Jose.jwk`] spells its public key as a JWK, for a test that
--- stands in for a provider or a client that proves itself with a signed
--- assertion.
--- @public

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Der = require("cosmic.internal.der")
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Key = require("cosmic.key")

local record Jose
  --- A signature algorithm, as RFC 7518 and RFC 8037 name it.
  enum Alg
    --- ECDSA over P-256 with SHA-256.
    "ES256"
    --- RSASSA-PKCS1-v1_5 with SHA-256.
    "RS256"
    --- Ed25519.
    "EdDSA"
  end

  --- A public key that checks signatures, from a JSON Web Key.
  record Jwk
    --- The algorithm the key signs with.
    alg: Alg
    --- The key's id, when its JWK names one.
    kid?: string
    --- The key's `use`, when its JWK names one: "sig" for a signing key.
    use?: string
    --- The key itself, which checks signatures and spells its thumbprint
    --- ([`Key.Public.thumbprint`]).
    public: Key.Public
  end

  --- A compact JWS, decoded: what [`Jose.decode`] and [`Jose.verify`]
  --- return.
  record Jws
    --- The protected header.
    header: {string: Json.Value}
    --- The header's `alg`.
    alg: string
    --- The header's `kid`, when it has one.
    kid?: string
    --- The payload's bytes.
    payload: string
    --- The header and the payload as the token spells them, joined by a
    --- dot: the bytes the signature is over.
    signing_input: string
    --- The signature's bytes.
    signature: string
  end

  --- What [`Jose.verify`] takes.
  record VerifyOptions
    --- The algorithms to take: all three by default.
    algs?: {Alg}
  end

  --- The claims of a token [`Jose.verify_jwt`] has checked.
  record Claims
    --- The issuer.
    iss: string
    --- The subject: who the token is about.
    sub: string
    --- The audiences, from a string or an array of strings.
    aud: {string}
    --- When the token expires, in seconds since the epoch.
    exp?: integer
    --- When it was issued.
    iat?: integer
    --- When it starts to count.
    nbf?: integer
    --- Every claim, as the payload holds it.
    claims: {string: Json.Value}
  end

  --- What [`Jose.verify_jwt`] takes.
  record JwtOptions
    --- The `iss` the token must hold, exactly.
    issuer: string
    --- An audience `aud` must hold.
    audience: string
    --- The algorithms to take: all three by default.
    algs?: {Alg}
    --- The time in seconds since the epoch: the clock's by default.
    now?: integer
    --- How far the issuer's clock may be from this one, in seconds (60).
    leeway?: integer
    --- Whether the token must hold `exp` (true).
    require_exp?: boolean
    --- The header's `typ` the token must have, compared without regard
    --- to case and to an `application/` prefix, as RFC 7515 says; nil
    --- takes any.
    typ?: string
  end
end

-- TODO: take PS256 once cosmic.key verifies RSASSA-PSS, which some
-- providers sign ID tokens with when asked.

--- The algorithm of [`cosmic.key`] of a key of the JOSE algorithm `alg`.
local function key_alg(alg: Jose.Alg): Key.Alg
  return if alg == "ES256" then "p256" elseif alg == "RS256" then "rsa" else "ed25519" end
end

--- The algorithms taken where the caller names none.
local ALL: {Jose.Alg} = { "ES256", "RS256", "EdDSA" }

--- The longest token taken, in bytes: far past any ID token, and short
--- enough that a token sent to waste time is refused before it is read.
local MAX_TOKEN <const> = 64 * 1024

--- The member `name` of `object` when it is a string.
local function text(object: {string: Json.Value}, name: string): string?
  local value = object[name]
  if value is string then return value end
  return nil
end

--- The bytes the base64url member `name` of `jwk` spells, or why not.
local function bytes(jwk: {string: Json.Value}, name: string): string?, string
  local spelled = text(jwk, name)
  if spelled == nil then return nil, ("jose: the key has no %s"):format(name) end
  local decoded, why = Codec.unbase64url(spelled)
  if decoded == nil then return nil, ("jose: the key's %s: %s"):format(name, why) end
  return decoded, ""
end

--- Whether `name` is an algorithm this module knows.
local function known(name: string): boolean
  return name == "ES256" or name == "RS256" or name == "EdDSA"
end

-- Jose.key, its failure in words.
local function key_text(jwk: {string: Json.Value}): Jose.Jwk?, string
  local kty = text(jwk, "kty")
  if kty == nil then return nil, "jose: the key has no kty" end
  if jwk["d"] ~= nil then return nil, "jose: the key is a private key" end
  local alg: Jose.Alg
  local public: string
  if kty == "EC" then
    if text(jwk, "crv") ~= "P-256" then return nil, "jose: an EC key must be on P-256" end
    local x, why = bytes(jwk, "x")
    if x == nil then return nil, why end
    local y, trouble = bytes(jwk, "y")
    if y == nil then return nil, trouble end
    if #x ~= 32 or #y ~= 32 then return nil, "jose: a P-256 key's x and y are 32 bytes each" end
    alg, public = "ES256", "\4" .. x .. y
  elseif kty == "RSA" then
    local n, why = bytes(jwk, "n")
    if n == nil then return nil, why end
    local e, trouble = bytes(jwk, "e")
    if e == nil then return nil, trouble end
    -- RFC 7518 section 6.3.1 spells each integer with no leading zero,
    -- which a thumbprint depends on.
    if n:byte(1) == 0 or e:byte(1) == 0 then
      return nil, "jose: the RSA key's n or e has a leading zero"
    end
    if #n < 256 or #n > 512 then return nil, "jose: an RSA key is from 2048 to 4096 bits" end
    if (n:byte(#n) or 0) & 1 == 0 then return nil, "jose: the RSA key's modulus is even" end
    local last = e:byte(#e) or 0
    if #e > 8 or (#e == 1 and last < 3) or last & 1 == 0 then
      return nil, "jose: the RSA key's exponent is out of range"
    end
    alg, public = "RS256", Der.sequence(Der.unsigned(n), Der.unsigned(e))
  elseif kty == "OKP" then
    if text(jwk, "crv") ~= "Ed25519" then return nil, "jose: an OKP key must be on Ed25519" end
    local x, why = bytes(jwk, "x")
    if x == nil then return nil, why end
    if #x ~= 32 then return nil, "jose: an Ed25519 key is 32 bytes" end
    alg, public = "EdDSA", x
  else
    return nil, ("jose: a key of type %q is not taken"):format(kty)
  end
  for _, name in ipairs({ "alg", "kid", "use" }) do
    if jwk[name] ~= nil and text(jwk, name) == nil then
      return nil, ("jose: the key's %s is no string"):format(name)
    end
  end
  local named = text(jwk, "alg")
  if named ~= nil and named ~= alg then
    return nil, ("jose: a %s key cannot sign with %s"):format(kty, named)
  end
  -- The checks above are those Key.public makes, so it takes the bytes.
  local key = assert(Key.public(key_alg(alg), public))
  return { alg = alg, kid = text(jwk, "kid"), use = text(jwk, "use"), public = key }, ""
end

--- The key `jwk` holds, a JSON Web Key's members: an EC key on P-256, an
--- RSA key of 2048 to 4096 bits or an OKP key on Ed25519. Nil and why for
--- any other, for a key whose `alg` is not the one its type signs with,
--- for a private key (one with `d`), which has no place where a public
--- key is asked for, and for an `alg`, `kid` or `use` that is no string.
---
--- A key is believed as its publisher's: an RSA exponent and an Ed25519
--- point are checked for form, not strength, so a key set is fetched
--- only from a provider the app trusts, over https.
---
---     local key = assert(Jose.key(Json.decode_object(text)))
function Jose.key(jwk: {string: Json.Value}): (Jose.Jwk) | (nil, Failure)
  local value, why = key_text(jwk)
  if value == nil then return nil, Failure.new(why) end
  return value
end

-- Jose.keys, its failure in words.
local function keys_text(set: {string: Json.Value}): {Jose.Jwk}?, string
  local listed = set["keys"]
  if listed == nil then return nil, "jose: the key set has no keys" end
  local items, why = Json.to_array(listed)
  if items == nil then return nil, "jose: the key set's keys: " .. tostring(why) end
  local out: mut {Jose.Jwk} = {}
  for _, item in ipairs(items) do
    local object, _ = Json.to_object(item)
    if object ~= nil then
      local key, _ = Jose.key(object)
      if key ~= nil and (key.use == nil or key.use == "sig") then out[#out + 1] = key end
    end
  end
  return out, ""
end

--- The signing keys of the JWK Set `set` (an object with `keys`, as a
--- provider's `jwks_uri` serves it). A key this module does not take, or
--- one whose `use` is not "sig", is left out, since a provider may
--- publish keys of other kinds beside its signing keys. Nil and why when
--- `set` holds no `keys` array.
---
---     local keys = assert(Jose.keys(assert(Json.decode_object(body))))
function Jose.keys(set: {string: Json.Value}): ({Jose.Jwk}) | (nil, Failure)
  local value, why = keys_text(set)
  if value == nil then return nil, Failure.new(why) end
  return value
end

-- Jose.decode, its failure in words.
local function decode_text(token: string): Jose.Jws?, string
  if #token > MAX_TOKEN then return nil, "jose: the token is too long" end
  local head, body, tail = token:match("^([%w_%-]*)%.([%w_%-]*)%.([%w_%-]*)$")
  if head == nil or body == nil or tail == nil then
    return nil, "jose: a token is three base64url parts apart by dots"
  end
  local header_text, why = Codec.unbase64url(head)
  if header_text == nil then return nil, "jose: the token's header: " .. tostring(why) end
  local header, bad = Json.decode_object(header_text)
  if header == nil then return nil, "jose: the token's header: " .. tostring(bad) end
  local alg = text(header, "alg")
  if alg == nil then return nil, "jose: the token's header names no alg" end
  if header["kid"] ~= nil and text(header, "kid") == nil then
    return nil, "jose: the token's kid is no string"
  end
  local payload, trouble = Codec.unbase64url(body)
  if payload == nil then return nil, "jose: the token's payload: " .. tostring(trouble) end
  local signature, wrong = Codec.unbase64url(tail)
  if signature == nil then return nil, "jose: the token's signature: " .. tostring(wrong) end
  return {
    header = header,
    alg = alg,
    kid = text(header, "kid"),
    payload = payload,
    signing_input = head .. "." .. body,
    signature = signature,
  }, ""
end

--- The compact JWS `token`, decoded and not checked: nothing in it is
--- yet to be believed. Nil and why for text that is not three base64url
--- parts apart by dots, whose header is no JSON object or names no `alg`.
function Jose.decode(token: string): (Jose.Jws) | (nil, Failure)
  local value, why = decode_text(token)
  if value == nil then return nil, Failure.new(why) end
  return value
end

--- Whether `signature` is one of `message` under `key`.
local function checks(key: Jose.Jwk, message: string, signature: string): boolean
  return key.public:verify(message, signature)
end

-- Jose.verify, its failure in words.
local function verify_text(token: string, keys: {Jose.Jwk}, opts?: Jose.VerifyOptions): Jose.Jws?, string
  local jws, why = decode_text(token)
  if jws == nil then return nil, why end
  local allowed = (opts or {}).algs or ALL
  local alg = jws.alg
  local taken = false
  for _, name in ipairs(allowed) do
    if name == alg then taken = true end
  end
  if not taken or not known(alg) then
    return nil, ("jose: the algorithm %q is not allowed"):format(alg)
  end
  -- No extension is understood, so one a token says must be is refused
  -- (RFC 7515 section 4.1.11).
  if jws.header["crit"] ~= nil then
    return nil, "jose: the token has crit members, which are not understood"
  end
  local kid = jws.kid
  local tried = 0
  for _, key in ipairs(keys) do
    if key.alg == alg and (kid == nil or key.kid == kid) then
      tried = tried + 1
      if checks(key, jws.signing_input, jws.signature) then return jws, "" end
    end
  end
  if tried == 0 then
    if kid ~= nil then return nil, ("jose: no %s key has the id %q"):format(alg, kid) end
    return nil, ("jose: no key signs with %s"):format(alg)
  end
  return nil, "jose: the signature does not check"
end

--- The token `token`, decoded, when one of `keys` signed it with an
--- algorithm of `opts.algs`. Where the header names a `kid`, only the
--- keys of that id are tried; where it names none, every key of its
--- algorithm is. Nil and why otherwise: a token that does not decode,
--- whose algorithm is not allowed (`none` and the HMAC ones never are),
--- whose header has `crit` members, or that no key checks. An ES256
--- token has two spellings that verify, its signature's S and n - S
--- ([`cosmic.key`]'s P-256 verify), so a list of tokens used or revoked is kept
--- by a claim (`jti`, or `sub` and `iat`), never by the token's text.
---
---     local jws = assert(Jose.verify(token, keys, { algs = { "ES256" } }))
function Jose.verify(token: string, keys: {Jose.Jwk}, opts?: Jose.VerifyOptions): (Jose.Jws) | (nil, Failure)
  local value, why = verify_text(token, keys, opts)
  if value == nil then return nil, Failure.new(why) end
  return value
end

--- A NumericDate claim `name` of `claims` as whole seconds; nil where it
--- is absent, false where it is no number.
local function date(claims: {string: Json.Value}, name: string): (integer | boolean)?
  local value = claims[name]
  if value == nil then return nil end
  if value is number then
    if value ~= value or value == math.huge or value == -math.huge then return false end
    local whole = math.tointeger(math.floor(value))
    if whole == nil then return false end
    return whole
  end
  return false
end

--- Whether the media type `got` is `want`, as RFC 7515 section 4.1.9
--- compares a `typ`.
local function same_type(got: string, want: string): boolean
  local function bare(t: string): string
    local lower = t:lower()
    return (lower:gsub("^application/", ""))
  end
  return bare(got) == bare(want)
end

-- Jose.verify_jwt, its failure in words.
local function verify_jwt_text(token: string, keys: {Jose.Jwk}, opts: Jose.JwtOptions): Jose.Claims?, string
  local jws, why = verify_text(token, keys, { algs = opts.algs })
  if jws == nil then return nil, why end
  local want_typ = opts.typ
  if want_typ ~= nil then
    local typ = text(jws.header, "typ")
    if typ == nil or not same_type(typ, want_typ) then
      return nil, ("jose: the token's typ is not %s"):format(want_typ)
    end
  end
  local claims, bad = Json.decode_object(jws.payload)
  if claims == nil then return nil, "jose: the token's payload: " .. tostring(bad) end
  local iss = text(claims, "iss")
  if iss ~= opts.issuer then return nil, "jose: the token's issuer is not " .. opts.issuer end
  local aud: mut {string} = {}
  local said = claims["aud"]
  if said is string then
    aud[1] = said
  elseif said ~= nil then
    local items, _ = Json.to_array(said)
    for _, item in ipairs(items or {}) do
      if not item is string then
        return nil, "jose: the token's aud holds a value that is no string"
      end
      aud[#aud + 1] = item
    end
  end
  local for_us = false
  for _, a in ipairs(aud) do
    if a == opts.audience then for_us = true end
  end
  if not for_us then return nil, "jose: the token is not for the audience " .. opts.audience end
  local sub = claims["sub"]
  if not sub is string or sub == "" then return nil, "jose: the token names no sub" end
  local now = opts.now or Clock.now_ns() // 1000000000
  local leeway = opts.leeway or 60
  local exp, nbf, iat = date(claims, "exp"), date(claims, "nbf"), date(claims, "iat")
  if exp == false or nbf == false or iat == false then
    return nil, "jose: a date claim of the token is no number"
  end
  if exp is integer then
    if now >= exp + leeway then return nil, "jose: the token has expired" end
  elseif opts.require_exp ~= false then
    return nil, "jose: the token has no exp"
  end
  if nbf is integer and now < nbf - leeway then return nil, "jose: the token is not valid yet" end
  if iat is integer and now < iat - leeway then
    return nil, "jose: the token is issued in the future"
  end
  return {
    iss = assert(iss),
    sub = sub,
    aud = aud,
    exp = if exp is integer then exp else nil end,
    iat = if iat is integer then iat else nil end,
    nbf = if nbf is integer then nbf else nil end,
    claims = claims,
  }, ""
end

--- The claims of the JWT `token`, when one of `keys` signed it as
--- [`Jose.verify`] checks, `iss` is `opts.issuer`, `aud` holds
--- `opts.audience`, and the time is within its `nbf` and `exp` and not
--- before its `iat`, give or take `opts.leeway`. Nil and why otherwise,
--- including for a header whose `typ` is not `opts.typ`, a payload that
--- is no JSON object, a `sub` that is absent, empty or no string, a
--- date claim that is no number, and no `exp` unless `opts.require_exp`
--- is false.
---
---     local claims = assert(Jose.verify_jwt(token, keys, {
---       issuer = "https://accounts.example.com", audience = "my-client-id",
---     }))
function Jose.verify_jwt(token: string, keys: {Jose.Jwk}, opts: Jose.JwtOptions): (Jose.Claims) | (nil, Failure)
  local value, why = verify_jwt_text(token, keys, opts)
  if value == nil then return nil, Failure.new(why) end
  return value
end

--- The JOSE algorithm of a key of [`cosmic.key`]'s algorithm `alg`.
local function jose_alg(alg: Key.Alg): Jose.Alg
  if alg == "x25519" then error("jose: an X25519 key signs nothing", 3) end
  return if alg == "p256" then "ES256" elseif alg == "rsa" then "RS256" else "EdDSA" end
end

--- The JSON Web Key of `key`, as a provider publishes it in a key set:
--- [`Key.Public.jwk`]'s members, with `alg`, `use` of "sig" and, when
--- given, `kid`. [`Jose.key`] reads it back. Raises on an X25519 key.
---
---     local key = Key.generate("p256")
---     local set = { keys = Json.array({ Jose.jwk(key.public, "2026-11") }) }
function Jose.jwk(key: Key.Public, kid?: string): {string: Json.Value}
  local jwk: mut {string: Json.Value} = {}
  for name, value in pairs(key:jwk()) do jwk[name] = value end
  jwk["alg"] = jose_alg(key.alg)
  jwk["use"] = "sig"
  if kid ~= nil then jwk["kid"] = kid end
  return jwk
end

--- The compact JWS of `payload` under `key`, with a header of the key's
--- `alg` (ES256, RS256 or EdDSA) and the members of `header` (`kid` and
--- `typ`, say). Raises on an X25519 key, and on a payload or a header
--- that is not JSON.
---
---     local key = Key.generate("p256")
---     local token = Jose.sign(key, { iss = "https://example.com", sub = "ada" }, { kid = "2026-11" })
function Jose.sign(key: Key.Secret, payload: {string: Json.Value}, header?: {string: Json.Value}): string
  local head: mut {string: Json.Value} = {}
  for name, value in pairs(header or {}) do head[name] = value end
  head["alg"] = jose_alg(key.alg)
  local input = Codec.base64url((assert(Json.encode(head)))) .. "." .. Codec.base64url((assert(Json.encode(payload))))
  return input .. "." .. Codec.base64url(key:sign(input))
end

return Jose
