--- Login with an OpenID Connect provider, for an app served to the
--- internet: the authorization code flow with PKCE (RFC 7636), the ID
--- token checked against the provider's published keys, and who logged
--- in kept in the app's session.
---
---     local Session = require("cosmic.web.session")
---     local SessionCookie = require("cosmic.web.session.cookie")
---     local Web = require("cosmic.web")
---
---     local app = Web.app{
---       routes = {
---         Web.get("/", function(req: Web.Request): Web.Response
---           local who = Web.who(req).oidc
---           if who == nil then return Web.html('<a href="/auth/login">log in</a>') end
---           return Web.text("hello " .. (who.name or who.subject))
---         end),
---         Web.get("/admin", function(_: Web.Request): Web.Response
---           return Web.text("the switches")
---         end, { middleware = { Web.require_login() } }),
---       },
---       middleware = {
---         Session.middleware{ store = SessionCookie.store{ keys = keys } },
---         Web.oidc{
---           issuer = "https://accounts.example.com",
---           client_id = "my-app",
---           client_secret = secret,
---           redirect_uri = "https://app.example.com/auth/callback",
---         },
---       },
---     }
---
--- The middleware handles three paths itself, before the routes:
---
--- - `GET /auth/login?next=/admin` sends the browser to the provider,
---   with a new `state`, `nonce` and PKCE challenge kept in the session.
---   A request for it from another site that is not a navigation of the
---   browser's window (an image, a frame, a script, a fetch) is refused
---   403, so a page cannot push the logins under way out of the session;
--- - the path of `redirect_uri` takes the provider's response, trades the
---   code for tokens at the token endpoint, checks the ID token, and
---   keeps who logged in in a regenerated session, then sends the browser
---   on to `next`;
--- - `POST /auth/logout` ends the session, and the login at the provider
---   too where `provider_logout` is given. A POST from another site is
---   refused 403, as [`cosmic.web.csrf`]'s Origin layer refuses one, with
---   `Sec-Fetch-Site: same-site` refused too. Behind a proxy that ends
---   TLS, set `trusted_proxy`, or every logout from a browser is refused.
---
--- Every other request goes on to the app with the identity the session
--- holds, which [`Web.who`] reads and [`Web.require_login`]
--- requires. [`cosmic.web.session`]'s middleware must run outside this
--- one: the session is where a login is kept.
---
--- The provider is found by OpenID Connect Discovery from `issuer` on
--- the first login or logout, and its keys from its `jwks_uri`. What
--- discovery finds is kept while the process runs; the keys are kept an
--- hour, and fetched again, at most once a minute, when a token does
--- not check against them, as one signed by a key the provider has just
--- rolled to does not. A fetch follows no redirect and waits at most 5
--- seconds, through the server's run, so other requests are served
--- meanwhile. Where the provider cannot be reached the request gets 503,
--- and why is written to the app's sink. A discovery or fetch of the keys
--- that fails is not tried again for 10 seconds: the requests in between
--- get 503 at once. Since a stranger can start a trade of a code for
--- tokens with two requests, the trades are limited: one client address
--- may start 30 a minute, have 10 fail or be refused in a minute and have
--- 10 under way, and all clients together may have 600 fail or be refused
--- in a minute. Past that the callback responds 429, and the login under
--- way can come back to it. Behind a proxy, every client has the proxy's
--- address unless the app sets `trusted_proxy`.
---
--- A login under way is kept in the session too: its `state`, `nonce`
--- and PKCE verifier. The signed cookie store
--- ([`cosmic.web.session.cookie`]) signs what it keeps but does not hide
--- it, so the browser can read them, which a code flow allows: the code
--- is the provider's to give and is used once. That store cannot revoke
--- a cookie either, so a logout there ends the session in the browser
--- alone; the SQLite store ([`cosmic.web.session.sqlite`]) ends it on the
--- server.
---
--- A token is believed only as [`Jose.verify_jwt`] checks it, from the
--- issuer configured, for this client, with the `nonce` of the login
--- that asked for it. `redirect_uri`, `issuer` and the provider's
--- endpoints are https, except on the loopback, where a test serves.
--- @public

