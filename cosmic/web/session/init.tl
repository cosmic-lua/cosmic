--- Sessions for [`cosmic.web`]: a small JSON object kept for a browser
--- between requests, behind one interface and two stores, the signed
--- cookie of [`cosmic.web.session.cookie`] and the SQLite table of
--- [`cosmic.web.session.sqlite`].
---
---     local app = Web.app{
---       routes = {
---         Web.post("/login", function(req: Web.Request): Web.Response
---           local session = Session.of(req)
---           session:regenerate()
---           session:set("user", "ada")
---           session:flash("success", "Signed in")
---           return Web.redirect("/")
---         end),
---       },
---       middleware = {
---         Session.middleware{
---           store = SessionCookie.store{ keys = assert(Secret.keys_from_env("SESSION_KEYS")) },
---         },
---       },
---     }
---
--- The middleware is lazy: a request that never touches the session reads
--- no cookie, queries nothing and sends no `Set-Cookie` and no `Vary`. A
--- request that reads it gets `Vary: Cookie` (and `Cache-Control: private`
--- unless the response sets its own); one that changes it gets a
--- `Set-Cookie`, and one that only reads gets none. A tampered, expired or
--- unknown cookie is an anonymous session, never an error, and is expired
--- on the way out. A handler that raises, which the app has answered 500 by
--- the time the middleware sees it, saves nothing; a 4xx keeps what the
--- handler changed, as a handler may flash and answer 422 on purpose.
---
--- Values must be what [`Json.encode`] accepts; `set` raises for any other
--- at the call, so the trace is the handler's. A nested table that `get`
--- returns is the session's own: change it, then `set` it again, or the
--- change is not saved. Two requests that change the session at once (htmx
--- loading three fragments) race: the signed cookie keeps whichever
--- response the browser applied last, the SQLite store merges the keys each
--- wrote.
---
--- After the middleware has built the response the handle is frozen, and a
--- write raises: a streamed response's head is already sent, so make every
--- change before returning.
---
--- `Secure` follows the request's scheme unless `secure` is given, which
--- [`Web.app`]'s `trusted_proxy` sets from `X-Forwarded-Proto`; behind a
--- TLS proxy without it, pass `secure = true`, and the cookie is then named
--- `__Host-session`.

local Clock = require("cosmic.clock")
local Cookies = require("cosmic.web.cookies")
local Json = require("cosmic.json")
local Request = require("cosmic.web.request")
local Response = require("cosmic.web.response")
local Types = require("cosmic.web.types")

