--- The passkeys of cosmic.web, against a stand-in authenticator: a
--- passkey registers and logs in through the endpoints, and each request
--- that is not bound to the challenge, the user, the store or the app's
--- origin is refused.

local Cbor = require("cosmic.cbor")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sign = require("cosmic.sign")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local Url = require("cosmic.url")
local Web = require("cosmic.web")
local type Webauthn = require("cosmic.webauthn")

local RP <const> = "example.com"
local ORIGIN <const> = "https://example.com"

--- A stand-in authenticator's passkey, Ed25519.
local record Key
  secret: string
  mut id: string
  mut count: integer
end

--- A client acting as a browser on an https page, which sends the Secure
--- session cookie back.
local function browser(app: Web.App): Web.TestClient
  local client = Web.test_client(app)
  client.scheme = "https"
  return client
end

local function key_new(): Key
  return { secret = assert(Rand.entropy(32)), id = assert(Rand.entropy(16)), count = 0 }
end

local function client_data(kind: string, challenge: string, origin?: string): string
  return (assert(Json.encode({ type = kind, challenge = Codec.base64url(challenge), origin = origin or ORIGIN })))
end

local function head_of(count: integer, flags: integer): string
  return Hash.sha256(RP) .. string.char(flags) .. string.pack(">I4", count)
end

--- The browser's JSON of a registration of `key` under `challenge`.
local function registration(key: Key, challenge: string, flags?: integer): {string: Json.Value}
  local cose = Cbor.encode(Cbor.map({
    { Cbor.integer(1), Cbor.integer(1) }, { Cbor.integer(3), Cbor.integer(-8) },
    { Cbor.integer(-1), Cbor.integer(6) }, { Cbor.integer(-2), Cbor.bytes(Sign.ed25519_public(key.secret)) },
  }), { sort = true })
  local data = head_of(key.count, flags or 0x5d) .. ("\0"):rep(16) .. string.pack(">I2", #key.id) .. key.id .. cose
  local object = Cbor.encode(Cbor.map({
    { Cbor.text("fmt"), Cbor.text("none") }, { Cbor.text("attStmt"), Cbor.map({}) },
    { Cbor.text("authData"), Cbor.bytes(data) },
  }))
  return {
    id = Codec.base64url(key.id), rawId = Codec.base64url(key.id), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(client_data("webauthn.create", challenge)),
      attestationObject = Codec.base64url(object), transports = Json.array({ "internal" }),
    },
  }
end

--- The browser's JSON of a login with `key` for `handle` under `challenge`.
local function assertion(key: Key, handle: string, challenge: string, flags?: integer): {string: Json.Value}
  local data = head_of(key.count, flags or 0x1d)
  local cd = client_data("webauthn.get", challenge)
  return {
    id = Codec.base64url(key.id), rawId = Codec.base64url(key.id), type = "public-key",
    response = {
      clientDataJSON = Codec.base64url(cd), authenticatorData = Codec.base64url(data),
      signature = Codec.base64url(Sign.ed25519(key.secret, data .. Hash.sha256(cd))),
      userHandle = Codec.base64url(handle),
    },
  }
end

--- The time a test's app reads, which the test moves.
local record Time
  mut now: integer
end

--- What a test changes of the app.
local record Extra
  store?: Web.PasskeyStore
  sessions?: Session.Store
  prefix?: string
  max_age?: integer
  require_verification?: boolean
  trusted_hosts?: {string}
  --- The handle the user `name` gets ("handle-" .. name).
  handle?: function(name: string): string
  --- The time the app reads, in place of one of its own.
  time?: Time
end

--- A test's app and what it keeps.
local record Rig
  app: Web.App
  store: Web.PasskeyStore
  time: Time
end