local Attempts = require("cosmic.web.attempts")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Csrf = require("cosmic.web.csrf")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Loopback = require("cosmic.internal.loopback")
local Rand = require("cosmic.rand")
local Identities = require("cosmic.web.identity")
local Request = require("cosmic.web.request")
local Response = require("cosmic.web.response")
local Session = require("cosmic.web.session")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")

local record Oidc
  --- Who logged in: see [`cosmic.web.identity.Oidc`].
  type Identity = Identities.Oidc

  --- What discovery finds of a provider (OpenID Connect Discovery 1.0
  --- section 3), or what an app gives where its provider has none.
  record Provider
    --- The issuer, exactly as its tokens name it.
    issuer: string
    --- Where the browser is sent to log in.
    authorization_endpoint: string
    --- Where a code is traded for tokens.
    token_endpoint: string
    --- Where the provider's signing keys are.
    jwks_uri: string
    --- Where a login at the provider is ended, when it has one.
    end_session_endpoint?: string
    --- Whether the provider names itself in its response to a login, as
    --- `iss` (RFC 9207): then a response that does not is refused.
    iss_in_answer?: boolean
  end

  --- Sends a request: [`Http.request`] by default. A test stands in for
  --- the provider with one of its own.
  type Fetch = function(method: string, url: string, opts: Http.Options): Http.Body?, string

  --- What [`Web.oidc`] takes.
  record Options
    --- The provider's issuer URL, as its tokens name it.
    issuer: string
    --- The app's client id at the provider.
    client_id: string
    --- The app's client secret, sent with HTTP basic authentication
    --- (`client_secret_basic`). Nil for a public client, which proves
    --- itself with PKCE alone.
    client_secret?: string
    --- The absolute URL the provider sends the browser back to, as it
    --- is registered there. The middleware handles its path.
    redirect_uri: string
    --- The scopes asked for: `openid email profile` by default.
    --- `openid` is always asked for.
    scopes?: {string}
    --- The path that starts a login ("/auth/login").
    login_path?: string
    --- The path that ends one ("/auth/logout"), for a POST.
    logout_path?: string
    --- Where logout sends the browser after ("/").
    after_logout?: string
    --- The absolute URL the provider sends the browser to after it ends
    --- its own login, registered there as a post-logout redirect URI.
    --- Given, and where the provider has an `end_session_endpoint`,
    --- logout goes through the provider; else it ends the app's session
    --- alone.
    provider_logout?: string
    --- Claims of the ID token to keep in [`cosmic.web.identity.Oidc.claims`]
    --- beside the standard ones (`groups`, say). Each is kept in the
    --- session: under the signed cookie store, all of the session must
    --- fit in its cookie, and a login whose claims do not is a 500.
    keep_claims?: {string}
    --- How long a login counts, in seconds; nil for as long as the
    --- session.
    max_age?: integer
    --- More parameters of the authorization request (`prompt`,
    --- `login_hint`, `hd`, ...). Those the flow sets itself are refused.
    params?: {string: string}
    --- The algorithms the ID token may be signed with: all of
    --- [`Jose.Alg`]'s by default.
    algs?: {Jose.Alg}
    --- The provider's metadata, given where it serves no discovery:
    --- then nothing is discovered.
    provider?: Provider
    --- Sends a request: see [`Oidc.Fetch`].
    fetch?: Fetch
    --- The time in seconds since the epoch, for a test.
    now?: function(): integer
  end
end

--- What a check of an ID token found.
local record Verdict
  --- The token's claims, where it is one to believe.
  claims?: {string: Json.Value}
  --- Why it is not.
  reason: string
  --- Whether that is because the provider could not be reached.
  down: boolean
end

--- The key a request's identity is kept under.
local IDENTITY: Types.Key<Oidc.Identity> = Identities.OIDC
--- The key the login path is kept under, for [`Oidc.require_login`].
local LOGIN: Types.Key<string> = Request.key("oidc.login")

