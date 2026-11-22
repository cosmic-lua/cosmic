--- The OpenID Connect login of cosmic.web, against a stand-in provider:
--- a whole login, and each answer of the provider or the browser that
--- must not log anyone in.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Sign = require("cosmic.sign")
local Test = require("cosmic.test")
local Url = require("cosmic.url")
local Web = require("cosmic.web")

local ISSUER <const> = "https://id.example.com"
local CLIENT <const> = "my-app"
local REDIRECT <const> = "https://app.example.com/auth/callback"

--- A stand-in provider: what it was asked, and what it answers.
local record Provider
  --- The key its ID tokens are signed with now.
  mut signer: Jose.Signer
  --- The keys its `jwks_uri` publishes.
  mut published: {Jose.Signer}
  --- The claims of the next ID token, laid over the usual ones.
  mut claims: {string: Json.Value}
  --- The nonce the last authorization request asked for.
  mut nonce: string
  --- The PKCE challenge it asked for.
  mut challenge: string
  --- The last token request's form, by name, and its Authorization.
  mut form: {string: string}
  mut authorization?: string
  --- How many times each URL was fetched.
  fetched: mut {string: integer}
  --- The token endpoint's status (200).
  mut token_status: integer
  --- The issuer its discovery document names.
  mut discovered_issuer: string
  --- The scheme of the token endpoint its discovery document names.
  mut token_scheme: string
  --- Whether it says it names itself in an answer (RFC 9207).
  mut iss_supported: boolean
  --- The time, in seconds since the epoch.
  mut now: integer
  --- The lines the app's sink took.
  lines: mut {string}
end

--- A client acting as a browser on an https page, which sends the Secure
--- session cookie back.
local function browser(app: Web.App): Web.TestClient
  local client = Web.test_client(app)
  client.scheme = "https"
  return client
end

local function provider_new(): Provider
  local signer = Jose.signer("ES256", Sign.p256_secret(), "k1")
  return {
    signer = signer, published = { signer }, claims = {}, nonce = "", challenge = "", form = {},
    fetched = {}, token_status = 200, discovered_issuer = ISSUER, token_scheme = "https", iss_supported = false, now = 1700000000, lines = {},
  }
end

local function json_body(value: Json.Value): Http.Body
  return { status = 200, body = assert(Json.encode(value)), headers = { ["content-type"] = "application/json" } }
end

--- The provider's fetch.
local function fetch_of(p: Provider): Web.OidcFetch
  return function(method: string, url: string, opts: Http.Options): Http.Body?, string
    p.fetched[url] = (p.fetched[url] or 0) + 1
    -- A redirect would take the fetch to a URL no check has seen.
    if opts.follow ~= false then error("a fetch of " .. url .. " follows redirects") end
    if url == ISSUER .. "/.well-known/openid-configuration" then
      return json_body({
        issuer = p.discovered_issuer,
        authorization_endpoint = ISSUER .. "/authorize",
        token_endpoint = (ISSUER .. "/token"):gsub("^https", p.token_scheme),
        authorization_response_iss_parameter_supported = p.iss_supported,
        jwks_uri = ISSUER .. "/jwks",
        end_session_endpoint = ISSUER .. "/logout",
      }), ""
    end
    if url == ISSUER .. "/jwks" then
      local jwks: mut {Json.Value} = {}
      for i, s in ipairs(p.published) do jwks[i] = s.jwk end
      return json_body({ keys = Json.array(jwks) }), ""
    end
    if url == ISSUER .. "/token" and method == "POST" then
      local form = assert(Url.decode_query(opts.body or ""))
      local seen: mut {string: string} = {}
      for _, pair in ipairs(form.pairs) do seen[pair.name] = pair.value end
      p.form = seen
      p.authorization = (opts.headers or {})["Authorization"]
      if p.token_status ~= 200 then
        return { status = p.token_status, body = "{}", headers = {} }, ""
      end
      local claims: mut {string: Json.Value} = {
        iss = ISSUER, sub = "user-1", aud = CLIENT, exp = p.now + 300, iat = p.now, nonce = p.nonce,
        email = "ada@example.com", email_verified = true, name = "Ada", groups = Json.array({ "admins" }),
      }
      for name, value in pairs(p.claims) do claims[name] = value end
      return json_body({ id_token = Jose.sign(p.signer, claims), token_type = "Bearer", access_token = "a" }), ""
    end
    return nil, "no such URL: " .. url
  end
