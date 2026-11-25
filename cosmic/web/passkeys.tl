--- Passkeys for a cosmic.web app: a user registers a passkey, and logs
--- in with it later, through JSON endpoints this middleware handles and
--- a script it serves that calls them from the page. The checks are
--- [`cosmic.webauthn`]'s; what is kept is the session's and a store's.
---
---     local Session = require("cosmic.web.session")
---     local SessionSqlite = require("cosmic.web.session.sqlite")
---     local Web = require("cosmic.web")
---
---     local app = Web.app{
---       routes = { ... },
---       middleware = {
---         Session.middleware{ store = assert(SessionSqlite.store(db)) },
---         Web.passkeys{
---           rp_id = "example.com", rp_name = "Example", origin = "https://example.com",
---           store = assert(Web.passkey_store(db)),
---           user = function(req: Web.Request): Web.PasskeyUser?
---             -- Who may add a passkey now: the account logged in, or
---             -- one this browser is making. Never one named by the
---             -- request alone: a registration logs in as its user.
---           end,
---         },
---       },
---     }
---
--- A page loads `/auth/passkey/script.js` and calls
--- `cosmicPasskeys.register()` to add a passkey for the user that `user`
--- names, or `cosmicPasskeys.login()` to log in with one; each returns a
--- promise, and `cosmicPasskeys.logout()` ends the session.
--- `login({ conditional: true })` offers the passkeys in the
--- browser's autofill of an input with `autocomplete="username webauthn"`,
--- and `login({ next: "/admin" })` goes there after (the page's path by
--- default; `go: false` stays). The script needs a browser with
--- `PublicKeyCredential.parseCreationOptionsFromJSON`.
---
--- Under the prefix (`/auth/passkey`), the middleware handles:
---
--- - `POST /register/begin` and `POST /login/begin`: the options for
---   `navigator.credentials.create` or `.get`, around a new challenge kept
---   in the session for five minutes (four of each at once, one a tab);
--- - `POST /register/finish`: checks the new passkey against that
---   challenge, keeps it in the store, and logs in with it;
--- - `POST /login/finish`: finds the passkey in the store, checks the
---   proof, keeps its new counter, and logs in in a regenerated session;
--- - `POST /logout`: ends the session, and sends the browser on to
---   `after_logout`;
--- - `GET /script.js`: the page's script.
---
--- Each POST but logout must be JSON (`Content-Type: application/json`),
--- which another site's page cannot send without the browser asking this
--- app first, and one whose `Origin` is not `origin` is refused. A browser
--- sends `Origin` with each such POST; a request with none is taken, as
--- one from a program. Each challenge is used once: the store notes it
--- ([`Store.spend`]), since a session in a signed cookie cannot forget
--- it, and a response to it is refused after. A login is a passkey with no user named first: the
--- browser offers the passkeys it holds for `rp_id`, and the user handle
--- of the one chosen says who logs in. [`Web.who`] returns
--- it, for every request of the session after while the store keeps the
--- passkey: removing one ([`Store.remove`]) logs out every session it
--- logged in, at its next request, though the session and what else it
--- holds stay. The session is bound
--- ([`Handle:bind_subject`]) to the user handle in base64url.
---
--- [`cosmic.web.session`]'s middleware must run outside this one. Under
--- its signed cookie store ([`cosmic.web.session.cookie`]) a logout ends
--- the session in the browser alone, as that store says: a copy of the
--- cookie stays logged in until it expires.
--- @public

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Json = require("cosmic.json")
local Identities = require("cosmic.web.identity")
local Response = require("cosmic.web.response")
local Session = require("cosmic.web.session")
local Sqlite = require("cosmic.sqlite")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")
local Webauthn = require("cosmic.webauthn")