--- The session key of who logged in.
local KEPT <const> = "_oidc"
--- The session key of the logins under way, by state.
local PENDING <const> = "_oidc_pending"
--- The most logins under way a session holds, one a tab: the oldest goes.
--- With `MAX_NEXT`, it keeps them within the signed cookie's 3800 bytes.
local MAX_PENDING <const> = 4
--- The longest `next` a login keeps, in bytes; a longer one goes to "/".
local MAX_NEXT <const> = 512
--- How long a login under way may take, in seconds.
local PENDING_SECONDS <const> = 600
--- How long a request to the provider may take.
local REQUEST_TIMEOUT <const> = 5 * 1000000000
--- How long a failed discovery or fetch of the keys is kept and given
--- again without asking the provider, in seconds: while the provider is
--- down or slow, a stream of requests costs one fetch a period.
local RETRY_SECONDS <const> = 10
--- The trades of a code for tokens one client address may start in
--- `EXCHANGE_WINDOW`.
local EXCHANGES_PER_ADDRESS <const> = 30
--- The trades one client address may have fail or be refused in
--- `EXCHANGE_WINDOW`, and may have under way at once.
local FAILURES_PER_ADDRESS <const> = 10
--- The trades all clients together may have fail or be refused in
--- `EXCHANGE_WINDOW`. A success counts only for its address, so that one
--- address cannot use up what every other has.
local FAILURES <const> = 600
local EXCHANGE_WINDOW <const> = Clock.minutes(1)
--- How long the provider's keys are kept before they are fetched again.
local KEYS_SECONDS <const> = 3600
--- How soon after a fetch of the keys a token with a key not yet seen
--- may fetch them again: a stream of forged tokens costs one fetch a
--- period.
local REFETCH_SECONDS <const> = 60

--- The claims an identity always keeps.
local STANDARD: {string} = {
  "iss", "sub", "email", "email_verified", "name", "preferred_username", "picture", "auth_time",
}

--- The parameters of the authorization request the flow sets itself.
local OWN_PARAMS: {string: boolean} = {
  response_type = true, client_id = true, redirect_uri = true, scope = true, state = true,
  nonce = true, code_challenge = true, code_challenge_method = true,
}

--- Whether `url` is https, or http to the loopback.
local function secure_url(url: string): boolean
  local parts, _ = Url.parse(url)
  if parts == nil then return false end
  if parts.scheme == "https" then return true end
  local host = parts.host
  return parts.scheme == "http" and (host == "localhost" or host == "::1" or Loopback.ipv4(host))
end

--- The member `name` of `object` when it is a string.
local function text(object: {string: Json.Value}, name: string): string?
  local value = object[name]
  if value is string then return value end
  return nil
end

--- `said`, the provider's words passed on by the browser, fit for a
--- problem's detail: RFC 6749 allows printable ASCII alone in `error`
--- and `error_description`, so any other byte becomes "?". At most 200
--- bytes are kept.
local function plain(said: string): string
  return (said:sub(1, 200):gsub("[^ -~]", "?"))
end

--- Whether `req` is a request from another site that is not a navigation
--- of the browser's window: one a page makes without the user (an
--- image, a frame, a script, a fetch). A link followed from another site
--- is a navigation of a document. A browser that sends no
--- `Sec-Fetch-Site` is not told apart; one that sends it without
--- `Sec-Fetch-Mode` and `Sec-Fetch-Dest` is refused.
local function cross_site_subresource(req: Types.Request): boolean
  local site = req.headers["sec-fetch-site"]
  if site == nil then return false end
  site = site:lower()
  if site == "same-origin" or site == "none" then return false end
  local mode = (req.headers["sec-fetch-mode"] or ""):lower()
  local dest = (req.headers["sec-fetch-dest"] or ""):lower()
  return mode ~= "navigate" or dest ~= "document"
end

--- 32 random bytes, base64url: a state, a nonce or a PKCE verifier.
local function random_token(): string
  return Codec.base64url((assert(Rand.entropy(32))))
end