end

--- The options of [`Web.oidc`] a test changes.
local record Extra
  client_id?: string
  client_secret?: string
  scopes?: {string}
  params?: {string: string}
  keep_claims?: {string}
  provider_logout?: string
  max_age?: integer
  algs?: {Jose.Alg}
  store?: Session.Store
end

--- An app logging in at `p`, with the options `extra` names.
--- `/` says who is logged in; `/admin` needs a login.
local function app_of(p: Provider, extra?: Extra): Web.App
  local e: Extra = extra or {}
  local opts: Web.OidcOptions = {
    issuer = ISSUER, client_id = e.client_id or CLIENT, redirect_uri = REDIRECT,
    client_secret = e.client_secret, scopes = e.scopes, params = e.params, keep_claims = e.keep_claims,
    provider_logout = e.provider_logout, max_age = e.max_age, algs = e.algs,
    fetch = fetch_of(p), now = function(): integer return p.now end,
  }
  return Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local who = Web.oidc_identity(req)
        if who == nil then return Web.text("nobody") end
        local groups = who.claims["groups"]
        local shown = if groups ~= nil then " " .. (Json.encode(groups) or "") else "" end
        return Web.text(who.subject .. " " .. (who.email or "") .. " " .. (who.name or "") .. shown)
      end),
      Web.get("/admin", function(_: Web.Request): Web.Response
        return Web.text("the switches")
      end, { middleware = { Web.require_login() } }),
    },
    middleware = {
      Session.middleware{ store = e.store or SessionCookie.store{ keys = { Secret.generate() } } },
      Web.oidc(opts),
    },
    sink = { line = function(_: Web.Sink, line: string) p.lines[#p.lines + 1] = line end },
  }
end

--- The query of the URL `location`.
local function query_of(location: string): Url.Query
  local parts = assert(Url.parse(location))
  return (assert(Url.decode_query(parts.query or "")))
end

--- Starts a login at `client`, notes what the provider was asked, and
--- answers the state.
local function start(client: Web.TestClient, p: Provider, next_path?: string): string
  local res = client:get("/auth/login" .. (if next_path ~= nil then "?next=" .. Url.escape(next_path) else "" end))
  assert(res.status == 302, res.status)
  local location = assert(res.redirect_location)
  assert(location:sub(1, #ISSUER + 10) == ISSUER .. "/authorize", location)
  local query = query_of(location)
  p.nonce = assert(Url.query_first(query, "nonce"))
  p.challenge = assert(Url.query_first(query, "code_challenge"))
  return assert(Url.query_first(query, "state"))
end

local function callback(client: Web.TestClient, state: string, code?: string): Web.TestResponse
  return client:get("/auth/callback", { query = { state = state, code = code or "the-code" } })
end

local function test_a_whole_login()
  local p = provider_new()
  local client = browser(app_of(p))
  assert(client:get("/"):text() == "nobody")
  local state = start(client, p, "/admin")
  local res = callback(client, state)
  assert(res.status == 303 and res.redirect_location == "/admin", res.status)
  assert(client:get("/"):text() == 'user-1 ada@example.com Ada')
  assert(client:get("/admin"):text() == "the switches")
  -- The token request proves the login with the verifier of its challenge.
  assert(p.form["grant_type"] == "authorization_code" and p.form["code"] == "the-code")
  assert(p.form["redirect_uri"] == REDIRECT and p.form["client_id"] == CLIENT)
  assert(Codec.base64url(Hash.sha256(assert(p.form["code_verifier"]))) == p.challenge)
  assert(p.authorization == nil)
end

local function test_the_authorization_request()
  local p = provider_new()
  local client = browser(app_of(p, {
    scopes = { "email" },
    params = { prompt = "select_account" },
  }))
  local query = query_of(assert(client:get("/auth/login").redirect_location))
  assert(Url.query_first(query, "response_type") == "code")
  assert(Url.query_first(query, "client_id") == CLIENT)
  assert(Url.query_first(query, "redirect_uri") == REDIRECT)
  assert(Url.query_first(query, "scope") == "openid email")
  assert(Url.query_first(query, "code_challenge_method") == "S256")
  assert(Url.query_first(query, "prompt") == "select_account")
  assert(#assert(Url.query_first(query, "state")) == 43 and #assert(Url.query_first(query, "nonce")) == 43)
end

local function test_a_confidential_client_authenticates_with_basic()
  local p = provider_new()
  local client = browser(app_of(p, {
    client_id = "id:x", client_secret = "s e+cret",
  }))
  p.claims = { aud = "id:x" }
  local res = callback(client, start(client, p))
  assert(res.status == 303, res.status)
  assert(p.authorization == "Basic " .. Codec.base64("id%3Ax:s+e%2Bcret"), p.authorization)
  assert(p.form["client_id"] == nil)
end

local function test_kept_claims()
  local p = provider_new()
  local client = browser(app_of(p, {
    keep_claims = { "groups" },
  }))
  callback(client, start(client, p))
  assert(client:get("/"):text() == 'user-1 ada@example.com Ada ["admins"]')
end

--- A callback with a state no login of this browser made is refused: it
--- is how a login planted from another browser, or an answer replayed,
--- is told apart.
local function test_a_state_of_no_login_is_refused()
  local p = provider_new()
  local client = browser(app_of(p))
  local state = start(client, p)
  assert(callback(client, "forged").status == 400)
  local other = browser(app_of(p))
  assert(callback(other, state).status == 400)
  assert(callback(client, state).status == 303)
  -- A state is used once.
  assert(callback(client, state).status == 400)
end

local function test_a_login_under_way_lapses()
  local p = provider_new()
  local client = browser(app_of(p))
  local state = start(client, p)
  p.now = p.now + 601
  assert(callback(client, state).status == 400)
end

local function test_tabs_each_log_in()
  local p = provider_new()
  local client = browser(app_of(p))
  local first = start(client, p)
  local first_nonce = p.nonce
  start(client, p)
  p.nonce = first_nonce
  assert(callback(client, first).status == 303)
end

local function test_id_tokens_that_are_refused()
  local function refused(claims: {string: Json.Value}, says: string)
    local p = provider_new()
    local client = browser(app_of(p))
    local state = start(client, p)
    p.claims = claims
    local res = callback(client, state)
    assert(res.status == 401 and res.body:find(says, 1, true) ~= nil, res.body)
    assert(client:get("/"):text() == "nobody")
  end
  refused({ nonce = "another" }, "not of this login")
  refused({ aud = "another-app" }, "audience")
  refused({ iss = "https://evil.example.com" }, "issuer")
  refused({ exp = 1600000000 }, "expired")
  refused({ aud = Json.array({ CLIENT, "other" }) }, "another party")
  refused({ azp = "other" }, "another party")
end

local function test_a_token_from_a_key_the_provider_does_not_publish_is_refused()
  local p = provider_new()
  local client = browser(app_of(p))
  local state = start(client, p)
  p.signer = Jose.signer("ES256", Sign.p256_secret(), "k1")
  local res = callback(client, state)
  assert(res.status == 401 and res.body:find("does not check", 1, true) ~= nil, res.body)
end

--- A provider that rolls its key signs with one the app has not fetched:
--- the keys are fetched again, once, and the login goes on.
local function test_a_rolled_key_is_fetched()
  local p = provider_new()
  local client = browser(app_of(p))
  callback(client, start(client, p))
  assert(p.fetched[ISSUER .. "/jwks"] == 1)
  local rolled = Jose.signer("ES256", Sign.p256_secret(), "k2")
  p.signer, p.published = rolled, { rolled }
  p.now = p.now + 61
  local res = callback(client, start(client, p))
  assert(res.status == 303, res.body)
  assert(p.fetched[ISSUER .. "/jwks"] == 2)
  assert(p.fetched[ISSUER .. "/.well-known/openid-configuration"] == 1)
end

--- Tokens under a key nobody publishes fetch the keys at most once a
--- minute.
local function test_unknown_keys_fetch_at_most_once_a_minute()
  local p = provider_new()
  local client = browser(app_of(p))
  callback(client, start(client, p))
  p.signer = Jose.signer("ES256", Sign.p256_secret(), "nobody's")
  for _ = 1, 3 do assert(callback(client, start(client, p)).status == 401) end
  assert(p.fetched[ISSUER .. "/jwks"] == 1)
end

local function test_the_provider_refusing_the_login()
  local p = provider_new()
  local client = browser(app_of(p))
  local state = start(client, p)
  local res = client:get("/auth/callback", { query = { state = state, error = "access_denied" } })
  assert(res.status == 401 and res.body:find("access_denied", 1, true) ~= nil, res.body)
  local again = start(client, p)
  p.token_status = 400
  assert(callback(client, again).status == 401)
end

local function test_an_answer_from_another_issuer_is_refused()
  local p = provider_new()
  local client = browser(app_of(p))
  local state = start(client, p)
  local res = client:get("/auth/callback", { query = { state = state, code = "c", iss = "https://evil.example.com" } })
  assert(res.status == 400, res.status)
end

local function test_discovery_of_another_issuer_is_a_503()
  local p = provider_new()
  p.discovered_issuer = "https://evil.example.com"
  local client = browser(app_of(p))
  local res = client:get("/auth/login")
  assert(res.status == 503, res.status)
  assert(#p.lines == 1 and p.lines[1]:find("another issuer", 1, true) ~= nil)
end

local function test_next_is_a_local_path()
  local p = provider_new()
  local client = browser(app_of(p))
  local res = callback(client, start(client, p, "//evil.example.com/"))
  assert(res.redirect_location == "/", res.redirect_location)
end

local function test_require_login()
  local p = provider_new()
  local client = browser(app_of(p))
  local page = client:get("/admin?x=1", { headers = { Accept = "text/html" } })
  assert(page.status == 303 and page.redirect_location == "/auth/login?next=%2Fadmin%3Fx%3D1", page.redirect_location)
  assert(client:get("/admin", { headers = { Accept = "application/json" } }).status == 401)
end

local function test_logout()
  local p = provider_new()
  local client = browser(app_of(p))
  callback(client, start(client, p))
  assert(client:get("/auth/logout").status == 405)
  assert(client:get("/"):text() ~= "nobody")
  local res = client:request("POST", "/auth/logout")
  assert(res.status == 303 and res.redirect_location == "/", res.redirect_location)
  assert(client:get("/"):text() == "nobody")
end

local function test_logout_through_the_provider()
  local p = provider_new()
  local client = browser(app_of(p, {
    provider_logout = "https://app.example.com/",
  }))
  callback(client, start(client, p))
  local res = client:request("POST", "/auth/logout")
  local location = assert(res.redirect_location)
  assert(location:sub(1, #ISSUER + 7) == ISSUER .. "/logout", location)
  assert(Url.query_first(query_of(location), "post_logout_redirect_uri") == "https://app.example.com/")
end

local function test_max_age()
  local p = provider_new()
  local client = browser(app_of(p, { max_age = 100 }))
  callback(client, start(client, p))
  assert(client:get("/"):text() ~= "nobody")
  p.now = p.now + 100
  assert(client:get("/"):text() == "nobody")
end

local function test_options_that_cannot_work_raise()
  local function raises(opts: Web.OidcOptions, says: string)
    Test.raises(function() Web.oidc(opts) end, says)
  end
  raises({ issuer = "http://id.example.com", client_id = CLIENT, redirect_uri = REDIRECT }, "issuer")
  raises({ issuer = ISSUER, client_id = CLIENT, redirect_uri = "http://app.example.com/cb" }, "redirect_uri")
  raises({ issuer = ISSUER, client_id = "", redirect_uri = REDIRECT }, "client_id")
  raises({ issuer = ISSUER, client_id = CLIENT, redirect_uri = REDIRECT, params = { state = "x" } }, "state")
  raises({ issuer = ISSUER, client_id = CLIENT, redirect_uri = REDIRECT, login_path = "//x" }, "login_path")
  raises({ issuer = ISSUER, client_id = CLIENT, redirect_uri = REDIRECT, max_age = 0 }, "max_age")
  -- The loopback may be served over http, as a test's provider is.
  local made = Web.oidc({ issuer = "http://127.0.0.1:8080", client_id = CLIENT, redirect_uri = "http://localhost:3000/cb" })
  assert(type(made) == "function")
end

--- A login gives the session a new id, so a session cookie planted
--- before it (fixation) does not carry the login.
local function test_a_login_regenerates_the_session()
  local p = provider_new()
  local store = assert(SessionSqlite.store((assert(Sqlite.memory()))))
  local app = app_of(p, { store = store })
  local client = browser(app)
  local state = start(client, p)
  local before = assert(client.jar["__Host-session"])
  assert(callback(client, state).status == 303)
  local after = assert(client.jar["__Host-session"])
  assert(after ~= before)
  assert(client:get("/"):text() == "user-1 ada@example.com Ada")
  local planted = browser(app)
  assert(planted:get("/", { cookies = { ["__Host-session"] = before } }):text() == "nobody")
end

local function test_a_fifth_login_drops_the_oldest()
  local p = provider_new()
  local client = browser(app_of(p))
  local first = start(client, p)
  p.now = p.now + 1
  local second = start(client, p)
  local second_nonce = p.nonce
  for _ = 1, 3 do
    p.now = p.now + 1
    start(client, p)
  end
  assert(callback(client, first).status == 400)
  p.nonce = second_nonce
  assert(callback(client, second).status == 303)
end

local function test_a_long_next_goes_home()
  local p = provider_new()
  local client = browser(app_of(p))
  local res = callback(client, start(client, p, "/" .. ("a"):rep(600)))
  assert(res.redirect_location == "/", res.redirect_location)
end

local function test_an_endpoint_that_is_not_https_is_refused()
  local p = provider_new()
  p.token_scheme = "http"
  local client = browser(app_of(p))
  assert(client:get("/auth/login").status == 503)
  assert(#p.lines == 1 and p.lines[1]:find("not https", 1, true) ~= nil, p.lines[1])
end

--- A provider that says it names itself must: an answer without `iss`
--- may be another provider's (a mix-up).
local function test_iss_is_required_where_the_provider_sends_it()
  local p = provider_new()
  p.iss_supported = true
  local client = browser(app_of(p))
  local state = start(client, p)
  assert(callback(client, state).status == 400)
  local again = start(client, p)
  assert(client:get("/auth/callback", { query = { state = again, code = "c", iss = ISSUER } }).status == 303)
end

local function test_head_uses_no_state()
  local p = provider_new()
  local client = browser(app_of(p))
  local state = start(client, p)
  client:head("/auth/callback?state=" .. Url.escape(state) .. "&code=c")
  assert(p.fetched[ISSUER .. "/token"] == nil)
  assert(callback(client, state).status == 303)
end

local function test_logout_answers_405_with_allow()
  local p = provider_new()
  local client = browser(app_of(p))
  local res = client:get("/auth/logout")
  assert(res.status == 405 and res.headers["allow"] == "POST")
end

--- An app that has served no login yet still ends the provider's.
local function test_logout_through_the_provider_discovers_it()
  local p = provider_new()
  local client = browser(app_of(p, { provider_logout = "https://app.example.com/" }))
  local res = client:request("POST", "/auth/logout")
  local location = assert(res.redirect_location)
  assert(location:sub(1, #ISSUER + 7) == ISSUER .. "/logout", location)
end

local function test_algs_limits_the_id_token()
  local p = provider_new()
  local client = browser(app_of(p, { algs = { "RS256" } }))
  local res = callback(client, start(client, p))
  assert(res.status == 401 and res.body:find("not allowed", 1, true) ~= nil, res.body)
end
