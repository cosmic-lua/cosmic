--- Proves [`cosmic.webauthn`] against a stand-in authenticator: a passkey
--- of each algorithm registers and logs in, and each answer that is not
--- bound to this challenge, origin, relying party, user and key is
--- refused.

local Cbor = require("cosmic.cbor")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")
-- The raw signing operations on bytes, which the fixtures build keys of.
local Sign = require("cosmic.internal.sign")
local Test = require("cosmic.test")
local Webauthn = require("cosmic.webauthn")

local RP <const> = "example.com"
local ORIGIN <const> = "https://example.com"
local HANDLE <const> = "user-handle-1"

--- A stand-in authenticator's passkey.
local record Key
  alg: integer
  secret: string
  mut id: string
  mut count: integer
end

--- DER INTEGER of the unsigned big-endian `b`.
local function der_int(b: string): string
  local trimmed = b:gsub("^\0+", "")
  if trimmed == "" then trimmed = "\0" end
  if (trimmed:byte(1) or 0) >= 0x80 then trimmed = "\0" .. trimmed end
  return "\2" .. string.char(#trimmed) .. trimmed
end

--- The DER SEQUENCE WebAuthn spells an ES256 signature R then S as.
local function der_signature(raw: string): string
  local body = der_int(raw:sub(1, 32)) .. der_int(raw:sub(33, 64))
  return "\x30" .. string.char(#body) .. body
end

local function key_new(alg: integer): Key
  local secret: string
  if alg == -7 then
    secret = Sign.p256_secret()
  elseif alg == -8 then
    secret = assert(Rand.entropy(32))
  else
    secret = Sign.rsa_secret()
  end
  return { alg = alg, secret = secret, id = assert(Rand.entropy(16)), count = 0 }
end

--- The DER INTEGERs of an RSAPublicKey, n and e.
local function rsa_parts(der: string): string, string
  local at = if (der:byte(2) or 0) >= 0x80 then 3 + ((der:byte(2) or 0) & 0x7f) else 3 end
  local values: mut {string} = {}
  for _ = 1, 2 do
    local len = der:byte(at + 1) or 0
    local start = at + 2
    if len >= 0x80 then
      local count = len & 0x7f
      len = 0
      for i = 1, count do len = (len << 8) | (der:byte(at + 1 + i) or 0) end
      start = at + 2 + count
    end
    local v = der:sub(start, start + len - 1):gsub("^\0", "")
    values[#values + 1] = v
    at = start + len
  end
  return assert(values[1]), assert(values[2])
end

--- `key`'s public half as a COSE_Key.
local function cose(key: Key): string
  local entries: {{Cbor.Item}}
  if key.alg == -7 then
    local public = Sign.p256_public(key.secret)
    entries = {
      { Cbor.integer(1), Cbor.integer(2) }, { Cbor.integer(3), Cbor.integer(-7) },
      { Cbor.integer(-1), Cbor.integer(1) }, { Cbor.integer(-2), Cbor.bytes(public:sub(2, 33)) },
      { Cbor.integer(-3), Cbor.bytes(public:sub(34, 65)) },
    }
  elseif key.alg == -8 then
    entries = {
      { Cbor.integer(1), Cbor.integer(1) }, { Cbor.integer(3), Cbor.integer(-8) },
      { Cbor.integer(-1), Cbor.integer(6) }, { Cbor.integer(-2), Cbor.bytes(Sign.ed25519_public(key.secret)) },
    }
  else
    local n, e = rsa_parts(Sign.rsa_public(key.secret))
    entries = {
      { Cbor.integer(1), Cbor.integer(3) }, { Cbor.integer(3), Cbor.integer(-257) },
      { Cbor.integer(-1), Cbor.bytes(n) }, { Cbor.integer(-2), Cbor.bytes(e) },
    }
  end
  return Cbor.encode(Cbor.map(entries), { sort = true })
end

--- `message` signed by `key` as WebAuthn spells it.
local function signed(key: Key, message: string): string
  if key.alg == -7 then return der_signature(Sign.p256(key.secret, message)) end
  if key.alg == -8 then return Sign.ed25519(key.secret, message) end
  return Sign.rsa(key.secret, message)
end

--- What a test changes of what the authenticator or browser sends.
local record Twist
  type?: string
  challenge?: string
  origin?: string
  rp_id?: string
  flags?: integer
  cross_origin?: boolean
  fmt?: string
  statement?: Cbor.Item
  raw_id?: string
  tail?: string
  count?: integer
  user_handle?: string
  signature?: string
  --- The COSE key in place of the key's own.
  cose?: string
  --- The credential id the authenticator data holds, in place of the key's.
  id?: string
  --- The authenticator data whole, in place of what is made.
  data?: string
  --- The attestation object whole.
  object?: string
end

local function client_data(kind: string, challenge: string, t: Twist): string
  local data: mut {string: Json.Value} = {
    type = t.type or kind, challenge = Codec.base64url(t.challenge or challenge), origin = t.origin or ORIGIN,
  }
  if t.cross_origin ~= nil then data["crossOrigin"] = t.cross_origin end
  return (assert(Json.encode(data)))
end

local function head_of(t: Twist, count: integer, flags: integer): string
  return Hash.sha256(t.rp_id or RP) .. string.char(t.flags or flags) .. string.pack(">I4", t.count or count)
end

--- The browser's JSON of a registration of `key` under `challenge`.
local function registration(key: Key, challenge: string, twist?: Twist): {string: Json.Value}
  local t: Twist = twist or {}
  local id = t.id or key.id
  local data = t.data or (head_of(t, key.count, 0x45 | 0x08 | 0x10) .. ("\0"):rep(16) .. string.pack(">I2", #id) .. id ..
    (t.cose or cose(key)) .. (t.tail or ""))
  local cd = client_data("webauthn.create", challenge, t)
  local statement = t.statement or Cbor.map({})
  if t.fmt == "packed" and t.statement == nil then
    statement = Cbor.map({
      { Cbor.text("alg"), Cbor.integer(key.alg) },
      { Cbor.text("sig"), Cbor.bytes(signed(key, data .. Hash.sha256(cd))) },
    })
  end
  local object = t.object or Cbor.encode(Cbor.map({
    { Cbor.text("fmt"), Cbor.text(t.fmt or "none") }, { Cbor.text("attStmt"), statement },
    { Cbor.text("authData"), Cbor.bytes(data) },
  }))
  local raw = t.raw_id or key.id
  return {
    id = Codec.base64url(raw), rawId = Codec.base64url(raw), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(cd), attestationObject = Codec.base64url(object),
      transports = Json.array({ "internal", "hybrid" }),
    },
  }
end

--- The browser's JSON of a login with `key` under `challenge`.
local function login(key: Key, challenge: string, twist?: Twist): {string: Json.Value}
  local t: Twist = twist or {}
  key.count = key.count + (if key.count > 0 then 1 else 0 end)
  local data = t.data or (head_of(t, key.count, 0x05 | 0x08) .. (t.tail or ""))
  local cd = client_data("webauthn.get", challenge, t)
  local raw = t.raw_id or key.id
  return {
    id = Codec.base64url(raw), rawId = Codec.base64url(raw), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(cd), authenticatorData = Codec.base64url(data),
      signature = Codec.base64url(t.signature or signed(key, data .. Hash.sha256(cd))),
      userHandle = Codec.base64url(t.user_handle or HANDLE),
    },
  }
end

local function expected(challenge: string, uv?: boolean): Webauthn.Expected
  return { challenge = challenge, origin = ORIGIN, rp_id = RP, user_verification = uv }
end

local function registered(key: Key): Webauthn.Credential
  local challenge = Webauthn.challenge()
  local credential, why = Webauthn.verify_registration(registration(key, challenge), HANDLE, expected(challenge))
  assert(credential ~= nil, why)
  return credential
end

local function test_each_algorithm_registers_and_logs_in()
  for _, alg in ipairs({ -7, -8, -257 }) do
    local key = key_new(alg)
    local credential = registered(key)
    assert(credential.alg == alg and credential.id == key.id and credential.user_handle == HANDLE)
    assert(credential.backup_eligible and credential.backed_up and credential.user_verified)
    assert(credential.transports[1] == "internal" and #credential.aaguid == 16)
    local challenge = Webauthn.challenge()
    local answer = login(key, challenge)
    assert(Webauthn.credential_id(answer) == key.id)
    local assertion, why = Webauthn.verify_authentication(answer, credential, expected(challenge, true))
    assert(assertion ~= nil, why)
    assert(assertion.sign_count == 0 and not assertion.backed_up and assertion.user_verified)
  end
end

local function test_a_packed_self_attestation()
  local key = key_new(-7)
  local challenge = Webauthn.challenge()
  assert(Webauthn.verify_registration(registration(key, challenge, { fmt = "packed" }), HANDLE,
    expected(challenge)) ~= nil)
  local forged = Cbor.map({
    { Cbor.text("alg"), Cbor.integer(-7) }, { Cbor.text("sig"), Cbor.bytes(der_signature(("\1"):rep(64))) },
  })
  local refused, why = Webauthn.verify_registration(registration(key, challenge, { fmt = "packed", statement = forged }),
    HANDLE, expected(challenge))
  assert(refused == nil and why:find("does not check", 1, true) ~= nil, why)
  local chain = Cbor.map({
    { Cbor.text("alg"), Cbor.integer(-7) }, { Cbor.text("sig"), Cbor.bytes("x") },
    { Cbor.text("x5c"), Cbor.array({ Cbor.bytes("cert") }) },
  })
  local chained, said = Webauthn.verify_registration(registration(key, challenge, { fmt = "packed", statement = chain }),
    HANDLE, expected(challenge))
  assert(chained == nil and said:find("certificate chain", 1, true) ~= nil, said)
end

local function test_registrations_that_are_refused()
  local key = key_new(-7)
  local challenge = Webauthn.challenge()
  local function refused(twist: Twist, says: string, uv?: boolean)
    local credential, why = Webauthn.verify_registration(registration(key, challenge, twist), HANDLE,
      expected(challenge, uv))
    assert(credential == nil and why:find(says, 1, true) ~= nil, why)
  end
  refused({ challenge = "another" }, "challenge")
  refused({ origin = "https://evil.example.com" }, "origin")
  refused({ type = "webauthn.get" }, "webauthn.create")
  refused({ rp_id = "evil.example.com" }, "relying party")
  refused({ cross_origin = true }, "frame")
  refused({ flags = 0x44 }, "not present")
  refused({ flags = 0x41 }, "not verified", true)
  refused({ flags = 0x51 }, "backed up but cannot be")
  refused({ flags = 0x05 }, "bytes follow")
  refused({ raw_id = "another id" }, "not the answer's")
  refused({ tail = "\0" }, "bytes follow")
  refused({ fmt = "tpm" }, "not taken")
  refused({ statement = Cbor.map({ { Cbor.text("x"), Cbor.integer(1) } }) }, "has a statement")
  local mismatched: mut {string: Json.Value} = {}
  for k, v in pairs(registration(key, challenge)) do mismatched[k] = v end
  mismatched["id"] = "AAAA"
  local credential, why = Webauthn.verify_registration(mismatched, HANDLE, expected(challenge))
  assert(credential == nil and why:find("rawId", 1, true) ~= nil, why)
end

local function test_logins_that_are_refused()
  local key = key_new(-7)
  local credential = registered(key)
  local challenge = Webauthn.challenge()
  local function refused(twist: Twist, says: string, uv?: boolean)
    local assertion, why = Webauthn.verify_authentication(login(key, challenge, twist), credential,
      expected(challenge, uv))
    assert(assertion == nil and why:find(says, 1, true) ~= nil, why)
  end
  refused({ challenge = "another" }, "challenge")
  refused({ origin = "https://evil.example.com" }, "origin")
  refused({ type = "webauthn.create" }, "webauthn.get")
  refused({ rp_id = "evil.example.com" }, "relying party")
  refused({ flags = 0x08 }, "not present")
  refused({ flags = 0x09 }, "not verified", true)
  refused({ flags = 0x05 }, "eligibility")
  refused({ raw_id = "another id" }, "another credential")
  refused({ user_handle = "another user" }, "another user")
  refused({ signature = der_signature(("\1"):rep(64)) }, "does not check")
  refused({ tail = "\0" }, "bytes follow")
  -- A signature in a DER that is not minimal is no signature.
  local raw = Sign.p256(key.secret, "x")
  refused({ signature = "\x30\x45\x02\x21\0" .. raw:sub(1, 32) .. "\x02\x20" .. raw:sub(33, 64) }, "does not check")
end

--- An authenticator that counts must count up: one that does not is
--- read as a copy.
local function test_the_signature_counter()
  local key = key_new(-8)
  key.count = 5
  local credential = registered(key)
  assert(credential.sign_count == 5)
  local challenge = Webauthn.challenge()
  local assertion = assert(Webauthn.verify_authentication(login(key, challenge), credential, expected(challenge)))
  assert(assertion.sign_count == 6)
  credential.sign_count = assertion.sign_count
  local again, why = Webauthn.verify_authentication(login(key, challenge, { count = 6 }), credential, expected(challenge))
  assert(again == nil and why:find("cloned", 1, true) ~= nil, why)
end

local function test_options()
  local challenge = Webauthn.challenge()
  local key = key_new(-8)
  local credential = registered(key)
  local made = Webauthn.creation_options({
    rp_id = RP, rp_name = "Example", user_id = HANDLE, user_name = "ada", exclude = { credential },
  }, challenge)
  local text = assert(Json.encode(made))
  assert(text:find('"challenge":"' .. Codec.base64url(challenge) .. '"', 1, true) ~= nil)
  assert(text:find('"residentKey":"required"', 1, true) ~= nil, text)
  assert(text:find('"attestation":"none"', 1, true) ~= nil)
  assert(text:find('"alg":-8', 1, true) ~= nil and text:find('"alg":-257', 1, true) ~= nil)
  assert(text:find(Codec.base64url(key.id), 1, true) ~= nil)
  local asked = assert(Json.encode(Webauthn.request_options({ rp_id = RP, user_verification = "required" }, challenge)))
  assert(asked:find('"rpId":"example.com"', 1, true) ~= nil and asked:find('"allowCredentials":[]', 1, true) ~= nil, asked)
  Test.raises(function()
    Webauthn.creation_options({ rp_id = RP, rp_name = "x", user_id = "", user_name = "a" }, challenge)
  end,
    "user_id")
  Test.raises(function() Webauthn.request_options({ rp_id = "" }, challenge) end, "rp_id")
end

local function test_what_is_no_answer_is_refused()
  local credential = registered(key_new(-7))
  local challenge = Webauthn.challenge()
  local answers: {{string: Json.Value}} = {
    {}, { type = "public-key" }, { type = "public-key", id = "AA", rawId = "AA" },
    { type = "public-key", id = "AA", rawId = "AA", response = "x" },
    { type = "public-key", id = "AA", rawId = "AA", response = { clientDataJSON = "!!" } },
  }
  for _, answer in ipairs(answers) do
    local r, why = Webauthn.verify_registration(answer, HANDLE, expected(challenge))
    assert(r == nil and why ~= "")
    local a, said = Webauthn.verify_authentication(answer, credential, expected(challenge))
    assert(a == nil and said ~= "")
  end
end

--- A COSE key of `entries`, label then value, sorted.
local function cose_of(entries: {{integer | string}}): string
  local items: mut {{Cbor.Item}} = {}
  for _, e in ipairs(entries) do
    local label, value = e[1], e[2]
    assert(label is integer)
    local item: Cbor.Item
    if value is integer then item = Cbor.integer(value) else item = Cbor.bytes(tostring(value)) end
    items[#items + 1] = { Cbor.integer(label), item }
  end
  return Cbor.encode(Cbor.map(items), { sort = true })
end

local function test_cose_keys_that_are_refused()
  local key = key_new(-7)
  local public = Sign.p256_public(key.secret)
  local x, y = public:sub(2, 33), public:sub(34, 65)
  local challenge = Webauthn.challenge()
  local function refused(c: string, says: string)
    local credential, why = Webauthn.verify_registration(registration(key, challenge, { cose = c }), HANDLE,
      expected(challenge))
    assert(credential == nil and why:find(says, 1, true) ~= nil, why)
  end
  refused(cose_of({ { 1, 2 }, { 3, -35 }, { -1, 1 }, { -2, x }, { -3, y } }), "algorithm is not taken")
  refused(cose_of({ { 1, 1 }, { 3, -7 }, { -1, 1 }, { -2, x }, { -3, y } }), "type is not its algorithm's")
  refused(cose_of({ { 1, 2 }, { 3, -7 }, { -1, 2 }, { -2, x }, { -3, y } }), "point of P-256")
  refused(cose_of({ { 1, 2 }, { 3, -7 }, { -1, 1 }, { -2, x } }), "point of P-256")
  refused(cose_of({ { 1, 2 }, { 3, -7 }, { -1, 1 }, { -2, x }, { -3, y:sub(2) } }), "32 bytes")
  refused(cose_of({ { 1, 1 }, { 3, -8 }, { -1, 4 }, { -2, x } }), "Ed25519")
  refused(cose_of({ { 1, 3 }, { 3, -257 }, { -1, x } }), "n and e")
  -- An n with a first byte of zero is refused for that before its size.
  refused(cose_of({ { 1, 3 }, { 3, -257 }, { -1, "\1" .. x:sub(2) }, { -2, "\1\0\1" } }), "2048")
  refused(Cbor.encode(Cbor.array({})), "no COSE key")
end

local function test_credential_ids_of_no_length_or_too_long()
  local key = key_new(-8)
  local challenge = Webauthn.challenge()
  local function refused(twist: Twist, says: string)
    local credential, why = Webauthn.verify_registration(registration(key, challenge, twist), HANDLE, expected(challenge))
    assert(credential == nil and why:find(says, 1, true) ~= nil, why)
  end
  refused({ raw_id = "" }, "1 to 1023")
  refused({ raw_id = ("x"):rep(1024) }, "1 to 1023")
  refused({ id = "" }, "1 to 1023")
  refused({ id = ("x"):rep(1024) }, "1 to 1023")
  local long = key_new(-8)
  long.id = ("x"):rep(1023)
  assert(registered(long).id == long.id)
end

local function test_authenticator_data_that_is_not_whole()
  local key = key_new(-7)
  local challenge = Webauthn.challenge()
  local whole = head_of({}, 0, 0x5d) .. ("\0"):rep(16) .. string.pack(">I2", #key.id) .. key.id .. cose(key)
  local function refused(twist: Twist, says: string)
    local credential, why = Webauthn.verify_registration(registration(key, challenge, twist), HANDLE, expected(challenge))
    assert(credential == nil and why:find(says, 1, true) ~= nil, why)
  end
  for n = 0, #whole - 1 do
    local credential, why = Webauthn.verify_registration(registration(key, challenge, { data = whole:sub(1, n) }),
      HANDLE, expected(challenge))
    assert(credential == nil and why ~= "", n)
  end
  refused({ data = whole:sub(1, 36) }, "short")
  refused({ data = whole:sub(1, 50) }, "short")
  refused({ data = whole:sub(1, 70) }, "short")
  -- The ED flag: extensions follow the key, and are a map.
  local ed = head_of({}, 0, 0xdd) .. ("\0"):rep(16) .. string.pack(">I2", #key.id) .. key.id .. cose(key)
  local with_ext = assert(Webauthn.verify_registration(registration(key, challenge, { data = ed .. "\xa0" }), HANDLE,
    expected(challenge)))
  assert(with_ext.id == key.id)
  refused({ data = ed .. "\x80" }, "no map")
  refused({ data = ed .. "\xa1" }, "extensions")
  refused({ data = ed }, "extensions")
  refused({ data = whole .. ("\0"):rep(64 * 1024) }, "too long")
  refused({ object = "\x80" }, "lacks fmt")
  refused({ object = Cbor.encode(Cbor.map({ { Cbor.text("fmt"), Cbor.text("none") } })) }, "lacks fmt")
  refused({ object = "\xff" }, "attestation object")
end

local function test_the_packed_algorithm_is_the_credential_s()
  local key = key_new(-7)
  local challenge = Webauthn.challenge()
  local statement = Cbor.map({
    { Cbor.text("alg"), Cbor.integer(-257) }, { Cbor.text("sig"), Cbor.bytes("x") },
  })
  local credential, why = Webauthn.verify_registration(registration(key, challenge, { fmt = "packed", statement = statement }),
    HANDLE, expected(challenge))
  assert(credential == nil and why:find("credential's algorithm", 1, true) ~= nil, why)
end

--- A signature is checked against the kept key alone: another key of the
--- same algorithm, signing the same bytes, is refused.
local function test_a_login_is_bound_to_the_kept_key()
  local key = key_new(-7)
  local credential = registered(key)
  local other = key_new(-7)
  other.id = key.id
  local challenge = Webauthn.challenge()
  local assertion, why = Webauthn.verify_authentication(login(other, challenge), credential, expected(challenge))
  assert(assertion == nil and why:find("does not check", 1, true) ~= nil, why)
  local wrong_alg: Webauthn.Credential = {
    id = credential.id, public_key = credential.public_key, alg = -8, sign_count = 0, user_handle = HANDLE,
    backup_eligible = true, backed_up = false, transports = {}, user_verified = true, aaguid = credential.aaguid,
  }
  local refused, said = Webauthn.verify_authentication(login(key, challenge), wrong_alg, expected(challenge))
  assert(refused == nil and said:find("kept algorithm", 1, true) ~= nil, said)
  local garbled: Webauthn.Credential = {
    id = credential.id, public_key = "\xff", alg = -7, sign_count = 0, user_handle = HANDLE,
    backup_eligible = true, backed_up = false, transports = {}, user_verified = true, aaguid = credential.aaguid,
  }
  local unread, told = Webauthn.verify_authentication(login(key, challenge), garbled, expected(challenge))
  assert(unread == nil and told:find("kept public key", 1, true) ~= nil, told)
end

local function test_the_counter_must_move_up()
  local key = key_new(-7)
  key.count = 10
  local credential = registered(key)
  local challenge = Webauthn.challenge()
  for _, count in ipairs({ 9, 10, 0 }) do
    local assertion, why = Webauthn.verify_authentication(login(key, challenge, { count = count }), credential,
      expected(challenge))
    assert(assertion == nil and why:find("cloned", 1, true) ~= nil, tostring(count))
  end
  assert(Webauthn.verify_authentication(login(key, challenge, { count = 11 }), credential, expected(challenge)) ~= nil)
end

local function test_signatures_in_der_that_is_not_strict()
  local key = key_new(-7)
  local credential = registered(key)
  local challenge = Webauthn.challenge()
  local r, s = ("\x7f"):rep(32), ("\x01"):rep(32)
  local high = "\xff" .. ("\1"):rep(31)
  local bad_signatures: {string} = {
    "\x30\x44\x02\x20" .. high .. "\x02\x20" .. s,
    "\x30\x45\x02\x20" .. r .. "\x02\x20" .. s,
    "\x30\x44\x02\x20" .. r .. "\x02\x20" .. s .. "\0",
    "\x30\x24\x02\x00\x02\x20" .. s,
    "\x30\x48\x02\x22\0\0" .. r .. "\x02\x20" .. s,
    "\x30\x22\x02\x20" .. r,
    "",
  }
  for _, bad in ipairs(bad_signatures) do
    local assertion, why = Webauthn.verify_authentication(login(key, challenge, { signature = bad }), credential,
      expected(challenge))
    assert(assertion == nil and why:find("does not check", 1, true) ~= nil, why)
  end
end

local function test_cross_origin_false_is_taken()
  local key = key_new(-8)
  local challenge = Webauthn.challenge()
  assert(Webauthn.verify_registration(registration(key, challenge, { cross_origin = false }), HANDLE,
    expected(challenge)) ~= nil)
end

local function test_empty_expectations_raise()
  local key = key_new(-8)
  local credential = registered(key)
  local answer = login(key, "x")
  Test.raises(function() Webauthn.verify_authentication(answer, credential, expected("")) end, "must not be empty")
  Test.raises(function() Webauthn.verify_registration(registration(key, "c"), "", expected("c")) end, "user_handle")
end