local record Passkeys
  --- Who a passkey is registered for, as [`Passkeys.Options.user`]
  --- names them.
  record User
    --- The user handle: opaque bytes the app chooses for the account, 1
    --- to 64, never an email address or a name. A passkey keeps it, and
    --- a login with the passkey gives it back. Make it at random when the
    --- account is made (16 bytes of [`Rand.entropy`]), keep it with the
    --- account, and look it up from there: a handle made from what a user
    --- types is one anybody can type, and the passkey they then register
    --- logs in to the account that has it. A handle that is `name` or
    --- `display_name` raises.
    handle: string
    --- The name the user knows the account by, which the browser shows.
    name: string
    --- A name to show; `name` by default.
    display_name?: string
  end

  --- Who logged in with a passkey: see [`cosmic.web.identity.Passkey`].
  type Identity = Identities.Passkey

  --- Where passkeys are kept: [`Web.passkey_store`] makes one in SQLite.
  --- Each of its functions returns nil (or false) and why when the store
  --- itself fails, which is a 500.
  record Store
    --- The passkey of credential id `id`; nil and "" where none is kept.
    find: function(Store, id: string): Webauthn.Credential?, string
    --- The user's passkeys.
    list: function(Store, user_handle: string): {Webauthn.Credential}?, string
    --- Keeps a new passkey: true, or false and "" where one of its id is
    --- kept already, for any user.
    add: function(Store, credential: Webauthn.Credential): boolean, string
    --- Keeps what a login changed of a passkey: its `sign_count` and
    --- `backed_up`. False and "" where it is no longer kept.
    update: function(Store, credential: Webauthn.Credential): boolean, string
    --- Removes the passkey of credential id `id`: true where one was kept.
    --- The sessions it logged in are logged in no more.
    remove: function(Store, id: string): boolean, string
    --- Notes that `challenge` is used, until the time `lapses` (seconds since the
    --- epoch), and forgets the ones noted until `now` or before: true
    --- the first time, false and "" for one noted already.
    spend: function(Store, challenge: string, lapses: integer, now: integer): boolean, string
  end

  --- What [`Web.passkey_store`] takes; every field is optional.
  record StoreOptions
    --- The table's name, a plain identifier ("web_passkeys").
    table?: string
  end

  --- What [`Web.passkeys`] takes.
  record Options
    --- The relying party id: the app's registrable domain or a host
    --- under it, which each passkey is bound to. The host of `origin`
    --- must be it or under it.
    rp_id: string
    --- The name to show for the app.
    rp_name: string
    --- The origin the app's pages are served from,
    --- `https://example.com`: https, or http on the loopback, where a
    --- test serves.
    origin: string
    --- Where the passkeys are kept.
    store: Store
    --- Who may register a passkey now, or nil where nobody may (401):
    --- the account logged in, or one this browser is making (a sign-up
    --- the session holds). A registration logs in as the user it returns,
    --- so a user named by the request alone, a header or a form field,
    --- gives the account to whoever names it. A sign-up reserves its name
    --- first, refusing one an account has, or a second browser signing up
    --- under the name adds its passkey to the first's account.
    user: function(req: Types.Request): User?
    --- The paths' prefix ("/auth/passkey").
    prefix?: string
    --- Where logout sends the browser after ("/").
    after_logout?: string
    --- Whether the authenticator must verify the user (a PIN, a
    --- fingerprint), beside the user being present. False by default:
    --- a passkey is asked to verify ("preferred") but one that does not
    --- is taken.
    require_verification?: boolean
    --- How long a login counts, in seconds; nil for as long as the
    --- session.
    max_age?: integer
    --- The time in seconds since the epoch, for a test.
    now?: function(): integer
  end
end

--- What is under way for a challenge, taken from the session.
local record Taken
  --- The challenge, raw bytes.
  challenge: string
  --- What the session kept with it.
  entry: {string: Json.Value}
  --- When it lapses, in seconds since the epoch.
  lapses: integer
  --- The time it was taken at, before `lapses`: what [`Store.spend`]
  --- is given as now, so that a spend never forgets the challenge it
  --- notes, however long the checks between took.
  taken_at: integer
end

--- The key a request's identity is kept under.
local IDENTITY: Types.Key<Passkeys.Identity> = Identities.PASSKEY

--- The session key of who logged in.
local KEPT <const> = "_passkey"
--- The session keys of the registrations and logins under way, by
--- challenge, apart, so a page that waits in autofill for a login can
--- still register.
local REGISTERING <const> = "_passkey_register"
local LOGGING_IN <const> = "_passkey_login"
--- The most of each a session holds, one a tab: the oldest goes.
local MAX_PENDING <const> = 4
--- How long a registration or login under way may take, in seconds: the
--- options' `timeout`, and a little.
local PENDING_SECONDS <const> = 330
--- The longest `next` a login takes, in bytes; a longer one goes to "/".
local MAX_NEXT <const> = 512

