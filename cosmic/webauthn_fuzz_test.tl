--- Fuzz properties for [`cosmic.webauthn`], whose every input is a
--- browser's JSON and so from anyone: [`Webauthn.verify_registration`]
--- and [`Webauthn.verify_authentication`] return for any response, changed
--- in its bytes or in its JSON, and never raise; a login is taken only
--- when the bytes the key signed are the ones it signed.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Array = require("cosmic.array")
local Cbor = require("cosmic.cbor")
local Codec = require("cosmic.codec")
local Fuzz = require("build.fuzz")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
-- The raw signing operations on bytes, which the stand-in key is built of.
local Sign = require("cosmic.internal.sign")
local Webauthn = require("cosmic.webauthn")

local RP <const> = "example.com"
local ORIGIN <const> = "https://example.com"
local HANDLE <const> = "user-handle-1"
local CHALLENGE <const> = "a challenge of the fuzz properties"
local ID <const> = "credential-id-16"
local EXPECTED: Webauthn.Expected = { challenge = CHALLENGE, origin = ORIGIN, rp_id = RP }

-- A fixed key, as P-256 signing here is deterministic: the same seed
-- then reaches the same inputs, and a kept login replays.
local secret <const> = Hash.sha256("cosmic.webauthn_fuzz_test key")

--- The bytes base64url `text` spells, or "" where it spells none.
local function bytes_of(text: string): string
  local bytes, _ = Codec.unbase64url(text)
  return bytes or ""
end