--- The provider `doc`, a discovery document, describes, checked
--- against the issuer asked for: nil and why for one that names another
--- issuer (Discovery section 4.3) or lacks an endpoint, or an endpoint
--- that is not https.
local function read_provider(doc: {string: Json.Value}, issuer: string): Oidc.Provider?, string
  if text(doc, "issuer") ~= issuer then
    return nil, "the discovery document names another issuer"
  end
  local found: mut {string: string} = {}
  for _, name in ipairs({ "authorization_endpoint", "token_endpoint", "jwks_uri" }) do
    local url = text(doc, name)
    if url == nil then return nil, "the discovery document has no " .. name end
    if not secure_url(url) then return nil, ("the provider's %s is not https"):format(name) end
    found[name] = url
  end
  local ending = text(doc, "end_session_endpoint")
  if ending ~= nil and not secure_url(ending) then ending = nil end
  return {
    issuer = issuer,
    authorization_endpoint = assert(found["authorization_endpoint"]),
    token_endpoint = assert(found["token_endpoint"]),
    jwks_uri = assert(found["jwks_uri"]),
    end_session_endpoint = ending,
    iss_in_answer = doc["authorization_response_iss_parameter_supported"] == true,
  }, ""
end

--- `url` with the query `pairs` added.
local function with_query(url: string, pairs_: {Url.Pair}): string
  local joint = if url:find("?", 1, true) then "&" else "?" end
  return url .. joint .. Url.encode_query(pairs_)
end

--- The identity a session keeps, or nil where it keeps none or one
--- that is not whole.
local function kept_identity(value: Json.Value?): Oidc.Identity?
  if value == nil then return nil end
  local object, _ = Json.to_object(value)
  if object == nil then return nil end
  local claims_value = object["claims"]
  local at = object["at"]
  if claims_value == nil or not at is integer then return nil end
  local claims, _ = Json.to_object(claims_value)
  if claims == nil then return nil end
  local iss, sub = text(claims, "iss"), text(claims, "sub")
  if iss == nil or sub == nil then return nil end
  return {
    issuer = iss,
    subject = sub,
    email = text(claims, "email"),
    email_verified = claims["email_verified"] == true,
    name = text(claims, "name"),
    preferred_username = text(claims, "preferred_username"),
    picture_url = text(claims, "picture"),
    logged_in_at = at,
    claims = claims,
  }
end

--- A path option `value`, `default` when nil, checked to be a local path.
local function path_option(value: string?, default: string, name: string): string
  local path = value or default
  if not Response.local_path(path) or path:find("?", 1, true) ~= nil then
    error(("web: oidc: %s must be a local path with no query"):format(name), 3)
  end
  return path
end

