--- Worked examples for [`Web.passkeys`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test. A stand-in authenticator answers in place of a browser's.

local Cbor = require("cosmic.cbor")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Input = require("cosmic.web.input")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local Sign = require("cosmic.sign")
local Sqlite = require("cosmic.sqlite")
local Url = require("cosmic.url")
local Web = require("cosmic.web")

local record Example
end

--- Ada signs up, which makes her account with a user handle drawn at
--- random and keeps it in the session, and registers a passkey for the
--- new account; a second sign-up under her name is refused, since it
--- would add a stranger's passkey to her account. Later, another browser
--- logs in with the passkey and no name at all. The authenticator here
--- is a stand-in that answers what `navigator.credentials` would.
function Example.passkeys()
  local origin = "https://example.com"
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE accounts (name TEXT PRIMARY KEY, handle BLOB NOT NULL UNIQUE)"))
  local function handle_of(name: string): string?
    return assert(Sqlite.map(db, "SELECT handle FROM accounts WHERE name = ?1", { { text = name } },
      function(r: Sqlite.Row): string return r:blob(1) end))[1]
  end
  local function name_of(handle: string): string?
    return assert(Sqlite.map(db, "SELECT name FROM accounts WHERE handle = ?1", { { blob = handle } },
      function(r: Sqlite.Row): string return r:text(1) end))[1]
  end
  local app = Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local who = Web.passkey_identity(req)
        if who == nil then return Web.text("nobody") end
        return Web.text("hello " .. assert(name_of(who.user_handle)))
      end),
      -- The name is the account's from here on: one taken is refused.
      Web.post("/signup", function(req: Web.Request): Web.Response
        local form = assert(Input.form(req).value)
        local name = Url.query_last(form, "name")
        if name == nil or name == "" then return Web.empty(400) end
        local handle = assert(Rand.entropy(16))
        assert(Sqlite.run(db, "INSERT INTO accounts (name, handle) VALUES (?1, ?2) ON CONFLICT DO NOTHING",
          { { text = name }, { blob = handle } }))
        if db:changes() ~= 1 then return Web.empty(409) end
        Session.of(req):set("signup", name)
        return Web.empty(204)
      end),
    },
    middleware = {
      Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } },
      Web.passkeys{
        rp_id = "example.com", rp_name = "Example", origin = origin,
        store = assert(Web.passkey_store(db)),
        -- The account this browser is making, or none, by the handle
        -- kept with it.
        user = function(req: Web.Request): Web.PasskeyUser?
          local name = Session.of(req):get_string("signup")
          if name == nil then return nil end
          local handle = handle_of(name)
          if handle == nil then return nil end
          return { handle = handle, name = name }
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
  -- A browser on an https page: the session cookie is Secure.
  first.scheme = "https"
  print(first:post("/auth/passkey/register/begin", { json = none }).status)
  print(first:post("/signup", { form = { name = "ada" } }).status)
  local begun = first:post("/auth/passkey/register/begin", { json = none })
  local challenge = challenge_of(begun)
  -- The authenticator keeps the user handle with the passkey.
  local user_id = assert(Json.to_object(assert(Json.to_object((begun:json())))["user"]))["id"]
  assert(user_id is string)
  local handle = assert(Codec.unbase64url(user_id))
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
  local stranger = Web.test_client(app)
  stranger.scheme = "https"
  local taken = stranger:post("/signup", { form = { name = "ada" } })
  print(taken.status)
  assert(taken.status == 409)

  local second = Web.test_client(app)
  second.scheme = "https"
  print(second:get("/"):text())
  challenge = challenge_of(second:post("/auth/passkey/login/begin", { json = none }))
  local data = Hash.sha256("example.com") .. "\x1d" .. string.pack(">I4", 0)
  local cd = client_data("webauthn.get", challenge)
  local logged_in = second:post("/auth/passkey/login/finish?next=/", { json = {
    id = Codec.base64url(id), rawId = Codec.base64url(id), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(cd), authenticatorData = Codec.base64url(data),
      signature = Codec.base64url(Sign.ed25519(secret, data .. Hash.sha256(cd))),
      userHandle = Codec.base64url(handle),
    },
  } })
  print(logged_in.status, logged_in.body)
  print(second:get("/"):text())
  assert(second:get("/"):text() == "hello ada")
end

return Example