--- An app whose user, for a registration, is the one the `X-User`
--- header names: a test's stand-in, since a real app's names one the
--- session holds. `/` says who logged in with a passkey.
local function rig_of(extra?: Extra): Rig
  local e: Extra = extra or {}
  local store = e.store or assert(Web.passkey_store((assert(Sqlite.memory()))))
  local time: Time = e.time or { now = 1700000000 }
  local app = Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local who = Web.passkey_identity(req)
        if who == nil then return Web.text("nobody") end
        return Web.text(who.user_handle .. (if who.user_verified then " verified" else "" end))
      end),
    },
    middleware = {
      Session.middleware{
        store = e.sessions or SessionCookie.store{ keys = { Secret.generate() } },
        now = function(): integer return time.now end,
      },
      Web.passkeys{
        rp_id = RP, rp_name = "Example", origin = ORIGIN, store = store, prefix = e.prefix,
        max_age = e.max_age, require_verification = e.require_verification,
        now = function(): integer return time.now end,
        user = function(req: Web.Request): Web.PasskeyUser?
          local name = req:header("x-user")
          if name == nil then return nil end
          return { handle = if e.handle ~= nil then e.handle(name) else "handle-" .. name end, name = name }
        end,
      },
    },
    trusted_hosts = e.trusted_hosts,
  }
  return { app = app, store = store, time = time }
end

--- An empty JSON object.
local NONE: {string: Json.Value} = {}

local function post(client: Web.TestClient, path: string, body?: {string: Json.Value},
                    headers?: {string: string}): Web.TestResponse
  return client:post("/auth/passkey" .. path, { json = if body == nil then NONE else body end, headers = headers })
end

--- The challenge of a begin's answer.
local function challenge_of(res: Web.TestResponse): string
  assert(res.status == 200, res.body)
  local options = assert(Json.to_object((res:json())))
  local challenge = options["challenge"]
  assert(challenge is string)
  return (assert(Codec.unbase64url(challenge)))
end

local function register(client: Web.TestClient, key: Key, user: string): Web.TestResponse
  local headers = { ["X-User"] = user }
  local challenge = challenge_of(post(client, "/register/begin", nil, headers))
  return post(client, "/register/finish", registration(key, challenge), headers)
end

local function log_in(client: Web.TestClient, key: Key, handle: string, next_path?: string): Web.TestResponse
  local challenge = challenge_of(post(client, "/login/begin"))
  local path = "/login/finish" .. (if next_path ~= nil then "?next=" .. next_path else "" end)
  return post(client, path, assertion(key, handle, challenge))
end

local function test_a_passkey_registers_and_logs_in()
  local rig = rig_of()
  local key = key_new()
  local first = browser(rig.app)
  local made = register(first, key, "ada")
  assert(made.status == 201, made.body)
  assert(assert(Json.to_object((made:json())))["id"] == Codec.base64url(key.id))
  assert(first:get("/"):text() == "handle-ada verified")
  local kept = assert(assert(rig.store:list("handle-ada"))[1])
  assert(kept.id == key.id and kept.user_handle == "handle-ada" and kept.transports[1] == "internal")
  -- Another browser, with no user named, logs in by the passkey alone.
  local second = browser(rig.app)
  assert(second:get("/"):text() == "nobody")
  local res = log_in(second, key, "handle-ada", "/admin")
  assert(res.status == 200, res.body)
  assert(assert(Json.to_object((res:json())))["next"] == "/admin")
  assert(second:get("/"):text() == "handle-ada verified")
end