--- The page's script, with the prefix in place of `PREFIX`.
local SCRIPT <const> = [[
(() => {
  "use strict";
  const prefix = PREFIX;
  async function post(path, body) {
    const res = await fetch(prefix + path, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body ?? {}),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || `passkey: ${res.status}`);
    return data;
  }
  async function register() {
    const options = await post("/register/begin");
    const credential = await navigator.credentials.create({
      publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options),
    });
    return post("/register/finish", credential.toJSON());
  }
  async function login(opts = {}) {
    const options = await post("/login/begin");
    const request = { publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(options) };
    if (opts.conditional) request.mediation = "conditional";
    if (opts.signal) request.signal = opts.signal;
    const credential = await navigator.credentials.get(request);
    const next = opts.next ?? location.pathname + location.search;
    const done = await post(`/login/finish?next=${encodeURIComponent(next)}`, credential.toJSON());
    if (opts.go !== false) location.assign(done.next);
    return done;
  }
  async function logout() {
    const res = await fetch(prefix + "/logout", { method: "POST", credentials: "same-origin" });
    location.assign(res.url);
  }
  window.cosmicPasskeys = { register, login, logout };
})();
]]

--- The member `name` of `object` when it is a string.
local function text(object: {string: Json.Value}, name: string): string?
  local value = object[name]
  if value is string then return value end
  return nil
end

--- The member `name` of `object`, base64url, decoded.
local function decoded(object: {string: Json.Value}, name: string): string?
  local value = text(object, name)
  if value == nil then return nil end
  local bytes, _ = Codec.unbase64url(value)
  return bytes
end

--- Whether `url` is an origin, https or http to the loopback, and its host.
local function origin_host(url: string): string?
  local parts, _ = Url.parse(url)
  if parts == nil then return nil end
  local host = parts.host
  if host == "" or parts.path ~= "" or parts.query ~= nil or parts.userinfo ~= nil or parts.fragment ~= nil then
    return nil
  end
  if parts.scheme == "https" then return host end
  if parts.scheme == "http" and (host == "127.0.0.1" or host == "localhost" or host == "::1") then
    return host
  end
  return nil
end

--- The challenge a response's `clientDataJSON` names, base64url as it
--- holds it; nil for a response that names none. Only to find what is
--- under way: the check of it is [`Webauthn`]'s.
local function answer_challenge(answer: {string: Json.Value}): string?
  local response, _ = Json.to_object(answer["response"])
  if response == nil then return nil end
  local data = decoded(response, "clientDataJSON")
  if data == nil then return nil end
  local client, _ = Json.decode_object(data)
  if client == nil then return nil end
  return text(client, "challenge")
end

--- The identity the session's `kept` value holds, or nil.
local function kept_identity(value: Json.Value?): Passkeys.Identity?
  if value == nil then return nil end
  local object, _ = Json.to_object(value)
  if object == nil then return nil end
  local handle, id = decoded(object, "user"), decoded(object, "credential")
  local at, verified = object["at"], object["verified"]
  if handle == nil or id == nil or not at is integer or not verified is boolean then return nil end
  return { user_handle = handle, credential_id = id, user_verified = verified, logged_in_at = at }
end