--- DER INTEGER of the unsigned big-endian `b`.
local function der_int(b: string): string
  local trimmed = b:gsub("^\0+", "")
  if trimmed == "" then trimmed = "\0" end
  if (trimmed:byte(1) or 0) >= 0x80 then trimmed = "\0" .. trimmed end
  return "\2" .. string.char(#trimmed) .. trimmed
end

--- `message` signed by the stand-in key, as WebAuthn spells ES256.
local function signed(message: string): string
  local raw = Sign.p256(secret, message)
  local body = der_int(raw:sub(1, 32)) .. der_int(raw:sub(33, 64))
  return "\x30" .. string.char(#body) .. body
end

local function cose(): string
  local public = Sign.p256_public(secret)
  return Cbor.encode(Cbor.map({
    { Cbor.integer(1), Cbor.integer(2) }, { Cbor.integer(3), Cbor.integer(-7) },
    { Cbor.integer(-1), Cbor.integer(1) }, { Cbor.integer(-2), Cbor.bytes(public:sub(2, 33)) },
    { Cbor.integer(-3), Cbor.bytes(public:sub(34, 65)) },
  }), { sort = true })
end

local function client_data(kind: string): string
  return (assert(Json.encode({ type = kind, challenge = Codec.base64url(CHALLENGE), origin = ORIGIN })))
end

local function head(flags: integer): string
  return Hash.sha256(RP) .. string.char(flags) .. string.pack(">I4", 0)
end

--- The parts of a registration, each as the bytes the browser encodes.
local record Parts
  client: string
  object: string
  raw_id: string
end

local registration_parts <const>: Parts = {
  client = client_data("webauthn.create"),
  object = Cbor.encode(Cbor.map({
    { Cbor.text("fmt"), Cbor.text("none") }, { Cbor.text("attStmt"), Cbor.map({}) },
    { Cbor.text("authData"), Cbor.bytes(head(0x45 | 0x08 | 0x10) .. ("\0"):rep(16) ..
        string.pack(">I2", #ID) .. ID .. cose()) },
  })),
  raw_id = ID,
}

local function registration(p: Parts): {string: Json.Value}
  return {
    id = Codec.base64url(p.raw_id), rawId = Codec.base64url(p.raw_id), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(p.client), attestationObject = Codec.base64url(p.object),
      transports = Json.array({ "internal" }),
    },
  }
end

local login_client <const> = client_data("webauthn.get")
local login_data <const> = head(0x05 | 0x08)
local login_signature <const> = signed(login_data .. Hash.sha256(login_client))

local function login(client: string, data: string, signature: string, user: string): {string: Json.Value}
  return {
    id = Codec.base64url(ID), rawId = Codec.base64url(ID), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(client), authenticatorData = Codec.base64url(data),
      signature = Codec.base64url(signature), userHandle = Codec.base64url(user),
    },
  }
end

local credential <const> = assert(Webauthn.verify_registration(registration(registration_parts), HANDLE, EXPECTED))

--- The browser's JSON of `answer` as text, for a property that changes it whole.
local function text_of(answer: {string: Json.Value}): string
  return (assert(Json.encode(answer)))
end

--- One of `parts` changed, or `whole` (the JSON text) changed, packed:
--- first "json" and the text, or the changed part's name and every part.
local function changed(src: Fuzz.Source, names: {string}, parts: {string}, whole: string): string
  local which = src:int(0, #names)
  if which == 0 then return Fuzz.pack({ "json", Fuzz.mutate(src, whole, 6) }) end
  local fields: mut {string} = { Array.at(names, which) }
  for i, part in ipairs(parts) do
    fields[#fields + 1] = if i == which then Fuzz.mutate(src, part, 6) else part end
  end
  return Fuzz.pack(fields)
end

--- The response an input of `changed` stands for: its text decoded, or
--- the one `build` makes of its parts; nil for text that is no object.
local function answer_of(fields: {string}, build: function({string}): {string: Json.Value}): {string: Json.Value}?
  if fields[1] == "json" then
    Fuzz.label("json")
    local decoded, _ = Json.decode_object(fields[2] or "")
    return decoded
  end
  Fuzz.label("parts")
  return build(fields)
end

--- Why client data that was taken should not have been, or "" when it is
--- of `kind`, the challenge and the origin.
local function client_wrong(client: string, kind: string): string
  local parsed, _ = Json.decode_object(client)
  if parsed == nil then return "took client data that is no JSON object" end
  if parsed["type"] ~= kind or parsed["challenge"] ~= Codec.base64url(CHALLENGE) or parsed["origin"] ~= ORIGIN then
    return "took client data of another type, challenge or origin: " .. client
  end
  return ""
end

local function test_a_changed_registration_is_answered_and_never_raises(tmp: string)
  local p = registration_parts
  Fuzz.run({
    name = "verify a changed registration",
    dir = tmp,
    requires = { "json", "parts", "registered", "refused" },
    gen = function(src: Fuzz.Source): string
      return changed(src, { "client", "object", "raw_id" }, { p.client, p.object, p.raw_id },
        text_of(registration(p)))
    end,
    check = function(input: string): boolean, string
      local answer = answer_of(Fuzz.unpack(input), function(f: {string}): {string: Json.Value}
        return registration({ client = f[2] or "", object = f[3] or "", raw_id = f[4] or "" })
      end)
      if answer == nil then return true, "" end
      local got, why = Webauthn.verify_registration(answer, HANDLE, EXPECTED)
      if got == nil then
        Fuzz.label("refused")
        if why == "" then return false, "a refusal with no reason" end
        return true, ""
      end
      Fuzz.label("registered")
      if got.alg ~= -7 and got.alg ~= -8 and got.alg ~= -257 then
        return false, "registered an algorithm not taken: " .. tostring(got.alg)
      end
      if got.user_handle ~= HANDLE or #got.id == 0 or #got.id > 1023 then
        return false, "registered a credential not bound to the answer"
      end
      local r, _ = Json.to_object(answer["response"])
      if r == nil then return false, "registered an answer with no response object" end
      local wrong = client_wrong(bytes_of(tostring(r["clientDataJSON"])), "webauthn.create")
      if wrong ~= "" then return false, wrong end
      return true, ""
    end,
  })
end

--- Why a login that was taken should not have been, or "" when what it
--- holds is the challenge's, the origin's, the relying party's, a
--- present user's and the credential's user's.
local function wrongly_taken(r: {string: Json.Value}): string
  local client = bytes_of(tostring(r["clientDataJSON"]))
  local data = bytes_of(tostring(r["authenticatorData"]))
  local handle = r["userHandle"]
  local user = if handle is string then bytes_of(handle) else "" end
  local bad_client = client_wrong(client, "webauthn.get")
  if bad_client ~= "" then return bad_client end
  if data:sub(1, 32) ~= Hash.sha256(RP) then return "took data for another relying party" end
  if (data:byte(33) or 0) & 0x01 == 0 then return "took a login whose user was not present" end
  if user ~= "" and user ~= HANDLE then return "took a login for another user" end
  return ""
end

local function test_a_login_is_taken_only_as_it_was_signed(tmp: string)
  Fuzz.run({
    name = "verify a changed login",
    dir = tmp,
    requires = { "json", "parts", "resigned", "refused", "taken" },
    shares = { taken = 0.05 },
    gen = function(src: Fuzz.Source): string
      -- A quarter are signed again after their client data and
      -- authenticator data change, so the checks before the signature's
      -- are what refuses them.
      if src:int(0, 3) == 0 then
        return Fuzz.pack({ "resigned", Fuzz.mutate(src, login_client, 4), Fuzz.mutate(src, login_data, 3),
          Fuzz.mutate(src, HANDLE, 2) })
      end
      return changed(src, { "client", "data", "signature", "user" },
        { login_client, login_data, login_signature, HANDLE },
        text_of(login(login_client, login_data, login_signature, HANDLE)))
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local resigned = fields[1] == "resigned"
      local answer: {string: Json.Value}?
      if resigned then
        Fuzz.label("resigned")
        local client, data = fields[2] or "", fields[3] or ""
        answer = login(client, data, signed(data .. Hash.sha256(client)), fields[4] or "")
      else
        answer = answer_of(fields, function(f: {string}): {string: Json.Value}
          return login(f[2] or "", f[3] or "", f[4] or "", f[5] or "")
        end)
      end
      if answer == nil then return true, "" end
      -- verify_authentication updates the credential it is given: each
      -- check gets a copy of the registered one.
      local held: Webauthn.Credential = {
        id = credential.id, public_key = credential.public_key, alg = credential.alg,
        sign_count = credential.sign_count, user_handle = credential.user_handle,
        backup_eligible = credential.backup_eligible, backed_up = credential.backed_up,
        transports = credential.transports, user_verified = credential.user_verified,
        aaguid = credential.aaguid,
      }
      local got, why = Webauthn.verify_authentication(answer, held, EXPECTED)
      if got == nil then
        Fuzz.label("refused")
        if why == "" then return false, "a refusal with no reason" end
        return true, ""
      end
      Fuzz.label("taken")
      local r, _ = Json.to_object(answer["response"])
      if r == nil then return false, "took a login with no response object" end
      local wrong = wrongly_taken(r)
      if wrong ~= "" then return false, wrong end
      if not resigned then
        local client, _ = Codec.unbase64url(tostring(r["clientDataJSON"]))
        local data, _ = Codec.unbase64url(tostring(r["authenticatorData"]))
        if client ~= login_client or data ~= login_data then
          return false, "took a login whose signed bytes changed"
        end
      end
      return true, ""
    end,
  })
end
