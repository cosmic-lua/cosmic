--- Worked examples for [`Web.passkeys`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test. A stand-in authenticator answers in place of a browser's.

local Cbor = require("cosmic.cbor")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Sign = require("cosmic.sign")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

local record Example
end

--- Ada signs up, which the session keeps, and registers a passkey for
--- the new account; later, another browser logs in with it and no name
--- at all. The authenticator here is a
--- stand-in that answers what `navigator.credentials` would.
function Example.passkeys()
  local origin = "https://example.com"
  local db = assert(Sqlite.memory())
  local app = Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local who = Web.passkey_identity(req)
        return Web.text(if who ~= nil then "hello " .. who.user_handle else "nobody" end)
      end),
      -- A sign-up page's form would take the name and make the account.
      Web.post("/signup", function(req: Web.Request): Web.Response
        Session.of(req):set("signup", "ada")
        return Web.empty(204)
      end),
    },
    middleware = {
      Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } },
      Web.passkeys{
        rp_id = "example.com", rp_name = "Example", origin = origin,
        store = assert(Web.passkey_store(db)),
        -- The account this browser is making, or none.
        user = function(req: Web.Request): Web.PasskeyUser?
          local name = Session.of(req):get_string("signup")
          if name == nil then return nil end
          return { handle = name, name = name .. "@example.com" }
        end,
      },
    },
  }
  local secret, id = assert(Rand.entropy(32)), assert(Rand.entropy(16))
  local none: {string: Json.Value} = {}
  local function challenge_of(res: Web.TestResponse): string
    local options = assert(Json.to_object((res:json())))
    local challenge = options["challenge"]
    assert(challenge is string)
    return (assert(Codec.unbase64url(challenge)))
  end
  local function client_data(kind: string, challenge: string): string
    return (assert(Json.encode({ type = kind, challenge = Codec.base64url(challenge), origin = origin })))
  end

  local first = Web.test_client(app)
  print(first:post("/auth/passkey/register/begin", { json = none }).status)
  local _ = first:post("/signup")
  local challenge = challenge_of(first:post("/auth/passkey/register/begin", { json = none }))
  local cose = Cbor.encode(Cbor.map({
    { Cbor.integer(1), Cbor.integer(1) }, { Cbor.integer(3), Cbor.integer(-8) },
    { Cbor.integer(-1), Cbor.integer(6) }, { Cbor.integer(-2), Cbor.bytes(Sign.ed25519_public(secret)) },
  }), { sort = true })
  local made = Hash.sha256("example.com") .. "\x5d" .. string.pack(">I4", 0) .. ("\0"):rep(16) ..
    string.pack(">I2", #id) .. id .. cose
  local registered = first:post("/auth/passkey/register/finish", { json = {
    id = Codec.base64url(id), rawId = Codec.base64url(id), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(client_data("webauthn.create", challenge)),
      attestationObject = Codec.base64url(Cbor.encode(Cbor.map({
        { Cbor.text("fmt"), Cbor.text("none") }, { Cbor.text("attStmt"), Cbor.map({}) },
        { Cbor.text("authData"), Cbor.bytes(made) },
      }))),
    },
  } })
  print(registered.status)

  local second = Web.test_client(app)
  print(second:get("/"):text())
  challenge = challenge_of(second:post("/auth/passkey/login/begin", { json = none }))
  local data = Hash.sha256("example.com") .. "\x1d" .. string.pack(">I4", 0)
  local cd = client_data("webauthn.get", challenge)
  local logged_in = second:post("/auth/passkey/login/finish?next=/", { json = {
    id = Codec.base64url(id), rawId = Codec.base64url(id), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(cd), authenticatorData = Codec.base64url(data),
      signature = Codec.base64url(Sign.ed25519(secret, data .. Hash.sha256(cd))),
      userHandle = Codec.base64url("ada"),
    },
  } })
  print(logged_in.status, logged_in.body)
  print(second:get("/"):text())
  assert(second:get("/"):text() == "hello ada")
end

return Example