--- The middleware of passkey registration and login that this
--- module's doc tells. Raises on options that cannot work: an
--- `origin` that is not https (or http to the loopback) or not
--- lowercase, a host of it that is not `rp_id` or under it, a `prefix`
--- or an `after_logout` that is not a path of this app.
--- @param opts Passkeys.Options What it takes
--- @return Types.Middleware The middleware
function Passkeys.middleware(opts: Passkeys.Options): Types.Middleware
  local host = origin_host(opts.origin)
  if host == nil or opts.origin ~= opts.origin:lower() then
    error("passkeys: origin must be an https origin, lowercase, with no path", 2)
  end
  local rp_id = opts.rp_id
  if rp_id == "" or (host ~= rp_id and host:sub(-#rp_id - 1) ~= "." .. rp_id) then
    error("passkeys: the host of origin must be rp_id or under it", 2)
  end
  local prefix = opts.prefix or "/auth/passkey"
  if not Response.local_path(prefix) or prefix:sub(-1) == "/" or prefix:find("?", 1, true) ~= nil then
    error("passkeys: prefix must be a path of this app, with no trailing /", 2)
  end
  local after_logout = opts.after_logout or "/"
  if not Response.local_path(after_logout) then
    error("passkeys: after_logout must be a path of this app", 2)
  end
  local store, max_age = opts.store, opts.max_age
  local verification: Webauthn.UserVerification = if opts.require_verification == true then "required" else "preferred" end
  local now = opts.now or function(): integer return Clock.now_ns() // 1000000000 end
  local script = SCRIPT:gsub("PREFIX", function(): string return (assert(Json.encode(prefix))) end)

  local function failed(req: Types.Request, why: string): Types.Response
    local sink = req.app.spec.sink
    if sink ~= nil then sink:line("passkeys: " .. why) end
    return Response.problem(500, "the passkeys cannot be read")
  end

  --- What the session holds under way at `key`, by challenge, at the
  --- time `t`, with those that lapsed left out. One lapses at
  --- `at + PENDING_SECONDS`, the time its spent row in the store lapses
  --- too: taken only before then, it is never taken once the store may
  --- have forgotten it.
  local function pending(session: Session.Handle, key: string, t: integer): mut {string: {string: Json.Value}}
    local out: mut {string: {string: Json.Value}} = {}
    local value = session:get(key)
    if value == nil then return out end
    local object, _ = Json.to_object(value)
    for challenge, entry in pairs(object or {}) do
      local each, _ = Json.to_object(entry)
      if each ~= nil then
        local at = each["at"]
        if at is integer and t - at < PENDING_SECONDS and at <= t then out[challenge] = each end
      end
    end
    return out
  end

  --- Keeps `entry` under way at `key` for a new challenge, the oldest
  --- going past `MAX_PENDING`; returns the challenge.
  local function begin(session: Session.Handle, key: string, entry: mut {string: Json.Value}): string
    local challenge = Webauthn.challenge()
    local t = now()
    local held = pending(session, key, t)
    local count = 0
    for _ in pairs(held) do count = count + 1 end
    while count >= MAX_PENDING do
      local oldest: string? = nil
      local oldest_at = math.maxinteger
      for c, each in pairs(held) do
        local at = each["at"]
        if at is integer and (at < oldest_at or (at == oldest_at and c < (oldest or c))) then
          oldest, oldest_at = c, at
        end
      end
      held[assert(oldest)] = nil
      count = count - 1
    end
    entry["at"] = t
    held[Codec.base64url(challenge)] = entry
    session:set(key, held)
    return challenge
  end

  --- What is under way at `key` for the challenge `answer` names, taken
  --- from the session, and the challenge; nil where none is.
  local function taken(session: Session.Handle, key: string, answer: {string: Json.Value}): Taken?
    local named = answer_challenge(answer)
    if named == nil then return nil end
    local t = now()
    local held = pending(session, key, t)
    local entry = held[named]
    if entry == nil then return nil end
    held[named] = nil
    session:set(key, held)
    local challenge, _ = Codec.unbase64url(named)
    local at = entry["at"]
    if challenge == nil or not at is integer then return nil end
    return { challenge = challenge, entry = entry, lapses = at + PENDING_SECONDS, taken_at = t }
  end

  --- Notes `took`'s challenge as used, in the store: nil where it is,
  --- else the response that refuses the request.
  local function spent(req: Types.Request, took: Taken): Types.Response?
    local fresh, why = store:spend(took.challenge, took.lapses, took.taken_at)
    if not fresh then
      if why ~= "" then return failed(req, why) end
      return Response.problem(400, "this challenge is answered already")
    end
    -- Lapsed while the store was asked, the challenge may have been
    -- forgotten by another request's spend, which this one's then took.
    if now() >= took.lapses then return Response.problem(400, "this challenge has lapsed") end
    return nil
  end

  local function expected(challenge: string): Webauthn.Expected
    return {
      challenge = challenge, origin = opts.origin, rp_id = rp_id,
      user_verification = opts.require_verification,
    }
  end

  --- Logs in with `credential`, in a regenerated session.
  local function log_in(session: Session.Handle, credential: Webauthn.Credential, verified: boolean)
    session:regenerate()
    local handle = Codec.base64url(credential.user_handle)
    session:set(KEPT, {
      user = handle, credential = Codec.base64url(credential.id), verified = verified, at = now(),
    })
    session:bind_subject(handle)
  end

  local function register_begin(req: Types.Request): Types.Response
    local user = opts.user(req)
    if user == nil then return Response.problem(401, "log in to add a passkey") end
    local kept, why = store:list(user.handle)
    if kept == nil then return failed(req, why) end
    if #user.handle == 0 or #user.handle > 64 then
      error("passkeys: the user function answered a handle that is not 1 to 64 bytes")
    end
    if user.handle == user.name or user.handle == user.display_name then
      error("passkeys: the user function answered the account's name as its handle")
    end
    local challenge = begin(Session.of(req), REGISTERING, { user = Codec.base64url(user.handle) })
    return Response.json(Webauthn.creation_options({
      rp_id = rp_id, rp_name = opts.rp_name, user_id = user.handle, user_name = user.name,
      display_name = user.display_name, exclude = kept, user_verification = verification,
    }, challenge))
  end

  local function register_finish(req: Types.Request, answer: {string: Json.Value}): Types.Response
    local session = Session.of(req)
    local took = taken(session, REGISTERING, answer)
    if took == nil then
      return Response.problem(400, "no registration of this browser is under way for this answer")
    end
    local user = opts.user(req)
    local handle = decoded(took.entry, "user")
    if user == nil or user.handle ~= handle then
      return Response.problem(401, "the registration is not for the user logged in")
    end
    local credential, why = Webauthn.verify_registration(answer, user.handle, expected(took.challenge))
    if credential == nil then return Response.problem(400, why) end
    local refused = spent(req, took)
    if refused ~= nil then return refused end
    local added, wrong = store:add(credential)
    if not added then
      if wrong ~= "" then return failed(req, wrong) end
      return Response.problem(409, "this passkey is registered already")
    end
    log_in(session, credential, credential.user_verified)
    return Response.json({ id = Codec.base64url(credential.id) }, { status = 201 })
  end

  local function login_begin(req: Types.Request): Types.Response
    local none: mut {string: Json.Value} = {}
    local challenge = begin(Session.of(req), LOGGING_IN, none)
    return Response.json(Webauthn.request_options({ rp_id = rp_id, user_verification = verification }, challenge))
  end

  local function login_finish(req: Types.Request, answer: {string: Json.Value}): Types.Response
    local session = Session.of(req)
    local took = taken(session, LOGGING_IN, answer)
    if took == nil then
      return Response.problem(400, "no login of this browser is under way for this answer")
    end
    local id, bad = Webauthn.credential_id(answer)
    if id == nil then return Response.problem(400, bad) end
    local credential, why = store:find(id)
    if credential == nil then
      if why ~= "" then return failed(req, why) end
      return Response.problem(401, "this passkey is not registered here")
    end
    local assertion, refused = Webauthn.verify_authentication(answer, credential, expected(took.challenge))
    if assertion == nil then return Response.problem(401, refused) end
    local used = spent(req, took)
    if used ~= nil then return used end
    credential.sign_count = assertion.sign_count
    credential.backed_up = assertion.backed_up
    local updated, wrong = store:update(credential)
    if not updated then
      if wrong ~= "" then return failed(req, wrong) end
      return Response.problem(401, "this passkey is not registered here")
    end
    log_in(session, credential, assertion.user_verified)
    local query, _ = req:query()
    local asked = if query ~= nil then Url.query_first(query, "next") else nil end
    local next_path = if asked ~= nil and #asked > MAX_NEXT then "/" else Response.safe_next(asked, "/") end
    return Response.json({ next = next_path })
  end

  --- Returns the response to a POST to one of the endpoints, `step`.
  local function answer(req: Types.Request, step: string): Types.Response
    if req.method ~= "POST" then
      local res = Response.problem(405, "this takes a POST")
      Response.add_header(res, "Allow", "POST")
      return res
    end
    local from = req:header("origin")
    if from ~= nil and from ~= opts.origin then
      return Response.problem(403, "this is answered to the app's own pages")
    end
    if step == "/logout" then
      Session.of(req):invalidate()
      return Response.redirect(after_logout, { status = 303 })
    end
    local kind = (req:header("content-type") or ""):match("^%s*([^;%s]+)")
    if kind == nil or kind:lower() ~= "application/json" then
      return Response.problem(415, "this takes JSON")
    end
    if step == "/register/begin" then return register_begin(req) end
    if step == "/login/begin" then return login_begin(req) end
    local body, unread = req:text()
    if body == nil then return Response.problem(400, unread) end
    local object, wrong = Json.decode_object(body)
    if object == nil then
      return Response.problem(400, "the answer is not a JSON object: " .. tostring(wrong))
    end
    if step == "/register/finish" then return register_finish(req, object) end
    return login_finish(req, object)
  end

  local steps: {string: boolean} = {
    ["/register/begin"] = true, ["/register/finish"] = true, ["/login/begin"] = true,
    ["/login/finish"] = true, ["/logout"] = true,
  }

  --- Sets the request's identity from its session: nil, or the 500 of a
  --- store that fails.
  local function identify(req: Types.Request): Types.Response?
    local session = req:get(Session.KEY)
    if session == nil then return nil end
    local identity = kept_identity(session:get(KEPT))
    if identity == nil or (max_age ~= nil and now() - identity.logged_in_at >= max_age) then
      return nil
    end
    -- A passkey removed from the store logs its sessions out, the
    -- copies of a signed cookie among them.
    local credential, why = store:find(identity.credential_id)
    if credential == nil and why ~= "" then return failed(req, why) end
    if credential ~= nil and credential.user_handle == identity.user_handle then
      req:set(IDENTITY, identity)
    end
    return nil
  end

  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local outcome = req.outcome
      local routed = outcome == nil or (outcome.kind ~= "bad_host" and outcome.kind ~= "bad_path" and
        outcome.kind ~= "redirect")
      local path = req.path
      local step: string? = nil
      if routed and path:sub(1, #prefix + 1) == prefix .. "/" then step = path:sub(#prefix + 1) end
      -- Neither asks the store, so a logout works while it fails.
      if step == "/logout" then return answer(req, "/logout") end
      if step == "/script.js" and (req.method == "GET" or req.method == "HEAD") then
        return Response.text(script, { headers = {
          ["Content-Type"] = "text/javascript; charset=utf-8", ["Cache-Control"] = "no-cache",
        } })
      end
      local refused = identify(req)
      if refused ~= nil then return refused end
      if step ~= nil and steps[step] == true then return answer(req, step) end
      return inner(req)
    end
  end
end

--- The columns a passkey is kept in, in the order a row is read.
local COLUMNS <const> = "id, user_handle, public_key, alg, sign_count, backup_eligible, backed_up, " ..
  "transports, user_verified, aaguid"

local function credential_of(r: Sqlite.Row): Webauthn.Credential
  local transports, _ = Json.decode(r:text(8))
  local list, _ = Json.to_array(transports)
  local names: mut {string} = {}
  for _, name in ipairs(list or {}) do
    if name is string then names[#names + 1] = name end
  end
  return {
    id = r:blob(1), user_handle = r:blob(2), public_key = r:blob(3), alg = r:integer(4),
    sign_count = r:integer(5), backup_eligible = r:integer(6) ~= 0, backed_up = r:integer(7) ~= 0,
    transports = names, user_verified = r:integer(9) ~= 0, aaguid = r:blob(10),
  }
end

local function flag(b: boolean): Sqlite.Value
  return { integer = if b then 1 else 0 end }
end

--- A [`Passkeys.Store`] in the SQLite database `db`: a table of its own,
--- made when it is missing, a row a passkey keyed by its credential id,
--- with an index of the user handle, and beside it a table of the
--- challenges used (`<table>_spent`) until they lapse. Nil and why where the table cannot
--- be made. Like [`cosmic.web.session.sqlite`], a query blocks the
--- server's thread; each here is one row or one user's.
--- @param db Sqlite.Handle The database, writable
--- @param opts Passkeys.StoreOptions | nil What it takes
--- @return Passkeys.Store | nil The store
--- @return string Why none, or ""
function Passkeys.sqlite_store(db: Sqlite.Handle, opts?: Passkeys.StoreOptions): Passkeys.Store?, string
  local name = (opts and opts.table) or "web_passkeys"
  if not name:match("^[%a_][%w_]*$") then
    error("passkeys: the table's name must be a plain identifier", 2)
  end
  local made, why = db:exec(([[
    CREATE TABLE IF NOT EXISTS %s (
      id BLOB PRIMARY KEY, user_handle BLOB NOT NULL, public_key BLOB NOT NULL, alg INTEGER NOT NULL,
      sign_count INTEGER NOT NULL, backup_eligible INTEGER NOT NULL, backed_up INTEGER NOT NULL,
      transports TEXT NOT NULL, user_verified INTEGER NOT NULL, aaguid BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS %s_user ON %s (user_handle);
    CREATE TABLE IF NOT EXISTS %s_spent (challenge BLOB PRIMARY KEY, lapses INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS %s_spent_lapses ON %s_spent (lapses);
  ]]):format(name, name, name, name, name, name))
  if not made then return nil, "passkeys: " .. tostring(why) end
  local store: Passkeys.Store = {
    find = function(_: Passkeys.Store, id: string): Webauthn.Credential?, string
      local found, wrong = db:map(("SELECT %s FROM %s WHERE id = ?1"):format(COLUMNS, name),
        { { blob = id } }, credential_of)
      if found == nil then return nil, "passkeys: " .. tostring(wrong) end
      return found[1], ""
    end,
    list = function(_: Passkeys.Store, user_handle: string): {Webauthn.Credential}?, string
      local found, wrong = db:map(("SELECT %s FROM %s WHERE user_handle = ?1 ORDER BY rowid"):format(
        COLUMNS, name), { { blob = user_handle } }, credential_of)
      if found == nil then return nil, "passkeys: " .. tostring(wrong) end
      return found, ""
    end,
    add = function(_: Passkeys.Store, c: Webauthn.Credential): boolean, string
      local ok, wrong = db:run(("INSERT INTO %s (%s) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) " ..
        "ON CONFLICT (id) DO NOTHING"):format(name, COLUMNS), {
          { blob = c.id }, { blob = c.user_handle }, { blob = c.public_key }, { integer = c.alg },
          { integer = c.sign_count }, flag(c.backup_eligible), flag(c.backed_up),
          { text = assert(Json.encode(Json.array(c.transports))) }, flag(c.user_verified), { blob = c.aaguid },
        })
      if not ok then return false, "passkeys: " .. tostring(wrong) end
      return db:changes() == 1, ""
    end,
    update = function(_: Passkeys.Store, c: Webauthn.Credential): boolean, string
      local ok, wrong = db:run(("UPDATE %s SET sign_count = ?2, backed_up = ?3 WHERE id = ?1"):format(name),
        { { blob = c.id }, { integer = c.sign_count }, flag(c.backed_up) })
      if not ok then return false, "passkeys: " .. tostring(wrong) end
      return db:changes() == 1, ""
    end,
    spend = function(_: Passkeys.Store, challenge: string, lapses: integer, now: integer): boolean, string
      local swept, unswept = db:run(("DELETE FROM %s_spent WHERE lapses <= ?1"):format(name), { { integer = now } })
      if not swept then return false, "passkeys: " .. tostring(unswept) end
      local ok, wrong = db:run(("INSERT INTO %s_spent (challenge, lapses) VALUES (?1, ?2) " ..
        "ON CONFLICT (challenge) DO NOTHING"):format(name), { { blob = challenge }, { integer = lapses } })
      if not ok then return false, "passkeys: " .. tostring(wrong) end
      return db:changes() == 1, ""
    end,
    remove = function(_: Passkeys.Store, id: string): boolean, string
      local ok, wrong = db:run(("DELETE FROM %s WHERE id = ?1"):format(name), { { blob = id } })
      if not ok then return false, "passkeys: " .. tostring(wrong) end
      return db:changes() == 1, ""
    end,
  }
  return store, ""
end

return Passkeys