local function test_a_registration_needs_a_user()
  local rig = rig_of()
  local client = browser(rig.app)
  local res = post(client, "/register/begin")
  assert(res.status == 401, res.body)
  -- Begun for one user, it does not finish for another, nor for none.
  local key = key_new()
  local challenge = challenge_of(post(client, "/register/begin", nil, { ["X-User"] = "ada" }))
  local other = post(client, "/register/finish", registration(key, challenge), { ["X-User"] = "eve" })
  assert(other.status == 401, other.body)
  challenge = challenge_of(post(client, "/register/begin", nil, { ["X-User"] = "ada" }))
  local none = post(client, "/register/finish", registration(key, challenge))
  assert(none.status == 401, none.body)
  assert(#assert(rig.store:list("handle-ada")) == 0)
end

local function test_a_credential_id_registers_once()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local again = register(browser(rig.app), key, "eve")
  assert(again.status == 409, again.body)
  assert(#assert(rig.store:list("handle-eve")) == 0)
end

local function test_begin_excludes_the_user_s_passkeys()
  local rig = rig_of()
  local key = key_new()
  local client = browser(rig.app)
  assert(register(client, key, "ada").status == 201)
  local options = assert(Json.to_object((post(client, "/register/begin", nil, { ["X-User"] = "ada" }):json())))
  local excluded = assert(Json.to_array(options["excludeCredentials"]))
  assert(#excluded == 1 and assert(Json.to_object(excluded[1]))["id"] == Codec.base64url(key.id))
  local user = assert(Json.to_object(options["user"]))
  assert(user["id"] == Codec.base64url("handle-ada") and user["name"] == "ada")
end

local function test_a_challenge_is_used_once()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local client = browser(rig.app)
  local challenge = challenge_of(post(client, "/login/begin"))
  local answer = assertion(key, "handle-ada", challenge)
  assert(post(client, "/login/finish", answer).status == 200)
  local again = post(client, "/login/finish", answer)
  assert(again.status == 400, again.body)
  -- A finish with no begin, and one with another browser's challenge.
  local fresh = browser(rig.app)
  assert(post(fresh, "/login/finish", answer).status == 400)
  local theirs = challenge_of(post(browser(rig.app), "/login/begin"))
  local _ = post(fresh, "/login/begin")
  local res = post(fresh, "/login/finish", assertion(key, "handle-ada", theirs))
  assert(res.status == 400 and res.body:find("under way", 1, true) ~= nil, res.body)
end

--- A signed cookie cannot forget a challenge: a copy of the cookie from
--- before the login, with the answer captured, is refused all the same.
local function test_a_copied_cookie_does_not_replay_a_login()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local client = browser(rig.app)
  local challenge = challenge_of(post(client, "/login/begin"))
  local saved = assert(client.jar["__Host-session"])
  local answer = assertion(key, "handle-ada", challenge)
  assert(post(client, "/login/finish", answer).status == 200)
  local thief = browser(rig.app)
  local res = thief:post("/auth/passkey/login/finish", { json = answer, cookies = { ["__Host-session"] = saved } })
  assert(res.status == 400 and res.body:find("answered already", 1, true) ~= nil, res.body)
  assert(thief:get("/"):text() == "nobody")
  -- So with a registration's.
  local other = key_new()
  local registering = browser(rig.app)
  local headers = { ["X-User"] = "eve" }
  local begun = challenge_of(post(registering, "/register/begin", nil, headers))
  local kept = assert(registering.jar["__Host-session"])
  local made = registration(other, begun)
  assert(post(registering, "/register/finish", made, headers).status == 201)
  assert(rig.store:remove(other.id) == true)
  local again = browser(rig.app):post("/auth/passkey/register/finish", {
    json = made, headers = headers, cookies = { ["__Host-session"] = kept },
  })
  assert(again.status == 400 and again.body:find("answered already", 1, true) ~= nil, again.body)
end

--- A login waiting in autofill and one from a button, in one browser,
--- each finish.
local function test_logins_under_way_at_once()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local client = browser(rig.app)
  local first = challenge_of(post(client, "/login/begin"))
  local second = challenge_of(post(client, "/login/begin"))
  assert(post(client, "/login/finish", assertion(key, "handle-ada", first)).status == 200)
  assert(post(client, "/login/finish", assertion(key, "handle-ada", second)).status == 200)
  -- Past four, the oldest goes.
  local begun: mut {string} = {}
  for i = 1, 5 do
    begun[i] = challenge_of(post(client, "/login/begin"))
    rig.time.now = rig.time.now + 1
  end
  local gone = post(client, "/login/finish", assertion(key, "handle-ada", assert(begun[1])))
  assert(gone.status == 400, gone.body)
  assert(post(client, "/login/finish", assertion(key, "handle-ada", assert(begun[2]))).status == 200)
end

--- A challenge kept with a time after now, as a clock set back makes, is
--- not taken.
local function test_a_challenge_from_the_future_is_not_taken()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local client = browser(rig.app)
  local challenge = challenge_of(post(client, "/login/begin"))
  rig.time.now = rig.time.now - 10
  local res = post(client, "/login/finish", assertion(key, "handle-ada", challenge))
  assert(res.status == 400, res.body)
end

--- A store that fails, or that has lost the passkey by the time a login
--- keeps its counter.
local function failing(store: Web.PasskeyStore, fails: string, why: string): Web.PasskeyStore
  local function broken(): boolean, string return false, why end
  return {
    find = function(_: Web.PasskeyStore, id: string): Webauthn.Credential?, string
      if fails == "find" then return nil, why end
      return store:find(id)
    end,
    list = function(_: Web.PasskeyStore, handle: string): {Webauthn.Credential}?, string
      if fails == "list" then return nil, why end
      return store:list(handle)
    end,
    add = function(_: Web.PasskeyStore, c: Webauthn.Credential): boolean, string
      if fails == "add" then return broken() end
      return store:add(c)
    end,
    update = function(_: Web.PasskeyStore, c: Webauthn.Credential): boolean, string
      if fails == "update" then return broken() end
      return store:update(c)
    end,
    remove = function(_: Web.PasskeyStore, id: string): boolean, string return store:remove(id) end,
    spend = function(_: Web.PasskeyStore, c: string, lapses: integer, now: integer): boolean, string
      if fails == "spend" then return broken() end
      return store:spend(c, lapses, now)
    end,
  }
end

local function test_a_store_that_fails_is_a_500()
  local inner = assert(Web.passkey_store((assert(Sqlite.memory()))))
  local key = key_new()
  assert(register(browser(rig_of({ store = inner }).app), key, "ada").status == 201)
  for _, fails in ipairs({ "find", "list", "add", "update", "spend" }) do
    local rig = rig_of({ store = failing(inner, fails, "the disk is full") })
    local client = browser(rig.app)
    local res: Web.TestResponse
    if fails == "list" then
      res = post(client, "/register/begin", nil, { ["X-User"] = "eve" })
    elseif fails == "add" then
      res = register(client, key_new(), "eve")
    else
      key.count = key.count + 1
      res = log_in(client, key, "handle-ada")
    end
    assert(res.status == 500 and res.body:find("disk", 1, true) == nil, fails .. ": " .. res.body)
    assert(client:get("/"):text() == "nobody", fails)
  end
  -- A passkey removed between its lookup and its update logs nobody in.
  local rig = rig_of({ store = failing(inner, "update", "") })
  key.count = key.count + 1
  local client = browser(rig.app)
  local res = log_in(client, key, "handle-ada")
  assert(res.status == 401 and res.body:find("not registered", 1, true) ~= nil, res.body)
  assert(client:get("/"):text() == "nobody")
end

local function test_a_login_unverified_says_so()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local client = browser(rig.app)
  local challenge = challenge_of(post(client, "/login/begin"))
  assert(post(client, "/login/finish", assertion(key, "handle-ada", challenge, 0x19)).status == 200)
  assert(client:get("/"):text() == "handle-ada")
end

--- A request the router turned away is not answered here.
local function test_a_bad_host_is_not_answered()
  local rig = rig_of({ trusted_hosts = { "example.com" } })
  local client = browser(rig.app)
  local res = post(client, "/login/begin", nil, { Host = "evil.example" })
  assert(res.status == 400 and res.body:find("challenge", 1, true) == nil, res.body)
  assert(post(client, "/login/begin", nil, { Host = "example.com" }).status == 200)
end

local function test_a_handle_past_64_bytes_raises()
  local rig = rig_of({ handle = function(_: string): string return ("h"):rep(65) end })
  local client = browser(rig.app)
  Test.raises(function() post(client, "/register/begin", nil, { ["X-User"] = "ada" }) end, "1 to 64 bytes")
end

local function test_a_challenge_lapses()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local client = browser(rig.app)
  local challenge = challenge_of(post(client, "/login/begin"))
  rig.time.now = rig.time.now + 331
  local res = post(client, "/login/finish", assertion(key, "handle-ada", challenge))
  assert(res.status == 400, res.body)
end

local record Ticking
  mut on: boolean
end

--- An answer replayed, with a copy of the cookie from before the login,
--- at the last second its challenge could be answered: the store still
--- holds the challenge as spent, even where the checks take a second.
local function test_a_spent_challenge_outlives_its_answer()
  for _, slow in ipairs({ false, true }) do
    local inner = assert(Web.passkey_store((assert(Sqlite.memory()))))
    local time: Time = { now = 1700000000 }
    local ticking: Ticking = { on = false }
    -- A lookup that takes a second, when `ticking.on`.
    local store: Web.PasskeyStore = {
      find = function(_: Web.PasskeyStore, id: string): Webauthn.Credential?, string
        if ticking.on then time.now = time.now + 1 end
        return inner:find(id)
      end,
      list = function(_: Web.PasskeyStore, h: string): {Webauthn.Credential}?, string
        return inner:list(h)
      end,
      add = function(_: Web.PasskeyStore, c: Webauthn.Credential): boolean, string
        return inner:add(c)
      end,
      update = function(_: Web.PasskeyStore, c: Webauthn.Credential): boolean, string
        return inner:update(c)
      end,
      remove = function(_: Web.PasskeyStore, id: string): boolean, string
        return inner:remove(id)
      end,
      spend = function(_: Web.PasskeyStore, c: string, lapses: integer, now: integer): boolean, string
        return inner:spend(c, lapses, now)
      end,
    }
    local rig = rig_of({ store = store, time = time })
    local key = key_new()
    assert(register(browser(rig.app), key, "ada").status == 201)
    local client = browser(rig.app)
    local challenge = challenge_of(post(client, "/login/begin"))
    local begun = rig.time.now
    local saved = assert(client.jar["__Host-session"])
    local answer = assertion(key, "handle-ada", challenge)
    assert(post(client, "/login/finish", answer).status == 200)
    rig.time.now = begun + 330 - (if slow then 1 else 0 end)
    ticking.on = slow
    local thief = browser(rig.app)
    local res = thief:post("/auth/passkey/login/finish", { json = answer, cookies = { ["__Host-session"] = saved } })
    assert(res.status == 400, tostring(slow) .. ": " .. res.body)
    ticking.on = false
    assert(thief:get("/"):text() == "nobody")
  end
end

--- A handle that is the account's name is anybody's to name.
local function test_a_name_as_the_handle_raises()
  local rig = rig_of({ handle = function(name: string): string return name end })
  local client = browser(rig.app)
  Test.raises(function() post(client, "/register/begin", nil, { ["X-User"] = "ada" }) end, "name")
end

--- Removed, a passkey logs out the sessions it logged in; a store that
--- fails to say is a 500.
local function test_a_removed_passkey_logs_its_sessions_out()
  local rig = rig_of()
  local key = key_new()
  local client = browser(rig.app)
  assert(register(client, key, "ada").status == 201)
  assert(client:get("/"):text() == "handle-ada verified")
  assert(rig.store:remove(key.id) == true)
  assert(client:get("/"):text() == "nobody")
  local broken = rig_of({ store = failing(rig.store, "find", "the disk is full") })
  local other = browser(broken.app)
  assert(register(other, key_new(), "eve").status == 201)
  local res = other:get("/")
  assert(res.status == 500 and res.body:find("disk", 1, true) == nil, res.body)
end

local function test_a_passkey_not_kept_does_not_log_in()
  local rig = rig_of()
  local client = browser(rig.app)
  local res = log_in(client, key_new(), "handle-ada")
  assert(res.status == 401 and res.body:find("not registered", 1, true) ~= nil, res.body)
  assert(client:get("/"):text() == "nobody")
  -- Removed, a passkey that logged in logs in no more.
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  assert(rig.store:remove(key.id) == true)
  assert(rig.store:remove(key.id) == false)
  assert(log_in(browser(rig.app), key, "handle-ada").status == 401)
end

local function test_a_signature_that_does_not_check_does_not_log_in()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local forged: Key = { secret = assert(Rand.entropy(32)), id = key.id, count = 0 }
  local client = browser(rig.app)
  local res = log_in(client, forged, "handle-ada")
  assert(res.status == 401 and res.body:find("does not check", 1, true) ~= nil, res.body)
  assert(client:get("/"):text() == "nobody")
end

local function test_the_counter_is_kept()
  local rig = rig_of()
  local key = key_new()
  key.count = 5
  assert(register(browser(rig.app), key, "ada").status == 201)
  key.count = 6
  assert(log_in(browser(rig.app), key, "handle-ada").status == 200)
  assert(assert(rig.store:find(key.id)).sign_count == 6)
  -- A copy of the authenticator that has not moved on is refused.
  local res = log_in(browser(rig.app), key, "handle-ada")
  assert(res.status == 401 and res.body:find("cloned", 1, true) ~= nil, res.body)
end

local function test_a_login_regenerates_the_session()
  local sessions = assert(SessionSqlite.store((assert(Sqlite.memory()))))
  local rig = rig_of({ sessions = sessions })
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  local client = browser(rig.app)
  local _ = post(client, "/login/begin")
  local before = assert(client.jar["__Host-session"])
  local challenge = challenge_of(post(client, "/login/begin"))
  assert(post(client, "/login/finish", assertion(key, "handle-ada", challenge)).status == 200)
  local after = assert(client.jar["__Host-session"])
  assert(before ~= after)
  assert(client:get("/"):text() == "handle-ada verified")
  -- Both sessions are Ada's: the registration's and the login's.
  assert(#assert(SessionSqlite.list(sessions, rig.time.now, { subject = Codec.base64url("handle-ada") })) == 2)
end

local function test_logout_ends_the_session()
  local rig = rig_of()
  local key = key_new()
  local client = browser(rig.app)
  assert(register(client, key, "ada").status == 201)
  local res = post(client, "/logout")
  assert(res.status == 303 and res.redirect_location == "/", res.body)
  assert(client:get("/"):text() == "nobody")
end

local function test_next_stays_on_the_app()
  local rig = rig_of()
  local key = key_new()
  assert(register(browser(rig.app), key, "ada").status == 201)
  for _, case in ipairs({
      { "//evil.example", "/" }, { "https://evil.example/", "/" }, { "/a?b=c", "/a?b=c" },
      { "/" .. ("x"):rep(600), "/" },
  }) do
    local asked, want = assert(case[1]), assert(case[2])
    local res = log_in(browser(rig.app), key, "handle-ada", Url.escape(asked))
    assert(res.status == 200, res.body)
    local next_path = assert(Json.to_object((res:json())))["next"]
    assert(next_path == want, asked .. " went to " .. tostring(next_path))
  end
end

local function test_the_endpoints_take_json_posts_from_the_origin_alone()
  local rig = rig_of()
  local client = browser(rig.app)
  local other = post(client, "/login/begin", nil, { Origin = "https://evil.example" })
  assert(other.status == 403, other.body)
  assert(post(client, "/login/begin", nil, { Origin = ORIGIN }).status == 200)
  local form = client:post("/auth/passkey/login/begin", { form = { a = "b" } })
  assert(form.status == 415, form.body)
  local plain = client:post("/auth/passkey/login/finish", { body = "{}", content_type = "text/plain" })
  assert(plain.status == 415, plain.body)
  -- Logout takes a form's POST too, from the origin alone.
  local logout = client:post("/auth/passkey/logout", { form = { a = "b" } })
  assert(logout.status == 303 and logout.redirect_location == "/", logout.body)
  local forced = client:post("/auth/passkey/logout", { form = { a = "b" }, headers = { Origin = "https://evil.example" } })
  assert(forced.status == 403, forced.body)
  local got = client:get("/auth/passkey/login/begin")
  assert(got.status == 405 and got.headers["allow"] == "POST", got.body)
  local junk = client:post("/auth/passkey/login/finish", { body = "[1]", content_type = "application/json" })
  assert(junk.status == 400, junk.body)
  -- A path past the prefix it does not answer goes on to the app.
  assert(client:get("/auth/passkey/other").status == 404)
end

local function test_the_script_names_the_prefix()
  local rig = rig_of({ prefix = "/keys" })
  local client = browser(rig.app)
  local res = client:get("/keys/script.js")
  assert(res.status == 200 and (res.headers["content-type"] or ""):find("text/javascript", 1, true) == 1)
  assert(res.body:find('const prefix = "/keys";', 1, true) ~= nil, res.body)
  assert(res.body:find("PREFIX", 1, true) == nil)
  assert(client:head("/keys/script.js").status == 200)
  assert(client:get("/auth/passkey/script.js").status == 404)
  local key = key_new()
  local challenge = challenge_of(client:post("/keys/register/begin", { json = NONE, headers = { ["X-User"] = "ada" } }))
  local made = client:post("/keys/register/finish", { json = registration(key, challenge), headers = { ["X-User"] = "ada" } })
  assert(made.status == 201, made.body)
end

local function test_max_age_ends_a_login()
  local rig = rig_of({ max_age = 60 })
  local client = browser(rig.app)
  assert(register(client, key_new(), "ada").status == 201)
  assert(client:get("/"):text() == "handle-ada verified")
  rig.time.now = rig.time.now + 60
  assert(client:get("/"):text() == "nobody")
end

local function test_verification_can_be_required()
  local rig = rig_of({ require_verification = true })
  local key = key_new()
  local client = browser(rig.app)
  local options = assert(Json.to_object((post(client, "/register/begin", nil, { ["X-User"] = "ada" }):json())))
  local selection = assert(Json.to_object(options["authenticatorSelection"]))
  assert(selection["userVerification"] == "required")
  local challenge = challenge_of(post(client, "/register/begin", nil, { ["X-User"] = "ada" }))
  -- UP and no UV.
  local res = post(client, "/register/finish", registration(key, challenge, 0x59), { ["X-User"] = "ada" })
  assert(res.status == 400 and res.body:find("verified", 1, true) ~= nil, res.body)
  assert(register(client, key, "ada").status == 201)
  local login_challenge = challenge_of(post(client, "/login/begin"))
  local unverified = post(client, "/login/finish", assertion(key, "handle-ada", login_challenge, 0x19))
  assert(unverified.status == 401, unverified.body)
end

local function test_options_that_cannot_work_raise()
  local store = assert(Web.passkey_store((assert(Sqlite.memory()))))
  local function made(origin: string, rp_id: string, prefix?: string): function()
    return function()
      Web.passkeys{
        rp_id = rp_id, rp_name = "x", origin = origin, store = store, prefix = prefix,
        user = function(_: Web.Request): Web.PasskeyUser? return nil end,
      }
    end
  end
  Test.raises(made("http://example.com", RP), "https")
  Test.raises(made("https://example.com/app", RP), "https")
  Test.raises(made("https://example.org", RP), "rp_id")
  Test.raises(made("https://badexample.com", RP), "rp_id")
  Test.raises(made(ORIGIN, RP, "/auth/"), "prefix")
  Test.raises(made(ORIGIN, RP, "auth"), "prefix")
  Test.raises(made("https://Example.com", RP), "lowercase")
  Test.raises(function()
    Web.passkeys{
      rp_id = RP, rp_name = "x", origin = ORIGIN, store = store, after_logout = "https://evil.example/",
      user = function(_: Web.Request): Web.PasskeyUser? return nil end,
    }
  end, "after_logout")
  made("https://login.example.com", RP)()
  made("http://127.0.0.1:8080", "127.0.0.1")()
  Test.raises(function()
    local _ = Web.passkey_store((assert(Sqlite.memory())), { table = "a b" })
  end, "identifier")
end

--- The store is a table of its own, and survives a second store over it.
local function test_the_store_keeps_every_field()
  local db = assert(Sqlite.memory())
  local store = assert(Web.passkey_store(db, { table = "keys" }))
  local credential: Webauthn.Credential = {
    id = "\0\1id", user_handle = "\0h", public_key = "\xa1\1\2", alg = -8, sign_count = 3,
    user_verified = false, backup_eligible = true, backed_up = false, transports = { "usb", "nfc" },
    aaguid = ("\7"):rep(16),
  }
  assert(store:add(credential) == true)
  assert(store:add(credential) == false)
  credential.sign_count = 9
  credential.backed_up = true
  assert(store:update(credential))
  local again = assert(Web.passkey_store(db, { table = "keys" }))
  local found = assert(again:find("\0\1id"))
  assert(found.user_handle == "\0h" and found.public_key == "\xa1\1\2" and found.alg == -8)
  assert(found.sign_count == 9 and found.backed_up and found.backup_eligible and not found.user_verified)
  assert(found.transports[1] == "usb" and found.transports[2] == "nfc" and found.aaguid == ("\7"):rep(16))
  local missing, why = again:find("other")
  assert(missing == nil and why == "")
  -- A challenge is spent once, and forgotten once it lapses.
  assert(again:spend("c", 100, 50) == true)
  assert(again:spend("c", 100, 60) == false)
  assert(again:spend("c", 200, 100) == true)
  -- An update of a passkey not kept says so.
  assert(again:remove("\0\1id") == true)
  assert(again:update(credential) == false)
end