--- The middleware of a login with an OpenID Connect provider: see the
--- module's description. Raises, naming it, for an option that cannot
--- work, before the app serves.
---
---     local auth = Web.oidc{ issuer = issuer, client_id = id, redirect_uri = uri }
function Oidc.middleware(opts: Oidc.Options): Types.Middleware
  if not secure_url(opts.issuer) then error("web: oidc: issuer must be an https URL", 2) end
  if opts.client_id == "" then error("web: oidc: client_id must not be empty", 2) end
  if not secure_url(opts.redirect_uri) then
    error("web: oidc: redirect_uri must be an https URL", 2)
  end
  local redirect = assert(Url.parse(opts.redirect_uri))
  local callback_path = if redirect.path == "" then "/" else redirect.path end
  local login_path = path_option(opts.login_path, "/auth/login", "login_path")
  local logout_path = path_option(opts.logout_path, "/auth/logout", "logout_path")
  local after_logout = opts.after_logout or "/"
  if not Response.local_path(after_logout) then
    error("web: oidc: after_logout must be a local path", 2)
  end
  local provider_logout = opts.provider_logout
  if provider_logout ~= nil and not secure_url(provider_logout) then
    error("web: oidc: provider_logout must be an https URL", 2)
  end
  local max_age = opts.max_age
  if max_age ~= nil and (math.type(max_age) ~= "integer" or max_age < 1) then
    error("web: oidc: max_age is a number of seconds, at least 1", 2)
  end
  for name in pairs(opts.params or {}) do
    if OWN_PARAMS[name] == true then
      error(("web: oidc: params must not set %s, which the flow sets"):format(name), 2)
    end
  end
  local scopes: mut {string} = { "openid" }
  for _, scope in ipairs(opts.scopes or { "email", "profile" }) do
    if scope ~= "openid" then scopes[#scopes + 1] = scope end
  end
  local scope = table.concat(scopes, " ")
  local keep: mut {string} = {}
  for _, name in ipairs(STANDARD) do keep[#keep + 1] = name end
  for _, name in ipairs(opts.keep_claims or {}) do keep[#keep + 1] = name end
  local fetch: Oidc.Fetch = opts.fetch or function(method: string, url: string, o: Http.Options): Http.Body?, string
    local body, why = Http.request(method, url, o)
    if body == nil then return nil, tostring(why) end
    return body, ""
  end
  local now = opts.now or function(): integer return Clock.now_ns() // 1000000000 end
  -- A test's clock moves the limits too.
  local now_ns: (function(): integer)? = nil
  if opts.now ~= nil then now_ns = function(): integer return now() * 1000000000 end end
  local by_address = Attempts.limiter{ limit = EXCHANGES_PER_ADDRESS, window_ns = EXCHANGE_WINDOW, now_ns = now_ns }
  local failed_by_address = Attempts.limiter{ limit = FAILURES_PER_ADDRESS, window_ns = EXCHANGE_WINDOW, now_ns = now_ns }
  local everyone = Attempts.limiter{ limit = FAILURES, window_ns = EXCHANGE_WINDOW, now_ns = now_ns }
  -- The trades under way, by client address.
  local trading: mut {string: integer} = {}

  local given = opts.provider
  if given ~= nil and given.issuer ~= opts.issuer then
    error("web: oidc: provider.issuer must be the issuer", 2)
  end
  local provider: Oidc.Provider? = given
  local keys: {Jose.Jwk}? = nil
  local keys_at = 0
  local discovery_failure: string? = nil
  local discovery_failed_at = 0
  local keys_failure: string? = nil
  local keys_failed_at = 0

  --- `failure` when it is from less than `RETRY_SECONDS` before `t`.
  local function recent(failure: string?, at: integer, t: integer): string?
    if failure ~= nil and t >= at and t - at < RETRY_SECONDS then return failure end
    return nil
  end

  --- The provider, asked of its discovery document.
  local function discover(): Oidc.Provider?, string
    local url = opts.issuer:gsub("/$", "") .. "/.well-known/openid-configuration"
    local body, why = fetch("GET", url, { timeout_ns = REQUEST_TIMEOUT, headers = { Accept = "application/json" }, follow = false })
    if body == nil then return nil, "discovery: " .. why end
    if body.status ~= 200 then
      return nil, ("discovery: %s answered %d"):format(url, body.status)
    end
    local doc, bad = Json.decode_object(body.body)
    if doc == nil then return nil, "discovery: " .. tostring(bad) end
    local found, trouble = read_provider(doc, opts.issuer)
    if found == nil then return nil, "discovery: " .. trouble end
    return found, ""
  end

  -- TODO: let a request that finds a discovery or a fetch of the keys
  -- under way wait for it (a Poll.notifier) rather than start its own:
  -- while the provider hangs, each request until the first fetch fails
  -- asks it again.

  --- The provider, discovered on the first call that succeeds and kept.
  local function discovered(): Oidc.Provider?, string
    local have = provider
    if have ~= nil then return have, "" end
    local t = now()
    local failed = recent(discovery_failure, discovery_failed_at, t)
    if failed ~= nil then return nil, failed end
    local found, why = discover()
    if found == nil then
      discovery_failure, discovery_failed_at = why, t
      return nil, why
    end
    provider = found
    return found, ""
  end

  --- The provider's keys, fetched.
  local function fetch_keys(p: Oidc.Provider): {Jose.Jwk}?, string
    local body, why = fetch("GET", p.jwks_uri, { timeout_ns = REQUEST_TIMEOUT, headers = { Accept = "application/json" }, follow = false })
    if body == nil then return nil, "keys: " .. why end
    if body.status ~= 200 then
      return nil, ("keys: %s answered %d"):format(p.jwks_uri, body.status)
    end
    local set, bad = Json.decode_object(body.body)
    if set == nil then return nil, "keys: " .. tostring(bad) end
    local got, trouble = Jose.keys(set)
    if got == nil then return nil, "keys: " .. tostring(trouble) end
    return got, ""
  end

  --- The provider's keys, fetched where none are kept, they are old, or
  --- `fresh` asks and the last fetch is not too recent.
  local function provider_keys(p: Oidc.Provider, fresh: boolean): {Jose.Jwk}?, string
    local t = now()
    local have = keys
    if have ~= nil and t - keys_at < KEYS_SECONDS and not (fresh and t - keys_at >= REFETCH_SECONDS) then
      return have, ""
    end
    local failed = recent(keys_failure, keys_failed_at, t)
    if failed ~= nil then return nil, failed end
    local got, why = fetch_keys(p)
    if got == nil then
      keys_failure, keys_failed_at = why, t
      return nil, why
    end
    keys, keys_at = got, t
    return got, ""
  end

  --- The claims of `token`, checked, or why not.
  local function checked(p: Oidc.Provider, token: string, nonce: string): Verdict
    local jwt_opts: Jose.JwtOptions = {
      issuer = p.issuer, audience = opts.client_id, algs = opts.algs, now = now(),
    }
    local have, why = provider_keys(p, false)
    if have == nil then return { reason = why, down = true } end
    local claims, refused = Jose.verify_jwt(token, have, jwt_opts)
    if claims == nil then
      -- A provider that rolls its keys signs with one not yet fetched.
      local again, trouble = provider_keys(p, true)
      if again == nil then return { reason = trouble, down = true } end
      if again ~= have then claims, refused = Jose.verify_jwt(token, again, jwt_opts) end
    end
    if claims == nil then
      return { reason = "the ID token: " .. tostring(refused), down = false }
    end
    if text(claims.claims, "nonce") ~= nonce then
      return { reason = "the ID token is not of this login", down = false }
    end
    -- OpenID Connect Core section 3.1.3.7, items 4 and 5.
    local azp = claims.claims["azp"]
    if (#claims.aud > 1 or azp ~= nil) and azp ~= opts.client_id then
      return { reason = "the ID token is for another party", down = false }
    end
    if claims.sub == "" then return { reason = "the ID token names no subject", down = false } end
    return { claims = claims.claims, reason = "", down = false }
  end

  --- The logins under way in `session`, by state, the stale left out.
  local function pending(session: Session.Handle): mut {string: {string: Json.Value}}
    local out: mut {string: {string: Json.Value}} = {}
    local value = session:get(PENDING)
    if value == nil then return out end
    local object, _ = Json.to_object(value)
    local t = now()
    for state, entry in pairs(object or {}) do
      local each, _ = Json.to_object(entry)
      if each ~= nil then
        local at = each["at"]
        if at is integer and t - at < PENDING_SECONDS and t >= at then out[state] = each end
      end
    end
    return out
  end

  local function unreachable(req: Types.Request, why: string): Types.Response
    local sink = req.app.spec.sink
    if sink ~= nil then sink:line("oidc: " .. why) end
    return Response.problem(503, "the login provider cannot be reached")
  end

  local function login(req: Types.Request): Types.Response
    if cross_site_subresource(req) then
      return Response.problem(403, "a login starts from a link, not from a request another site makes")
    end
    local query, _ = req:query()
    local asked = if query ~= nil then Url.query_first(query, "next") else nil end
    local next_path = if asked ~= nil and #asked > MAX_NEXT then "/" else Response.safe_next(asked, "/") end
    local p, why = discovered()
    if p == nil then return unreachable(req, why) end
    local session = Session.of(req)
    local under_way = pending(session)
    local count = 0
    local oldest: string? = nil
    local oldest_at = math.maxinteger
    for state, entry in pairs(under_way) do
      count = count + 1
      local at = entry["at"]
      if at is integer and at < oldest_at then oldest, oldest_at = state, at end
    end
    if count >= MAX_PENDING and oldest ~= nil then under_way[oldest] = nil end
    local state, nonce, verifier = random_token(), random_token(), random_token()
    under_way[state] = { nonce = nonce, verifier = verifier, next = next_path, at = now() }
    session:set(PENDING, under_way)
    local params: mut {Url.Pair} = {
      { name = "response_type", value = "code" },
      { name = "client_id", value = opts.client_id },
      { name = "redirect_uri", value = opts.redirect_uri },
      { name = "scope", value = scope },
      { name = "state", value = state },
      { name = "nonce", value = nonce },
      { name = "code_challenge", value = Codec.base64url(Hash.sha256(verifier)) },
      { name = "code_challenge_method", value = "S256" },
    }
    local extra: mut {string} = {}
    for name in pairs(opts.params or {}) do extra[#extra + 1] = name end
    table.sort(extra)
    for _, name in ipairs(extra) do
      params[#params + 1] = { name = name, value = assert((opts.params or {})[name]) }
    end
    return Response.redirect(with_query(p.authorization_endpoint, params), { status = 302 })
  end

  --- Trades `code`, of the login under way `entry`, for tokens at `p`:
  --- the claims to keep of who logged in, or nil and the response that
  --- refuses the login.
  local function exchange(req: Types.Request, p: Oidc.Provider, entry: {string: Json.Value},
                          code: string): {string: Json.Value}?, Types.Response?
    local form: mut {Url.Pair} = {
      { name = "grant_type", value = "authorization_code" },
      { name = "code", value = code },
      { name = "redirect_uri", value = opts.redirect_uri },
      { name = "code_verifier", value = assert(text(entry, "verifier")) },
    }
    local headers: mut {string: string} = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      Accept = "application/json",
    }
    local secret = opts.client_secret
    if secret ~= nil then
      -- RFC 6749 section 2.3.1: each half form-encoded before it is joined.
      local function enc(s: string): string return (Url.escape(s):gsub("%%20", "+")) end
      headers["Authorization"] = "Basic " .. Codec.base64(enc(opts.client_id) .. ":" .. enc(secret))
    else
      form[#form + 1] = { name = "client_id", value = opts.client_id }
    end
    local body, trouble = fetch("POST", p.token_endpoint, {
      headers = headers, body = Url.encode_query(form), timeout_ns = REQUEST_TIMEOUT, follow = false,
    })
    if body == nil then return nil, unreachable(req, "token: " .. trouble) end
    if body.status ~= 200 then
      local sink = req.app.spec.sink
      if sink ~= nil then
        sink:line(("oidc: token: %s answered %d"):format(p.token_endpoint, body.status))
      end
      return nil, Response.problem(401, "the provider did not take the login's code")
    end
    local tokens, wrong = Json.decode_object(body.body)
    if tokens == nil then return nil, unreachable(req, "token: " .. tostring(wrong)) end
    local id_token = text(tokens, "id_token")
    if id_token == nil then
      return nil, Response.problem(401, "the provider answered no ID token")
    end
    local verdict = checked(p, id_token, assert(text(entry, "nonce")))
    local claims = verdict.claims
    if claims == nil then
      if verdict.down then return nil, unreachable(req, verdict.reason) end
      return nil, Response.problem(401, verdict.reason)
    end
    local kept: mut {string: Json.Value} = {}
    for _, name in ipairs(keep) do
      local value = claims[name]
      if value ~= nil then kept[name] = value end
    end
    return kept, nil
  end

  local function callback(req: Types.Request): Types.Response
    local query, bad = req:query()
    if query == nil then return Response.problem(400, bad) end
    local state = Url.query_first(query, "state")
    if state == nil then return Response.problem(400, "the provider's answer has no state") end
    local session = Session.of(req)
    local under_way = pending(session)
    local entry = under_way[state]
    if entry == nil then
      return Response.problem(400, "no login of this browser is under way with this state")
    end
    -- Each response that refuses the login uses up its state.
    local function spend()
      under_way[state] = nil
      session:set(PENDING, if next(under_way) == nil then nil else under_way end)
    end
    local failed = Url.query_first(query, "error")
    if failed ~= nil then
      spend()
      local said = Url.query_first(query, "error_description")
      return Response.problem(401, "the provider refused the login: " .. plain(failed) ..
          (if said ~= nil and said ~= "" then " (" .. plain(said) .. ")" else "" end))
    end
    local code = Url.query_first(query, "code")
    if code == nil or code == "" then
      spend()
      return Response.problem(400, "the provider's answer has no code")
    end
    local p, why = discovered()
    if p == nil then return unreachable(req, why) end
    -- Refused before the state is spent, so the browser can come back to it.
    -- Nothing waits between asking and counting, and an address counts its
    -- trades under way, so that trades waiting on the provider count too.
    local address = if req.client ~= nil then req.client.host else "-" end
    local wait_ns = math.max(by_address:wait_ns(address), failed_by_address:wait_ns(address),
      everyone:wait_ns(""))
    if wait_ns == 0 and (trading[address] or 0) >= FAILURES_PER_ADDRESS then
      wait_ns = Clock.seconds(1)
    end
    if wait_ns > 0 then return Attempts.too_many(wait_ns, "too many logins; try again later") end
    spend()
    -- RFC 9207: a provider that names itself must name the issuer asked.
    local iss = Url.query_first(query, "iss")
    if (iss == nil and p.iss_in_answer == true) or (iss ~= nil and iss ~= p.issuer) then
      return Response.problem(400, "the answer is not from the issuer")
    end
    by_address:failed(address)
    trading[address] = (trading[address] or 0) + 1
    -- The count under way falls whatever the trade does, a raise included.
    local called, kept, refusal = pcall(exchange, req, p, entry, assert(code))
    local left = (trading[address] or 1) - 1
    if left > 0 then trading[address] = left else trading[address] = nil end
    if not called then error(kept, 0) end
    if kept == nil then
      failed_by_address:failed(address)
      everyone:failed("")
      return assert(refusal)
    end
    session:regenerate()
    session:set(KEPT, { claims = kept, at = now() })
    session:bind_subject(assert(text(kept, "sub")))
    return Response.redirect(Response.safe_next(text(entry, "next"), "/"))
  end

  local function logout(req: Types.Request): Types.Response
    if req.method ~= "POST" then
      local res = Response.problem(405, "log out with a POST")
      Response.add_header(res, "Allow", "POST")
      return res
    end
    Session.of(req):invalidate()
    if provider_logout == nil then return Response.redirect(after_logout) end
    local p, why = discovered()
    if p == nil then
      -- The app's session is over; the provider's is the provider's to end.
      local sink = req.app.spec.sink
      if sink ~= nil then sink:line("oidc: logout: " .. why) end
      return Response.redirect(after_logout)
    end
    local ending = p.end_session_endpoint
    -- TODO: send id_token_hint, which some providers require beside
    -- post_logout_redirect_uri, once a session store keeps what a signed
    -- cookie has no room for.
    if ending ~= nil then
      return Response.redirect(with_query(ending, {
        { name = "client_id", value = opts.client_id },
        { name = "post_logout_redirect_uri", value = provider_logout },
      }))
    end
    return Response.redirect(after_logout)
  end
  -- The middleware handles logout before any CSRF middleware inside it.
  local guarded_logout = Csrf.middleware{ token = false, strict_same_site = true }(logout)

  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      req:set(LOGIN, login_path)
      local outcome = req.outcome
      local routed = outcome == nil or (outcome.kind ~= "bad_host" and outcome.kind ~= "bad_path" and
        outcome.kind ~= "redirect")
      if routed then
        local path = req.path
        -- A GET alone: a HEAD would use up a state, or a code, as a GET does.
        if path == callback_path and req.method == "GET" then return callback(req) end
        if path == login_path and req.method == "GET" then return login(req) end
        if path == logout_path then return guarded_logout(req) end
      end
      local session = req:get(Session.KEY)
      if session ~= nil then
        local identity = kept_identity(session:get(KEPT))
        if identity ~= nil and identity.issuer == opts.issuer then
          if max_age == nil or now() - identity.logged_in_at < max_age then
            req:set(IDENTITY, identity)
          end
        end
      end
      return inner(req)
    end
  end
end

--- Middleware that requires a login: a GET or HEAD that would take HTML
--- is sent to [`Web.oidc`]'s login path, to come back here after; any
--- other request with nobody logged in gets 401. Put it inside
--- [`Web.oidc`], on the app, a mount or a route.
function Oidc.require_login(): Types.Middleware
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      if req:get(IDENTITY) ~= nil then return inner(req) end
      local login_path = req:get(LOGIN)
      if login_path ~= nil and (req.method == "GET" or req.method == "HEAD") and
          req:accepts({ "text/html", "application/json" }) == "text/html" then
        local here = req.path .. (if req.query_string ~= "" then "?" .. req.query_string else "" end)
        return Response.redirect(with_query(login_path, { { name = "next", value = here } }))
      end
      return Response.problem(401, "this needs a login")
    end
  end
end

return Oidc