local record Session
  --- A message to show the user once.
  record Flash
    --- "info", "success", "warning", "error" or the app's own.
    kind: string
    --- The text, at most 500 bytes.
    text: string
  end

  --- What a session holds, as a store keeps it.
  record Data
    --- The values, by key.
    values: {string:any}
    --- When the session began, in seconds since the epoch.
    created: integer
    --- When it ends, in seconds since the epoch.
    expires: integer
    --- Set by a store that read the session under a key it is retiring: the
    --- middleware saves it again, signed by the newest.
    stale?: boolean
  end

  --- What a request changed, for a store that merges instead of
  --- replacing.
  record Changes
    --- The keys written, with their values.
    set: {string:any}
    --- The keys deleted.
    removed: {string}
    --- Whether everything was removed first (what `set` and `removed` hold
    --- came after).
    cleared?: boolean
    --- Whether the session is to take a new id, keeping its data.
    regenerated?: boolean
    --- The user the session is bound to, for a store that can find
    --- sessions by it; nil when not bound.
    subject?: string
  end

  --- Where a session is kept. `cookie` is the name of the session cookie
  --- the token travels in, for a store that binds one to the other.
  record Store
    --- The data `token` names; nil and "" when it names none (absent,
    --- tampered, unknown, expired), which makes the request anonymous.
    --- Nil and why when the store itself failed, which is a 500.
    load: function(Store, token: string, now: integer, cookie: string): Data | nil, string
    --- Keeps `data`, the session as the request saw it with its changes
    --- applied, and answers the token to send. `previous` is the token the
    --- request came with, "" for a new session. Nil and why when it cannot
    --- (the cookie store when the token is too big), which is a 500.
    save: function(Store, previous: string, data: Data, changes: Changes, now: integer,
        cookie: string): string | nil, string
    --- Revokes `token` where the store can.
    destroy: function(Store, token: string): boolean, string
    --- Whether `destroy` revokes: false for a signed cookie, which
    --- lives until it expires wherever it was copied.
    revocable: boolean
  end

  --- What [`Session.middleware`] takes.
  record Options
    --- Where sessions are kept. Required: the choice, and its key, are
    --- visible at the top of the app.
    store: Store
    --- The cookie's name: "session", or "__Host-session" when `secure` is
    --- true (and "__Secure-session" with a `domain`).
    cookie_name?: string
    --- The lifetime in seconds from the session's start (14 days).
    max_age?: integer
    --- Extend the lifetime on use (false): once less than half of
    --- `max_age` is left, a request that reads the session renews it, so
    --- it writes at most about twice a period.
    rolling?: boolean
    --- The cookie's path ("/").
    path?: string
    --- The cookie's domain (none: host-only).
    domain?: string
    --- "Lax" by default.
    same_site?: Cookies.SameSite
    --- The cookie's `Secure`; nil follows the request's scheme.
    secure?: boolean
    --- The time in seconds since the epoch, for a test.
    now: function(): integer
  end

  --- A request's session. Its methods are called with ":".
  record Handle
    --- The value at `key`, or nil.
    get: function(Handle, key: string): any
    --- The value at `key` when it is a string.
    get_string: function(Handle, key: string): string | nil
    --- The value at `key` when it is an integer.
    get_integer: function(Handle, key: string): integer | nil
    --- The value at `key` when it is a boolean.
    get_boolean: function(Handle, key: string): boolean | nil
    --- Keeps `value` at `key`; a nil value removes the key, as `delete` does.
    --- Raises when the value is not JSON or nests past [`Session.MAX_DEPTH`],
    --- when the key is empty or the reserved "_flash", and after the response
    --- has been built.
    set: function(Handle, key: string, value: any)
    --- Removes `key`.
    delete: function(Handle, key: string)
    --- The value at `key`, removed.
    pop: function(Handle, key: string): any
    --- Removes every value.
    clear: function(Handle)
    --- Gives the session a new id (and a new lifetime), keeping its data
    --- but the CSRF secret, which the next [`Csrf.token`] draws anew: call it
    --- at login and on any change of privilege. A signed cookie
    --- cannot revoke the old one.
    regenerate: function(Handle)
    --- Revokes the session and expires the cookie (logout), even when the
    --- response turns out to be a 500: a logout that errors afterwards still
    --- logs out. The handle is then an empty anonymous session that may be
    --- written again, which starts a new one (saved only if the response is
    --- not a 500).
    invalidate: function(Handle)
    --- Adds a message for the next page: at most 10 are kept (the oldest
    --- go) of at most 500 bytes. Raises for a kind or text that is not UTF-8.
    flash: function(Handle, kind: string, text: string)
    --- The pending messages, removed: each is shown once.
    take_flashes: function(Handle): {Flash}
    --- Whether the request came without a valid session.
    is_new: function(Handle): boolean
    --- The session's id where the store has one (SQLite), else "". It is a
    --- credential: never log it.
    id: function(Handle): string
    --- Binds the session to a user, so a store that can ([`cosmic.web.session.sqlite`])
    --- ends all of one user's sessions at once; a no-op on a signed cookie.
    bind_subject: function(Handle, subject: string)
  end

  --- The key the middleware keeps the request's [`Session.Handle`] under.
  KEY: Types.Key<Handle>
  --- The key [`cosmic.web.csrf`] keeps its secret under ("_csrf"). The session
  --- drops it at `regenerate`, `clear` and `invalidate`: a token belongs to one
  --- identity of the session, so what a login changes, and a fixed session
  --- cookie planted before it, cannot carry a token across.
  CSRF_KEY: string
  --- How many arrays and objects a session may nest, counting the object
  --- that holds the values (16): `set` refuses a deeper value and a store
  --- refuses to save, or to load, one.
  MAX_DEPTH: integer
end

