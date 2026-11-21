--- Worked examples for [`cosmic.webauthn`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Json = require("cosmic.json")
local Webauthn = require("cosmic.webauthn")

local record Example
end

--- The options a page hands to `navigator.credentials.create`, for a
--- new passkey of the user whose handle is `u-1`.
function Example.creation_options()
  local challenge = Webauthn.challenge()
  local options = Webauthn.creation_options({
    rp_id = "example.com", rp_name = "Example", user_id = "u-1", user_name = "ada@example.com",
  }, challenge)
  local named = options["rp"]
  assert(named ~= nil)
  local rp = assert(Json.to_object(named))
  print(rp["id"], options["attestation"])
  assert(rp["id"] == "example.com")
end

--- The options of a login with no user named first: any passkey of the
--- app the browser holds may answer.
function Example.request_options()
  local options = Webauthn.request_options({ rp_id = "example.com", user_verification = "required" },
    Webauthn.challenge())
  print(options["rpId"], options["userVerification"])
  assert(options["userVerification"] == "required")
end

--- What the browser sends is checked before anything in it is
--- believed: here an answer to another challenge.
function Example.verify_registration()
  local answer = assert(Json.decode_object([[
    {"type": "public-key", "id": "AQID", "rawId": "AQID",
     "response": {"clientDataJSON": "eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIiwiY2hhbGxlbmdlIjoiQUFBQSIsIm9yaWdpbiI6Imh0dHBzOi8vZXhhbXBsZS5jb20ifQ",
                  "attestationObject": "oA"}}
  ]]))
  local credential, why = Webauthn.verify_registration(answer, "u-1", {
    challenge = Webauthn.challenge(), origin = "https://example.com", rp_id = "example.com",
  })
  print(credential == nil, why)
  assert(credential == nil and why:find("challenge", 1, true) ~= nil)
  assert(Webauthn.credential_id(answer) == "\1\2\3")
end

--- A login is checked against the passkey the app keeps for the id the
--- answer names: here an answer from another passkey is refused before
--- its signature is read.
function Example.verify_authentication()
  local kept: Webauthn.Credential = {
    id = "\9\9\9", public_key = "", alg = -8, sign_count = 0, user_handle = "u-1", backup_eligible = true,
    backed_up = true, transports = { "internal" }, user_verified = true, aaguid = ("\0"):rep(16),
  }
  local answer = assert(Json.decode_object([[
    {"type": "public-key", "id": "AQID", "rawId": "AQID",
     "response": {"clientDataJSON": "e30", "authenticatorData": "", "signature": ""}}
  ]]))
  local assertion, why = Webauthn.verify_authentication(answer, kept, {
    challenge = Webauthn.challenge(), origin = "https://example.com", rp_id = "example.com",
  })
  print(assertion == nil, why)
  assert(assertion == nil and why:find("another credential", 1, true) ~= nil)
end

return Example
