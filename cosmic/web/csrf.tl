--- Cross-site request forgery defence for [`cosmic.web`]: two layers on
--- every request whose method changes state, and the token for forms and
--- htmx.
---
---     middleware = { Session.middleware{ store = store }, Csrf.middleware() }
---
---     -- in a page handler, for a form:
---     Csrf.field(req)                       -- <input type="hidden" name="csrf_token" ...>
---     -- or once, on <body>, for every htmx request below it:
---     --   <body hx-headers='{{Csrf.hx_headers(req)}}'>
---
--- 1. **Origin.** A browser says where an unsafe request came from. The
---    `Origin` header (the `Referer`'s origin where there is no `Origin`)
---    must be the origin the request was made to, or one of
---    `trusted_origins`; `Origin: null` is refused unless `"null"` is
---    listed; `Sec-Fetch-Site: cross-site` is refused whatever `Origin`
---    says. A request with neither header (curl, a server) passes this
---    layer.
--- 2. **A synchronizer token.** The secret is 32 random bytes in the session
---    under [`Session.CSRF_KEY`], drawn by the first [`Csrf.token`]. A page
---    carries a masked copy (a fresh one per call, so a compressed response
---    does not leak the secret by its length), which a request returns in
---    the `X-CSRF-Token` header or the `csrf_token` field of its form. It is
---    checked against the session's secret with [`Hash.equal`]. A request
---    with no session, or a session that never drew a secret, has nothing
---    to match and is refused. `session:regenerate()` (login) drops the
---    secret, so a token seen before it stops working; a boosted login must
---    end in a full navigation (`HX-Redirect`).
---
--- GET and TRACE are never checked, so a GET must not change state (an
--- `hx-get` that mutates is a bug this cannot catch). HEAD and OPTIONS
--- are not checked either, unless the matched route lists that method
--- itself: a handler registered for it is a handler that can change state.
--- Any other method, a lowercase "get" included, is unsafe.
---
--- A JSON body takes its token in the header alone. A form takes it in the
--- header or its `csrf_token` field, which must lie within the body's first
--- 16 KiB (a urlencoded form: any field there) or be its first part (a
--- multipart form): no more than that is read to find out, so an upload is
--- not buffered to look for a token, and the bytes read are put back for the
--- handler. Put [`Csrf.field`] first in a form, and send the header from a
--- script that posts a larger one.
---
--- A request with `Authorization: Bearer` skips the token layer by default
--- (`bearer_exempt`): a cross-site page cannot set that header, and a
--- `fetch` that does needs a CORS preflight. A route that takes a cookie
--- or a bearer token must answer an invalid bearer token 401, never fall
--- back to the cookie. Basic authentication is ambient in a browser and is
--- never exempt. The better answer for an API is structural: mount it
--- with no session and no CSRF middleware at all.
---
--- Behind a proxy that ends TLS, the request's scheme is http unless the
--- app sets `trusted_proxy`: an https `Origin` then differs from the
--- origin the request was made to and every unsafe request is refused. Set
--- `trusted_proxy`.
---
--- The `HX-Request` header exempts nothing: it is sent by script, and
--- script that sets a header cross-site needs a CORS preflight, but the
--- token does the work. A refusal of an htmx request says to reload the page.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Html = require("cosmic.html")
local Input = require("cosmic.web.input")
local Multipart = require("cosmic.http.multipart")
local Origin = require("cosmic.web.origin")
local Rand = require("cosmic.rand")
local Response = require("cosmic.web.response")
local Session = require("cosmic.web.session")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")

local record Csrf
  --- What [`Csrf.middleware`] takes; every field is optional.
  record Options
    --- Origins besides the request's own that may send an unsafe request, as
    --- "https://app.example.com" (a CORS partner: see [`Cors.trusted`]), or
    --- "null". An entry that is no origin raises. Such a request still needs
    --- its token.
    trusted_origins?: {string}
    --- Run the Origin layer (true).
    origin_check?: boolean
    --- Run the token layer (true). False states that the Origin layer is
    --- the whole defence, as for a site with no session.
    token?: boolean
    --- Treat `Sec-Fetch-Site: same-site` as cross-site (false); an `Origin`
    --- of another origin is refused either way.
    strict_same_site?: boolean
    --- Requests this answers true for are not checked (nil).
    exempt?: function(Types.Request): boolean
    --- Skip the token layer for a request with `Authorization: Bearer` (true).
    bearer_exempt?: boolean
    --- Answers a refused request, given why ("origin", "cross-site",
    --- "referer" or "token"); the default is a 403 through the app's error
    --- page.
    on_failure?: function(Types.Request, string): Types.Response
  end

  --- The form field the token is read from.
  FIELD: string
  --- The header the token is read from.
  HEADER: string
end

Csrf.FIELD = "csrf_token"
Csrf.HEADER = "X-CSRF-Token"

--- How many bytes of a form body are read to find the token.
local PEEK <const> = 16384

--- The token's length: 32 bytes of mask and 32 of masked secret, base64url.
local TOKEN_LENGTH <const> = 86

local SAFE <const>: {string:boolean} = { GET = true, HEAD = true, OPTIONS = true, TRACE = true }

--- `a` xor `b`, both of one length.
local function xor(a: string, b: string): string
  local out: {string} = {}
  for i = 1, #a do out[i] = string.char(a:byte(i) ~ b:byte(i)) end
  return table.concat(out)
end

--- The session's secret as raw bytes, or nil when it has none or it is not
--- 32 bytes.
local function secret_of(session: Session.Handle): string | nil
  local text = session:get_string(Session.CSRF_KEY)
  if text == nil then return nil end
  local raw, _ = Codec.unbase64url(text)
  if raw == nil or #raw ~= 32 then return nil end
  return raw
end

--- The session of `req`, with its secret drawn if it had none.
local function secret_for(req: Types.Request): string
  local session = Session.of(req)
  local secret = secret_of(session)
  if secret ~= nil then return secret end
  local drawn = assert(Rand.entropy(32))
  session:set(Session.CSRF_KEY, Codec.base64url(drawn))
  return drawn
end

--- A masked token for this request's session, drawing the session's secret
--- if it has none. The session middleware must be installed above the
--- handler. Each call returns a different string; every one unmasks to the
--- same secret.
--- @param req Types.Request The request
--- @return string The token, 86 characters of base64url
function Csrf.token(req: Types.Request): string
  local secret = secret_for(req)
  local mask = (assert(Rand.entropy(32)))
  return Codec.base64url(mask .. xor(secret, mask))
end

--- A hidden form input with this request's token, to put in a form that
--- posts to the app.
--- @param req Types.Request The request
--- @return Html.SafeHtml The `<input>`
function Csrf.field(req: Types.Request): Html.SafeHtml
  -- A token is base64url: nothing in it needs escaping.
  return Html.trust('<input type="hidden" name="' .. Csrf.FIELD .. '" value="' .. Csrf.token(req) .. '">')
end

--- A `<meta name="csrf-token">` tag with this request's token, for a script
--- that sets the header itself (on `htmx:configRequest`); such a script is
--- the app's own and needs the CSP nonce.
--- @param req Types.Request The request
--- @return Html.SafeHtml The tag
function Csrf.meta(req: Types.Request): Html.SafeHtml
  return Html.trust('<meta name="csrf-token" content="' .. Csrf.token(req) .. '">')
end

--- The JSON object `{"X-CSRF-Token": "..."}` for an `hx-headers` attribute,
--- which puts the token on every htmx request below the element (htmx sends
--- it to this origin only, as the config [`Htmx.head`] writes has
--- `selfRequestsOnly`).
--- @param req Types.Request The request
--- @return Html.SafeJson The attribute's value
function Csrf.hx_headers(req: Types.Request): Html.SafeJson
  return (assert(Html.json({ [Csrf.HEADER] = Csrf.token(req) })))
end

--- Whether `candidate` is a token of this secret: the right length, the
--- right alphabet, and, unmasked, equal to `secret` in constant time.
local function valid(secret: string, candidate: string): boolean
  if #candidate ~= TOKEN_LENGTH then return false end
  local raw, _ = Codec.unbase64url(candidate)
  if raw == nil or #raw ~= 64 or Codec.base64url(raw) ~= candidate then return false end
  return Hash.equal(secret, xor(raw:sub(1, 32), raw:sub(33)))
end

--- The first part of a multipart body when it is the token, read from at most
--- `PEEK` bytes; the bytes are put back on the request.
local function multipart_token(req: Types.Request): string | nil
  local cached = req:get(Input.FORM)
  if cached ~= nil then
    local list = cached.by_name[Csrf.FIELD]
    return list ~= nil and #list == 1 and list[1] or nil
  end
  local boundary = Input.media_type(req).params["boundary"]
  if boundary == nil then return nil end
  local body = req.raw.body
  local head, _ = Stream.read_up_to(body, PEEK)
  if head == nil then return nil end
  req.raw.body = Stream.prepend(head, body)
  local reader, _ = Multipart.reader(Stream.from_string(head), { boundary = boundary, max_parts = 1 })
  if reader == nil then return nil end
  local part, _ = reader:next_part()
  local value: string | nil = nil
  if part ~= nil and part.name == Csrf.FIELD and part.filename == nil then
    value, _ = Stream.read_up_to(part.body, TOKEN_LENGTH + 1)
  end
  local _, _ = reader:close()
  return value
end

--- The token field of a urlencoded body when it lies within the first `PEEK`
--- bytes and appears once; the bytes are put back on the request.
local function urlencoded_token(req: Types.Request): string | nil
  local cached = req:get(Input.FORM)
  if cached ~= nil then
    local list = cached.by_name[Csrf.FIELD]
    return list ~= nil and #list == 1 and list[1] or nil
  end
  local body = req.raw.body
  local head, _ = Stream.read_up_to(body, PEEK)
  if head == nil then return nil end
  req.raw.body = Stream.prepend(head, body)
  local found: string | nil = nil
  local count = 0
  local from = 1
  while from <= #head do
    local stop = head:find("&", from, true)
    -- A field the peek cut short is not read.
    if stop == nil and #head == PEEK then break end
    local pair = head:sub(from, (stop or #head + 1) - 1)
    local name, value = pair:match("^([^=]*)=(.*)$")
    if name == Csrf.FIELD then
      count = count + 1
      found = value
    end
    from = (stop or #head) + 1
  end
  if count ~= 1 then return nil end
  return found
end

--- The token the request carries: the header, else the form's field.
local function token_of(req: Types.Request): string | nil
  local header = req.headers["x-csrf-token"]
  if header ~= nil then return header end
  local essence = Input.media_type(req).essence
  if essence == "multipart/form-data" then return multipart_token(req) end
  if essence == "application/x-www-form-urlencoded" then return urlencoded_token(req) end
  return nil
end

--- Whether the request names itself a bearer token.
local function bearer(req: Types.Request): boolean
  local auth = req.headers["authorization"]
  return auth ~= nil and auth:lower():find("^bearer%s+%S") ~= nil
end

--- Why the Origin layer refuses `req`, or nil.
local function origin_refusal(req: Types.Request, trusted: {string:boolean}, strict: boolean): string | nil
  local origin = req.headers["origin"]
  local normal: string | nil = nil
  if origin ~= nil then
    if origin == "null" then
      if trusted["null"] then return nil end
      return "origin"
    end
    normal = Origin.normalize(origin)
    if normal ~= nil and trusted[normal] then return nil end
  end
  local site = req.headers["sec-fetch-site"]
  if site ~= nil then
    site = site:lower()
    if site == "cross-site" or (strict and site == "same-site") then return "cross-site" end
  end
  local here = Origin.of_request(req)
  if origin ~= nil then
    if normal == nil or normal ~= here then return "origin" end
    return nil
  end
  local referer = req.headers["referer"]
  if referer ~= nil and referer ~= "" then
    local from = Origin.of_url(referer)
    if from == nil then return "referer" end
    if trusted[from] then return nil end
    if from ~= here then return "referer" end
  end
  return nil
end

--- Makes `text`, a client's, safe for a log line.
local function plain(text: string | nil): string
  if text == nil then return "-" end
  return (text:sub(1, 200):gsub("[^%w%p ]", "?"))
end

--- Whether `req`'s method is checked: anything but GET and TRACE, and HEAD
--- and OPTIONS when the matched route lists them itself.
local function checked(req: Types.Request): boolean
  if not SAFE[req.method] then return true end
  if req.method ~= "HEAD" and req.method ~= "OPTIONS" then return false end
  -- Middleware at the top of the app runs before the router has matched.
  local route = req.route
  if route == nil then route = req.app.router:match(req.method, req.raw.path).route end
  if route == nil then return false end
  for _, method in ipairs(route.methods) do
    if method == req.method then return true end
  end
  return false
end

--- The default answer to a refused request.
local function refuse(req: Types.Request, reason: string): Types.Response
  -- TODO: once Response.abort can carry headers, answer an htmx request with
  -- `HX-Trigger: {"csrf-failed": {"reason": ...}}` so a page can react to it.
  if req.headers["hx-request"] == "true" then
    return Response.abort(403, "The request was refused; reload the page and try again.")
  elseif reason == "token" then
    return Response.abort(403, "The form's security token is missing or has expired; reload the page and try again.")
  end
  return Response.abort(403, "The request came from another site.")
end

--- Builds the middleware: see this module's description. It belongs
--- inside [`Session.middleware`] and outside everything that changes state.
--- Raises for an option of the wrong shape, naming it.
--- @param opts Csrf.Options | nil What to check
--- @return Types.Middleware The middleware
function Csrf.middleware(opts?: Csrf.Options): Types.Middleware
  opts = opts or {}
  local trusted: {string:boolean} = {}
  for _, each in ipairs(opts.trusted_origins or {}) do
    local normal = each == "null" and "null" or (type(each) == "string" and Origin.normalize(each) or nil)
    if normal == nil then
      error(("csrf: trusted_origins: %s is not an origin like https://app.example.com"):format(tostring(each)), 2)
    end
    trusted[normal] = true
  end
  local origin_on = opts.origin_check ~= false
  local token_on = opts.token ~= false
  local bearer_exempt = opts.bearer_exempt ~= false
  local strict = opts.strict_same_site == true
  local exempt = opts.exempt
  local on_failure = opts.on_failure or refuse
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      if not checked(req) or (exempt ~= nil and exempt(req)) then return inner(req) end
      local reason: string | nil = nil
      if origin_on then reason = origin_refusal(req, trusted, strict) end
      if reason == nil and token_on and not (bearer_exempt and bearer(req)) then
        local secret = secret_of(Session.of(req))
        -- With no secret nothing can match: the body is not read.
        local sent = secret ~= nil and token_of(req) or nil
        if secret == nil or sent == nil or not valid(secret, sent) then reason = "token" end
      end
      if reason == nil then return inner(req) end
      assert(req.app.spec.sink):line(("csrf: refused %s %s (%s) Origin: %s"):format(
        req.method, plain(req.path), reason, plain(req.headers["origin"])))
      return on_failure(req, reason)
    end
  end
end

return Csrf