Session.KEY = Request.key("session")
Session.MAX_DEPTH = 16
Session.CSRF_KEY = "_csrf"

local DAY <const> = 86400
local MAX_FLASHES <const> = 10
local MAX_FLASH_BYTES <const> = 500
local FLASH <const> = "_flash"

--- What one request has read and changed of its session.
local record State
  req: Types.Request
  opts: Session.Options
  cookie: string
  max_age: integer
  now: integer
  loaded: boolean
  accessed: boolean
  frozen: boolean
  --- Whether the request came with a valid session.
  valid: boolean
  --- The token the request came with and that is still the session's.
  token: string
  --- Whether a cookie came that named no valid session.
  bad_cookie: boolean
  data: Session.Data
  changes: Session.Changes
  --- Whether the session is to be saved.
  dirty: boolean
  --- Whether the handler invalidated the session.
  invalidated: boolean
  --- Tokens to revoke when the response is built.
  doomed: {string}
end

--- A fresh anonymous session.
local function blank(now: integer, max_age: integer): Session.Data
  return { values = {}, created = now, expires = now + max_age }
end

--- No changes yet.
local function nothing(): Session.Changes
  return { set = {}, removed = {} }
end

--- Reads the session from the cookie, once.
local function ensure(st: State)
  st.accessed = true
  if st.loaded then return end
  st.loaded = true
  st.data = blank(st.now, st.max_age)
  local token = Cookies.parse(st.req:header("cookie"))[st.cookie]
  if token == nil or token == "" then return end
  local data, why = st.opts.store:load(token, st.now, st.cookie)
  if data == nil then
    if why ~= "" then error("session: " .. why, 0) end
    st.bad_cookie = true
    return
  end
  st.valid = true
  st.token = token
  st.data = data
  if data.stale then st.dirty = true end
end

--- Raises where the session may not be written.
local function writable(st: State)
  if st.frozen then
    error("session: written after the response head was built; set it before returning the response", 0)
  end
  ensure(st)
end

local function get_string(st: State, key: string): string | nil
  ensure(st)
  local value = st.data.values[key]
  if value is string then return value end
  return nil
end

--- Notes that the session is to be saved.
local function mark(st: State)
  st.dirty = true
end

local function remove_key(list: {string}, key: string)
  for i = #list, 1, -1 do
    if list[i] == key then table.remove(list, i) end
  end
end

