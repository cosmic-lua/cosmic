--- WebAuthn (Web Authentication Level 3): passkeys, the relying party's
--- half. A browser makes a key pair on an authenticator (a phone, a
--- laptop's secure enclave, a security key) and proves later that it
--- holds it; the app checks each proof here and keeps the public key.
---
--- A registration has two steps, and so does a login:
---
--- 1. [`Webauthn.creation_options`] (or [`Webauthn.request_options`])
---    makes the JSON a page hands to `navigator.credentials.create` (or
---    `.get`), through `PublicKeyCredential.parseCreationOptionsFromJSON`,
---    around a new challenge from [`Webauthn.challenge`] the app keeps
---    for the request that brings the response.
--- 2. [`Webauthn.verify_registration`] (or
---    [`Webauthn.verify_authentication`]) checks the credential's
---    `toJSON()` the page sends back, against that challenge, the app's
---    origin and its relying party id.
---
---     local challenge = Webauthn.challenge()
---     local options = Webauthn.creation_options({
---       rp_id = "example.com", rp_name = "Example", user_id = user.handle, user_name = "ada",
---     }, challenge)
---     -- ... the page responds with the credential's JSON ...
---     local credential = assert(Webauthn.verify_registration(answer, user.handle, {
---       challenge = challenge, origin = "https://example.com", rp_id = "example.com",
---     }))
---
--- A credential's public key is one of ES256, EdDSA (Ed25519) or RS256.
--- No attestation is asked for, and of what an authenticator sends only
--- `none` and a packed self-attestation are taken: an app here trusts a
--- passkey for what it proves later, not for who made the
--- authenticator. Every function that checks takes the browser's JSON,
--- which is from anyone: what does not check returns nil and a reason,
--- and nothing raises.
---
--- What stays the app's to do, with what it keeps:
---
--- - At registration, refuse a credential id already registered to
---   anyone.
--- - At login, find the credential by [`Webauthn.credential_id`] among
---   those it keeps (the user's, where a user was named first), and
---   refuse an id it does not keep.
--- - Keep each credential's new `sign_count` and `backed_up`.
---
--- A response is taken from the one origin the app names, never from a
--- page in another site's frame (`crossOrigin`), and the extensions an
--- authenticator or browser reports are read past and not used: no
--- extension is asked for.
--- @public

local Cbor = require("cosmic.cbor")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")

local record Webauthn
  --- Whether the user must be verified by the authenticator (a PIN, a
  --- fingerprint), beside being present.
  enum UserVerification
    "required"
    "preferred"
    "discouraged"
  end

  --- Whether the passkey is kept on the authenticator, to be found with
  --- no user named first.
  enum ResidentKey
    "required"
    "preferred"
    "discouraged"
  end

  --- A registered passkey, as an app keeps it: what
  --- [`Webauthn.verify_registration`] returns and
  --- [`Webauthn.verify_authentication`] checks against.
  record Credential
    --- The credential's id, raw bytes: the key it is looked up by.
    id: string
    --- Its public key, as the COSE_Key (RFC 9052) the authenticator sent.
    public_key: string
    --- The COSE algorithm: -7 (ES256), -8 (EdDSA) or -257 (RS256).
    alg: integer
    --- The authenticator's signature counter at the last use; 0 for one
    --- that keeps none, as most passkeys are.
    mut sign_count: integer
    --- The user handle it was made for: [`CreationOptions.user_id`].
    user_handle: string
    --- Whether it may be synced to the user's other devices.
    backup_eligible: boolean
    --- Whether it is, as of its last use.
    mut backed_up: boolean
    --- How the browser says it reaches the authenticator ("internal",
    --- "hybrid", "usb", ...), to hint at in a later request.
    transports: {string}
    --- Whether the user was verified (a PIN, a fingerprint) when it was made.
    user_verified: boolean
    --- The authenticator's model id (AAGUID), 16 bytes; all zeros for
    --- one that does not say.
    aaguid: string
  end

  --- What [`Webauthn.creation_options`] takes.
  record CreationOptions
    --- The relying party id: the app's registrable domain or a host
    --- under it, which the passkey is bound to.
    rp_id: string
    --- The name to show for the app.
    rp_name: string
    --- The user handle: opaque bytes the app chooses for the user, at
    --- most 64, never an email address or a name. A passkey keeps it
    --- and sends it back at login.
    user_id: string
    --- The name the user knows the account by.
    user_name: string
    --- A name to show; `user_name` by default.
    display_name?: string
    --- The user's passkeys already registered, which an authenticator
    --- that holds one declines to make again.
    exclude?: {Credential}
    --- "preferred" by default.
    user_verification?: UserVerification
    --- "required" by default.
    resident_key?: ResidentKey
    --- How long the browser waits, in milliseconds (300000).
    timeout_ms?: integer
  end

  --- What [`Webauthn.request_options`] takes.
  record RequestOptions
    --- The relying party id.
    rp_id: string
    --- The passkeys that may be used; none lets the browser offer any of
    --- the app's it holds (a passkey login with no user named first).
    allow?: {Credential}
    --- "preferred" by default.
    user_verification?: UserVerification
    --- How long the browser waits, in milliseconds (300000).
    timeout_ms?: integer
  end

  --- What a check takes: what the response must be bound to. A check
  --- raises on a `challenge`, `origin` or `rp_id` that is empty, as one
  --- read from a session that has lost it is.
  record Expected
    --- The challenge the options were made with.
    challenge: string
    --- The origin the page is served from, `https://example.com`.
    origin: string
    --- The relying party id the options named.
    rp_id: string
    --- Whether the user must have been verified (false).
    user_verification?: boolean
  end

  --- What [`Webauthn.verify_authentication`] found.
  record Assertion
    --- The credential's new signature counter, to keep.
    sign_count: integer
    --- Whether it is backed up now, to keep.
    backed_up: boolean
    --- Whether the user was verified.
    user_verified: boolean
  end
end

--- The COSE algorithms taken, best first, and the JOSE ones they are.
local ALGS: {integer: Jose.Alg} = { [-8] = "EdDSA", [-7] = "ES256", [-257] = "RS256" }
local ALG_ORDER: {integer} = { -8, -7, -257 }

local TIMEOUT_MS <const> = 300000

--- Flags of authenticator data (WebAuthn section 6.1).
local UP <const> = 0x01
local UV <const> = 0x04
local BE <const> = 0x08
local BS <const> = 0x10
local AT <const> = 0x40
local ED <const> = 0x80

--- The longest credential id WebAuthn allows (section 6.5.1).
local MAX_ID <const> = 1023
--- The longest response taken, in bytes: past any real one, and so the
--- bound on what decoding it may make.
local MAX_ANSWER <const> = 64 * 1024

--- A new challenge: 32 bytes from the system's entropy. Keep it for the
--- request that brings the response (in the session), and use it once.
---
---     local challenge = Webauthn.challenge()
function Webauthn.challenge(): string
  return (assert(Rand.entropy(32)))
end

local function descriptors(list: {Webauthn.Credential}): {Json.Value}
  local out: mut {Json.Value} = {}
  for _, c in ipairs(list) do
    local d: mut {string: Json.Value} = { type = "public-key", id = Codec.base64url(c.id) }
    if #c.transports > 0 then
      local t: mut {Json.Value} = {}
      for i, name in ipairs(c.transports) do t[i] = name end
      d["transports"] = Json.array(t)
    end
    out[#out + 1] = d
  end
  return Json.array(out)
end

--- The JSON of `PublicKeyCredentialCreationOptions` for a registration
--- under `challenge`, with every byte string base64url, as
--- `PublicKeyCredential.parseCreationOptionsFromJSON` takes it. Raises on
--- options that cannot work: an empty `rp_id`, a `user_id` of no bytes or
--- more than 64.
---
---     local options = Webauthn.creation_options({ rp_id = "example.com", rp_name = "Example",
---       user_id = handle, user_name = "ada" }, Webauthn.challenge())
function Webauthn.creation_options(opts: Webauthn.CreationOptions, challenge: string): {string: Json.Value}
  if opts.rp_id == "" then error("webauthn: rp_id must not be empty", 2) end
  if #opts.user_id == 0 or #opts.user_id > 64 then
    error("webauthn: user_id is 1 to 64 bytes", 2)
  end
  local resident = opts.resident_key or "required"
  local params: mut {Json.Value} = {}
  for _, alg in ipairs(ALG_ORDER) do params[#params + 1] = { type = "public-key", alg = alg } end
  return {
    rp = { id = opts.rp_id, name = opts.rp_name },
    user = {
      id = Codec.base64url(opts.user_id), name = opts.user_name, displayName = opts.display_name or opts.user_name,
    },
    challenge = Codec.base64url(challenge),
    pubKeyCredParams = Json.array(params),
    timeout = opts.timeout_ms or TIMEOUT_MS,
    excludeCredentials = descriptors(opts.exclude or {}),
    authenticatorSelection = {
      residentKey = resident,
      requireResidentKey = resident == "required",
      userVerification = opts.user_verification or "preferred",
    },
    attestation = "none",
  }
end

--- The JSON of `PublicKeyCredentialRequestOptions` for a login under
--- `challenge`, as `PublicKeyCredential.parseRequestOptionsFromJSON`
--- takes it. Raises on an empty `rp_id`.
---
---     local options = Webauthn.request_options({ rp_id = "example.com" }, Webauthn.challenge())
function Webauthn.request_options(opts: Webauthn.RequestOptions, challenge: string): {string: Json.Value}
  if opts.rp_id == "" then error("webauthn: rp_id must not be empty", 2) end
  return {
    challenge = Codec.base64url(challenge),
    rpId = opts.rp_id,
    allowCredentials = descriptors(opts.allow or {}),
    userVerification = opts.user_verification or "preferred",
    timeout = opts.timeout_ms or TIMEOUT_MS,
  }
end

--- The member `name` of `object` when it is a string.
local function text(object: {string: Json.Value}, name: string): string?
  local value = object[name]
  if value is string then return value end
  return nil
end

--- The bytes of the base64url member `name` of `object`, or why not.
local function bytes(object: {string: Json.Value}, name: string): string?, string
  local spelled = text(object, name)
  if spelled == nil then return nil, ("webauthn: the answer has no %s"):format(name) end
  local decoded, why = Codec.unbase64url(spelled)
  if decoded == nil then return nil, ("webauthn: the answer's %s: %s"):format(name, why) end
  return decoded, ""
end

--- What a response holds that both checks read.
local record Answer
  id: string
  response: {string: Json.Value}
  client_data: string
end

--- The common members of the credential's JSON `answer`, or why not.
local function answer_of(answer: {string: Json.Value}): Answer?, string
  if text(answer, "type") ~= "public-key" then
    return nil, "webauthn: the answer is not a public key credential"
  end
  local raw, why = bytes(answer, "rawId")
  if raw == nil then return nil, why end
  if #raw == 0 or #raw > MAX_ID then
    return nil, "webauthn: the credential id is 1 to 1023 bytes"
  end
  if text(answer, "id") ~= Codec.base64url(raw) then
    return nil, "webauthn: the answer's id is not its rawId"
  end
  local response_value = answer["response"]
  if response_value == nil then return nil, "webauthn: the answer has no response" end
  local response, _ = Json.to_object(response_value)
  if response == nil then return nil, "webauthn: the answer has no response" end
  local client_data, trouble = bytes(response, "clientDataJSON")
  if client_data == nil then return nil, trouble end
  return { id = raw, response = response, client_data = client_data }, ""
end

--- Whether `client_data` is of `kind`, for the challenge and origin
--- `expected` names (WebAuthn section 7.1 steps 7 to 10), or why not.
local function check_client_data(client_data: string, kind: string, expected: Webauthn.Expected): boolean, string
  -- An empty challenge, as a lost session leaves, would match a
  -- response's empty one.
  if expected.challenge == "" or expected.origin == "" or expected.rp_id == "" then
    error("webauthn: expected.challenge, origin and rp_id must not be empty", 3)
  end
  local data, bad = Json.decode_object(client_data)
  if data == nil then return false, "webauthn: the client data: " .. tostring(bad) end
  if text(data, "type") ~= kind then
    return false, ("webauthn: the client data is not of %s"):format(kind)
  end
  if text(data, "challenge") ~= Codec.base64url(expected.challenge) then
    return false, "webauthn: the answer is not to this challenge"
  end
  if text(data, "origin") ~= expected.origin then
    return false, ("webauthn: the answer is from another origin than %s"):format(expected.origin)
  end
  -- A page framed by another site responds with crossOrigin true. Such a
  -- page is refused for good: no option names the frames to take.
  local cross = data["crossOrigin"]
  if cross ~= nil and cross ~= false then
    return false, "webauthn: the answer is from a page in another site's frame"
  end
  return true, ""
end

--- Authenticator data, read (WebAuthn section 6.1).
local record AuthData
  flags: integer
  sign_count: integer
  --- The attested credential data, when the AT flag is set.
  mut aaguid?: string
  mut credential_id?: string
  mut public_key?: string
  mut cose?: Cbor.Item
end

--- `data`, authenticator data, read and checked against `expected`'s
--- relying party and the flags it requires; or why not.
local function auth_data(data: string, expected: Webauthn.Expected): AuthData?, string
  if #data < 37 then return nil, "webauthn: the authenticator data is short" end
  if data:sub(1, 32) ~= Hash.sha256(expected.rp_id) then
    return nil, "webauthn: the answer is for another relying party than " .. expected.rp_id
  end
  local flags = assert(data:byte(33))
  if flags & UP == 0 then return nil, "webauthn: the user was not present" end
  if expected.user_verification == true and flags & UV == 0 then
    return nil, "webauthn: the user was not verified"
  end
  if flags & BS ~= 0 and flags & BE == 0 then
    return nil, "webauthn: the credential is backed up but cannot be"
  end
  local count = (string.unpack(">I4", data, 34))
  local out: AuthData = { flags = flags, sign_count = count }
  local at = 38
  if flags & AT ~= 0 then
    if #data < at + 17 then return nil, "webauthn: the attested credential data is short" end
    out.aaguid = data:sub(at, at + 15)
    local id_len = (string.unpack(">I2", data, at + 16))
    if id_len == 0 or id_len > MAX_ID then
      return nil, "webauthn: the credential id is 1 to 1023 bytes"
    end
    local id_at = at + 18
    if #data < id_at + id_len then return nil, "webauthn: the attested credential data is short" end
    out.credential_id = data:sub(id_at, id_at + id_len - 1)
    local key_at = id_at + id_len
    local first, why = Cbor.decode_first(data, key_at, { max_depth = 4 })
    if first == nil then return nil, "webauthn: the credential's public key: " .. tostring(why) end
    out.cose = first.item
    out.public_key = data:sub(key_at, first.next - 1)
    at = first.next
  end
  if flags & ED ~= 0 then
    local ext, why = Cbor.decode_first(data, at, { max_depth = 16 })
    if ext == nil then return nil, "webauthn: the extensions: " .. tostring(why) end
    if ext.item.kind ~= "map" then return nil, "webauthn: the extensions are no map" end
    at = ext.next
  end
  if at <= #data then return nil, "webauthn: bytes follow the authenticator data" end
  return out, ""
end

--- The integer at `label` of the COSE key `key`.
local function label_int(key: Cbor.Item, label: integer): integer?
  local v = Cbor.get(key, label)
  if v == nil or v.kind ~= "integer" then return nil end
  return v.integer
end

--- The byte string at `label` of the COSE key `key`.
local function label_bytes(key: Cbor.Item, label: integer): string?
  local v = Cbor.get(key, label)
  if v == nil or v.kind ~= "bytes" then return nil end
  return v.bytes
end

--- A credential's public key, and its COSE algorithm.
local record Public
  key: Jose.Jwk
  alg: integer
end

--- The key the COSE_Key `cose` is (RFC 9053 section 7, RFC 8230), as
--- [`cosmic.jose`] checks with, or why not.
local function cose_key(cose: Cbor.Item): Public?, string
  if cose.kind ~= "map" then return nil, "webauthn: the public key is no COSE key" end
  local kty, alg = label_int(cose, 1), label_int(cose, 3)
  if alg == nil or ALGS[alg] == nil then
    return nil, "webauthn: the public key's algorithm is not taken"
  end
  local jwk: {string: Json.Value}
  if kty == 2 and alg == -7 then
    local x, y = label_bytes(cose, -2), label_bytes(cose, -3)
    if label_int(cose, -1) ~= 1 or x == nil or y == nil then
      return nil, "webauthn: an ES256 key is a point of P-256"
    end
    jwk = { kty = "EC", crv = "P-256", x = Codec.base64url(x), y = Codec.base64url(y) }
  elseif kty == 1 and alg == -8 then
    local x = label_bytes(cose, -2)
    if label_int(cose, -1) ~= 6 or x == nil then
      return nil, "webauthn: an EdDSA key is on Ed25519"
    end
    jwk = { kty = "OKP", crv = "Ed25519", x = Codec.base64url(x) }
  elseif kty == 3 and alg == -257 then
    local n, e = label_bytes(cose, -1), label_bytes(cose, -2)
    if n == nil or e == nil then return nil, "webauthn: an RS256 key has n and e" end
    jwk = { kty = "RSA", n = Codec.base64url(n), e = Codec.base64url(e) }
  else
    return nil, "webauthn: the public key's type is not its algorithm's"
  end
  local key, why = Jose.key(jwk)
  if key == nil then return nil, "webauthn: the public key: " .. tostring(why) end
  return { key = key, alg = alg }, ""
end

--- The 64 bytes R then S of the DER ECDSA signature `der`, or nil.
local function raw_ecdsa(der: string): string?
  if der:byte(1) ~= 0x30 or der:byte(2) ~= #der - 2 then return nil end
  local parts: mut {string} = {}
  local at = 3
  for _ = 1, 2 do
    if der:byte(at) ~= 0x02 then return nil end
    local len = der:byte(at + 1) or 0
    if len == 0 or len > 33 or at + 1 + len > #der then return nil end
    local int = der:sub(at + 2, at + 1 + len)
    -- DER spells each integer in its fewest bytes, positive.
    local first, second = int:byte(1) or 0, int:byte(2) or 0
    if first >= 0x80 or (first == 0 and (len == 1 or second < 0x80)) then return nil end
    int = int:gsub("^\0", "")
    if #int > 32 then return nil end
    parts[#parts + 1] = ("\0"):rep(32 - #int) .. int
    at = at + 2 + len
  end
  if at ~= #der + 1 then return nil end
  return table.concat(parts)
end

--- Whether `signature`, as WebAuthn spells one of `alg` (DER for
--- ES256), is one of `message` under `key`.
local function checks(key: Jose.Jwk, alg: integer, message: string, signature: string): boolean
  if alg == -7 then
    local raw = raw_ecdsa(signature)
    return raw ~= nil and key.public:verify(message, raw)
  end
  return key.public:verify(message, signature)
end

--- The strings of the array member `name` of `object`.
local function strings(object: {string: Json.Value}, name: string): {string}
  local out: mut {string} = {}
  local value = object[name]
  if value == nil then return out end
  local items, _ = Json.to_array(value)
  for _, item in ipairs(items or {}) do
    if item is string then out[#out + 1] = item end
  end
  return out
end

--- The passkey the credential's JSON `answer` (its `toJSON()`, a
--- `RegistrationResponseJSON`) registers for `user_handle`, checked
--- against `expected` as WebAuthn section 7.1 says; nil and why when it
--- does not check.
---
---     local credential = assert(Webauthn.verify_registration(answer, handle, {
---       challenge = challenge, origin = "https://example.com", rp_id = "example.com",
---     }))
function Webauthn.verify_registration(answer: {string: Json.Value}, user_handle: string,
                                      expected: Webauthn.Expected): Webauthn.Credential?, string
  if #user_handle == 0 or #user_handle > 64 then
    error("webauthn: user_handle is 1 to 64 bytes", 2)
  end
  local a, why = answer_of(answer)
  if a == nil then return nil, why end
  local ok, trouble = check_client_data(a.client_data, "webauthn.create", expected)
  if not ok then return nil, trouble end
  local object_bytes, bad = bytes(a.response, "attestationObject")
  if object_bytes == nil then return nil, bad end
  if #object_bytes > MAX_ANSWER then return nil, "webauthn: the attestation object is too long" end
  local object, wrong = Cbor.decode(object_bytes, { max_depth = 8 })
  if object == nil then return nil, "webauthn: the attestation object: " .. tostring(wrong) end
  local fmt, data_item, statement = Cbor.get(object, "fmt"), Cbor.get(object, "authData"), Cbor.get(object, "attStmt")
  if fmt == nil or fmt.kind ~= "text" or data_item == nil or data_item.kind ~= "bytes" or
      statement == nil or statement.kind ~= "map" then
    return nil, "webauthn: the attestation object lacks fmt, authData or attStmt"
  end
  local data_bytes = assert(data_item.bytes)
  local data, refused = auth_data(data_bytes, expected)
  if data == nil then return nil, refused end
  local cose, id, aaguid, public_key = data.cose, data.credential_id, data.aaguid, data.public_key
  if cose == nil or id == nil or aaguid == nil or public_key == nil then
    return nil, "webauthn: the authenticator data holds no credential"
  end
  if id ~= a.id then return nil, "webauthn: the credential id is not the answer's" end
  local public, unusable = cose_key(cose)
  if public == nil then return nil, unusable end
  local key, alg = public.key, public.alg
  if fmt.bytes == "none" then
    if #(statement.entries or {}) ~= 0 then
      return nil, "webauthn: a none attestation has a statement"
    end
  elseif fmt.bytes == "packed" then
    -- Self-attestation (section 8.2): signed by the credential's own key.
    if Cbor.get(statement, "x5c") ~= nil then
      -- TODO: check a packed attestation's x5c chain once cosmic has an
      -- X.509 verifier; today an authenticator that sends one is refused.
      return nil, "webauthn: an attestation with a certificate chain is not taken"
    end
    local sig_alg, sig = Cbor.get(statement, "alg"), Cbor.get(statement, "sig")
    if sig_alg == nil or sig_alg.integer ~= alg or sig == nil or sig.kind ~= "bytes" then
      return nil, "webauthn: the packed attestation is not signed with the credential's algorithm"
    end
    if not checks(key, alg, data_bytes .. Hash.sha256(a.client_data), assert(sig.bytes)) then
      return nil, "webauthn: the packed attestation's signature does not check"
    end
  else
    return nil, ("webauthn: an attestation of format %q is not taken"):format(tostring(fmt.bytes))
  end
  return {
    id = id,
    public_key = public_key,
    alg = alg,
    sign_count = data.sign_count,
    user_handle = user_handle,
    backup_eligible = data.flags & BE ~= 0,
    backed_up = data.flags & BS ~= 0,
    transports = strings(a.response, "transports"),
    user_verified = data.flags & UV ~= 0,
    aaguid = aaguid,
  }, ""
end

--- The credential id the JSON `answer` of a login names, raw bytes, to
--- look the passkey up by; nil and why for one that names none.
---
---     local id = assert(Webauthn.credential_id(answer))
function Webauthn.credential_id(answer: {string: Json.Value}): string?, string
  local a, why = answer_of(answer)
  if a == nil then return nil, why end
  return a.id, ""
end

--- Whether the credential's JSON `answer` of a login (an
--- `AuthenticationResponseJSON`) is a proof by `credential`, checked
--- against `expected` as WebAuthn section 7.2 says: what changed of the
--- credential, to keep, or nil and why. A signature counter that did not
--- move up, where either it or the kept one is not 0, is refused: the
--- authenticator may have been cloned.
---
---     local assertion = assert(Webauthn.verify_authentication(answer, credential, expected))
---     credential.sign_count = assertion.sign_count
function Webauthn.verify_authentication(answer: {string: Json.Value}, credential: Webauthn.Credential,
                                        expected: Webauthn.Expected): Webauthn.Assertion?, string
  local a, why = answer_of(answer)
  if a == nil then return nil, why end
  if a.id ~= credential.id then return nil, "webauthn: the answer is from another credential" end
  local handle = text(a.response, "userHandle")
  if handle ~= nil and handle ~= "" then
    local decoded, _ = Codec.unbase64url(handle)
    if decoded ~= credential.user_handle then
      return nil, "webauthn: the answer is for another user"
    end
  end
  local ok, trouble = check_client_data(a.client_data, "webauthn.get", expected)
  if not ok then return nil, trouble end
  local data_bytes, bad = bytes(a.response, "authenticatorData")
  if data_bytes == nil then return nil, bad end
  if #data_bytes > MAX_ANSWER then return nil, "webauthn: the authenticator data is too long" end
  local data, refused = auth_data(data_bytes, expected)
  if data == nil then return nil, refused end
  if (data.flags & BE ~= 0) ~= credential.backup_eligible then
    return nil, "webauthn: the credential's backup eligibility changed"
  end
  local signature, wrong = bytes(a.response, "signature")
  if signature == nil then return nil, wrong end
  local cose, unreadable = Cbor.decode(credential.public_key, { max_depth = 4 })
  if cose == nil then return nil, "webauthn: the kept public key: " .. tostring(unreadable) end
  local public, unusable = cose_key(cose)
  if public == nil then return nil, unusable end
  local key, alg = public.key, public.alg
  if alg ~= credential.alg then
    return nil, "webauthn: the kept public key is not of the kept algorithm"
  end
  if not checks(key, alg, data_bytes .. Hash.sha256(a.client_data), signature) then
    return nil, "webauthn: the signature does not check"
  end
  local count = data.sign_count
  if (count ~= 0 or credential.sign_count ~= 0) and count <= credential.sign_count then
    return nil, "webauthn: the signature counter did not move up: the authenticator may be cloned"
  end
  return { sign_count = count, backed_up = data.flags & BS ~= 0, user_verified = data.flags & UV ~= 0 }, ""
end

return Webauthn