local function delete_value(st: State, key: string)
  writable(st)
  if st.data.values[key] == nil then return end
  st.data.values[key] = nil
  st.changes.set[key] = nil
  remove_key(st.changes.removed, key)
  st.changes.removed[#st.changes.removed + 1] = key
  mark(st)
end

local function set_value(st: State, key: string, value: any)
  writable(st)
  if type(key) ~= "string" or key == "" then
    error("session: a key is a non-empty string", 0)
  end
  if key == FLASH then
    error("session: " .. FLASH .. " is reserved; use flash()", 0)
  end
  if value == nil then
    delete_value(st, key)
    return
  end
  -- The value sits inside the object of values, one level down.
  local _, why = Json.encode_any(value, { max_depth = Session.MAX_DEPTH - 1 })
  if why ~= nil and why ~= "" then
    error("session: cannot keep " .. key .. ": " .. why, 0)
  end
  st.data.values[key] = value
  st.changes.set[key] = value
  remove_key(st.changes.removed, key)
  mark(st)
end

--- The longest prefix of `text` of at most `limit` bytes that ends on a
--- character, as JSON refuses a string cut in the middle of one.
local function cut(text: string, limit: integer): string
  if #text <= limit then return text end
  local stop = limit
  while stop > 0 do
    local b = text:byte(stop + 1)
    if b < 0x80 or b >= 0xC0 then break end
    stop = stop - 1
  end
  return text:sub(1, stop)
end

local function flashes_of(st: State): {{string:any}}
  local list = st.data.values[FLASH]
  if list is {{string:any}} then return list end
  return {}
end

local function make_handle(st: State): Session.Handle
  local handle: Session.Handle = {
    get = function(_: Session.Handle, key: string): any
      ensure(st)
      return st.data.values[key]
    end,
    get_string = function(_: Session.Handle, key: string): string | nil
      return get_string(st, key)
    end,
    get_integer = function(_: Session.Handle, key: string): integer | nil
      ensure(st)
      local value = st.data.values[key]
      if value is integer then return value end
      return nil
    end,
    get_boolean = function(_: Session.Handle, key: string): boolean | nil
      ensure(st)
      local value = st.data.values[key]
      if value is boolean then return value end
      return nil
    end,
    set = function(_: Session.Handle, key: string, value: any)
      set_value(st, key, value)
    end,
    delete = function(_: Session.Handle, key: string)
      delete_value(st, key)
    end,
    pop = function(_: Session.Handle, key: string): any
      writable(st)
      local value = st.data.values[key]
      delete_value(st, key)
      return value
    end,
    clear = function(_: Session.Handle)
      writable(st)
      if next(st.data.values) == nil and not st.valid then return end
      st.data.values = {}
      st.changes = { set = {}, removed = {}, cleared = true, regenerated = st.changes.regenerated,
        subject = st.changes.subject }
      mark(st)
    end,
    regenerate = function(_: Session.Handle)
      writable(st)
      delete_value(st, Session.CSRF_KEY)
      st.changes.regenerated = true
      st.data.created = st.now
      st.data.expires = st.now + st.max_age
      mark(st)
    end,
    invalidate = function(_: Session.Handle)
      writable(st)
      if st.token ~= "" then st.doomed[#st.doomed + 1] = st.token end
      st.token = ""
      st.valid = false
      st.bad_cookie = false
      st.data = blank(st.now, st.max_age)
      st.changes = nothing()
      st.dirty = false
      st.invalidated = true
    end,
    flash = function(_: Session.Handle, kind: string, text: string)
      writable(st)
      if type(kind) ~= "string" or kind == "" or type(text) ~= "string" then
        error("session: a flash is a kind and a text, both strings", 0)
      end
      local _, why = Json.encode({ kind = kind, text = text })
      if why ~= nil and why ~= "" then
        error("session: cannot flash that: " .. why, 0)
      end
      local list: {{string:any}} = {}
      for _, each in ipairs(flashes_of(st)) do list[#list + 1] = each end
      list[#list + 1] = { kind = kind, text = cut(text, MAX_FLASH_BYTES) }
      while #list > MAX_FLASHES do table.remove(list, 1) end
      st.data.values[FLASH] = list
      st.changes.set[FLASH] = list
      remove_key(st.changes.removed, FLASH)
      mark(st)
    end,
    take_flashes = function(_: Session.Handle): {Session.Flash}
      ensure(st)
      local out: {Session.Flash} = {}
      if st.data.values[FLASH] == nil then return out end
      writable(st)
      for _, each in ipairs(flashes_of(st)) do
        local kind, text = each.kind, each.text
        if kind is string and text is string then
          out[#out + 1] = { kind = kind, text = text }
        end
      end
      delete_value(st, FLASH)
      return out
    end,
    is_new = function(_: Session.Handle): boolean
      ensure(st)
      return not st.valid
    end,
    id = function(_: Session.Handle): string
      ensure(st)
      if st.opts.store.revocable then return st.token end
      return ""
    end,
    bind_subject = function(_: Session.Handle, subject: string)
      writable(st)
      if type(subject) ~= "string" or subject == "" then
        error("session: a subject is a non-empty string", 0)
      end
      if not st.opts.store.revocable then return end
      st.changes.subject = subject
      mark(st)
    end,
  }
  return handle
end

--- The request's session. Raises where [`Session.middleware`] is not
--- installed above the handler.
--- @param req Types.Request The request
--- @return Session.Handle The session
function Session.of(req: Types.Request): Session.Handle
  local handle = req:get(Session.KEY)
  if handle == nil then
    error("session: Session.middleware is not installed", 0)
  end
  return handle
end

--- The attributes the session cookie is written with.
local function attributes(opts: Session.Options, secure: boolean): Cookies.Attributes
  return { path = opts.path, domain = opts.domain, same_site = opts.same_site, secure = secure }
end

--- Adds the line that expires the session cookie to `res`.
local function expire(res: Types.Response, cookie: string, opts: Session.Options, secure: boolean)
  local attrs = attributes(opts, secure)
  -- A cookie that never was set over http cannot be Secure-less SameSite=None.
  if not secure and attrs.same_site == "None" then attrs.same_site = "Lax" end
  local line, why = Cookies.expire(cookie, attrs)
  if line == nil then error("session: " .. why, 0) end
  Response.add_header(res, "Set-Cookie", line)
end

--- Builds the middleware that gives each request a lazy session: see this
--- module's description. Raises for an option that cannot work, naming it,
--- before the app serves.
--- @param opts Session.Options The store and the cookie
--- @return Types.Middleware The middleware
function Session.middleware(opts: Session.Options): Types.Middleware
  if type(opts) ~= "table" or opts.store == nil then
    error("session: Session.middleware needs a store (SessionCookie.store or SessionSqlite.store)", 0)
  end
  local max_age = opts.max_age or 14 * DAY
  if math.type(max_age) ~= "integer" or max_age < 1 then
    error("session: max_age is a number of seconds, at least 1", 0)
  end
  local cookie: string
  local cookie_name = opts.cookie_name
  if cookie_name ~= nil then
    cookie = cookie_name
  elseif opts.secure == true then
    cookie = opts.domain == nil and "__Host-session" or "__Secure-session"
  else
    cookie = "session"
  end
  local opts_secure = opts.secure
  -- SameSite=None needs Secure, which an unset `secure` decides per request.
  local probe = opts_secure == true or (opts_secure == nil and opts.same_site == "None")
  local _, why = Cookies.format(cookie, "x", attributes(opts, probe))
  if why ~= "" then error("session: " .. why, 0) end
  local clock = opts.now or function(): integer return Clock.now_ns() // 1000000000 end
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local now = clock()
      local st: State = { req = req, opts = opts, cookie = cookie, max_age = max_age, now = now,
        data = blank(now, max_age), loaded = false, accessed = false, frozen = false, valid = false, token = "",
        bad_cookie = false, changes = nothing(), dirty = false, invalidated = false, doomed = {} }
      req:set(Session.KEY, make_handle(st))
      local handled = inner(req)
      st.frozen = true
      if not st.accessed then return handled end
      local res = Response.copy(handled)
      Response.add_header(res, "Vary", "Cookie")
      if Response.header(res, "Cache-Control") == nil then
        Response.set_header(res, "Cache-Control", "private")
      end
      local secure: boolean
      local opts_secure2 = opts.secure
      if opts_secure2 ~= nil then
        secure = opts_secure2
      else
        -- TODO: once the app can tell its middleware where it listens
        -- (Web.app's listeners), warn once at startup when `secure` is unset
        -- and a listener is not on the loopback, as doc/plans/web/input.md
        -- asks: behind a TLS proxy without trusted_proxy the cookie goes out
        -- without Secure.
        secure = req.scheme == "https"
      end
      -- Revoking is not undone by a 500: a logout that errors still logs out.
      for _, token in ipairs(st.doomed) do
        local ok, destroy_why = opts.store:destroy(token)
        if not ok then error("session: " .. destroy_why, 0) end
      end
      if res.status >= 500 then
        if st.invalidated then expire(res, cookie, opts, secure) end
        return res
      end
      if not st.dirty and opts.rolling and st.valid and st.data.expires - st.now < max_age // 2 then
        st.data.expires = st.now + max_age
        st.dirty = true
      end
      if st.dirty then
        if opts.same_site == "None" and not secure then
          error("session: same_site = \"None\" needs a Secure cookie, and this request came over http; " ..
              "serve over https, set Web.app's trusted_proxy for X-Forwarded-Proto, or pass secure = true", 0)
        end
        local token, save_why = opts.store:save(st.token, st.data, st.changes, st.now, cookie)
        if token == nil then error("session: " .. save_why, 0) end
        local attrs = attributes(opts, secure)
        attrs.max_age = math.max(st.data.expires - st.now, 1)
        local ok, format_why = Cookies.set(res, cookie, token, attrs)
        if not ok then error("session: " .. format_why, 0) end
      elseif st.invalidated or st.bad_cookie then
        expire(res, cookie, opts, secure)
      end
      return res
    end
  end
end

return Session
