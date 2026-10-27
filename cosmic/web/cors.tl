--- Cross-origin resource sharing for [`cosmic.web`]: the middleware that
--- answers a browser's preflight and marks the responses a page of another
--- origin may read.
---
---     middleware = {
---       Cors.middleware{
---         allow_origins = { "https://app.example.com" },
---         allow_credentials = true,
---       },
---       ...
---     }
---
--- CORS is not authorization. It tells a browser which sites' scripts may
--- read a response; it does not stop a request from being made or run, and
--- a client that is no browser ignores it. Authenticate and authorize every
--- request, and keep a state-changing one behind [`cosmic.web.csrf`]. CORS
--- is not CSRF protection either: a cross-site form is a "simple" request
--- that needs no preflight.
---
--- Put it first in the app's middleware. A 401, 403, 404 or 413 made below
--- it, and the 500 the exception layer makes for a raise, carry the CORS
--- headers, so the browser shows the problem and not an opaque "CORS error".
---
--- An origin is matched exactly on scheme, lowercased host and port (a
--- default port equals none). `Origin: null` (a sandboxed iframe, a `file:`
--- page) is never allowed by `"*"` or by a predicate, only by listing
--- `"null"`. A credentialed `"*"` raises: the browser refuses it, and the
--- usual repair, reflecting any origin, would give every site the user's
--- cookies. Every response to a request with an `Origin`, or without one
--- (the answer to either is not the other's), a refusal and an error
--- included, carries `Vary: Origin`, so a cache keeps them apart.

local Origin = require("cosmic.web.origin")
local Response = require("cosmic.web.response")
local Types = require("cosmic.web.types")

local record Cors
  --- What [`Cors.middleware`] takes.
  record Options
    --- The origins a page may read from: "https://app.example.com" (scheme,
    --- host and an optional port, no path), "null", or `{"*"}` alone for
    --- any. An entry that is none of these raises.
    allow_origins?: {string}
    --- A predicate in addition to the list, given an origin in lowercase
    --- ("https://a.example.com"); never called for "null". With credentials
    --- it is the app's job not to say yes to a stranger.
    allow_origin?: function(origin: string): boolean
    --- The methods a preflight may ask for; {"GET", "HEAD", "POST"} by
    --- default. Each is an uppercase method name: "*" raises.
    allow_methods?: {string}
    --- The request headers a preflight may ask for besides the safelisted
    --- (Accept, Accept-Language, Content-Language, Content-Type); {"*"}
    --- allows any header name, and the answer repeats the ones asked for.
    allow_headers?: {string}
    --- Response headers a script may read (Access-Control-Expose-Headers).
    expose_headers?: {string}
    --- Let a page send and read cookies and Authorization (false).
    allow_credentials?: boolean
    --- Seconds a browser may keep a preflight's answer (600). Browsers cap
    --- it: Chrome 7200, Firefox 86400.
    max_age?: integer
  end
end

local SAFELISTED <const>: {string:boolean} = {
  accept = true, ["accept-language"] = true, ["content-language"] = true, ["content-type"] = true,
}

--- A header or method name: an HTTP token.
local function token(text: any): boolean
  return type(text) == "string" and text:find("^[%w!#$%%&'*+.^_`|~-]+$") ~= nil
end

--- The list `names` as a set of lowercase names, raising for any that is no token.
local function names_of(names: {string}?, what: string): {string:boolean}, boolean
  local set: mut {string:boolean} = {}
  local any = false
  for _, each in ipairs(names or {}) do
    if not token(each) then
      error(("cors: %s: %s is no header name"):format(what, tostring(each)), 3)
    end
    if each == "*" then
      any = true
    else
      set[each:lower()] = true
    end
  end
  return set, any
end

--- The origins a config allows by name, as a set.
local function origins_of(list: {string}?): {string:boolean}, boolean
  local set: mut {string:boolean} = {}
  local any = false
  for _, each in ipairs(list or {}) do
    if each == "*" then
      any = true
    elseif each == "null" then
      set["null"] = true
    else
      local normal = type(each) == "string" and Origin.normalize(each) or nil
      if normal == nil then
        error(("cors: allow_origins: %s is not an origin like https://app.example.com (no path), \"null\" or \"*\""):format(
          tostring(each)), 3)
      end
      set[normal] = true
    end
  end
  return set, any
end

--- The named origins of `opts.allow_origins` that are safe to trust with
--- state changes, in a spelling [`Csrf.Options.trusted_origins`] takes: for
--- a partner that sends credentialed unsafe requests, which must be
--- listed in both. "*" and "null" are left out, and so is any origin that
--- only the [`allow_origin`] predicate admits: list those in `trusted_origins`
--- by hand.
--- @param opts Cors.Options The config
--- @return {string} The origins
function Cors.trusted(opts: Cors.Options): {string}
  local out: mut {string} = {}
  for _, each in ipairs(opts.allow_origins or {}) do
    local normal = Origin.normalize(each)
    if normal ~= nil then out[#out + 1] = normal end
  end
  return out
end

--- Builds the middleware: see this module's description. Raises, naming the
--- field, for a config that cannot work.
--- @param opts Cors.Options What to allow
--- @return Types.Middleware The middleware
function Cors.middleware(opts: Cors.Options): Types.Middleware
  if type(opts) ~= "table" then error("cors: Cors.middleware takes the options", 2) end
  local origins, wildcard = origins_of(opts.allow_origins)
  local credentials = opts.allow_credentials == true
  if wildcard and credentials then
    error("cors: allow_credentials with allow_origins = {\"*\"} is refused by browsers; list the origins", 2)
  end
  if wildcard and next(origins) ~= nil then
    error("cors: allow_origins = {\"*\"} stands alone", 2)
  end
  local methods: mut {string} = {}
  local method_set: mut {string:boolean} = {}
  for _, each in ipairs(opts.allow_methods or { "GET", "HEAD", "POST" }) do
    if not token(each) or each == "*" or each ~= each:upper() then
      error(("cors: allow_methods: %s is not an uppercase method name"):format(tostring(each)), 2)
    end
    if not method_set[each] then
      method_set[each] = true
      methods[#methods + 1] = each
    end
  end
  local header_set, any_header = names_of(opts.allow_headers, "allow_headers")
  local listed_headers: mut {string} = {}
  for _, each in ipairs(opts.allow_headers or {}) do
    if each ~= "*" then listed_headers[#listed_headers + 1] = each end
  end
  names_of(opts.expose_headers, "expose_headers")
  local expose_headers = opts.expose_headers
  local exposed = if expose_headers ~= nil and #expose_headers > 0 then
    table.concat(expose_headers, ", ") else nil end
  local max_age = opts.max_age or 600
  if math.type(max_age) ~= "integer" or max_age < 0 then
    error("cors: max_age is a number of seconds, 0 or more", 2)
  end
  local predicate = opts.allow_origin
  --- The origin to answer with, or nil where `sent` is not allowed.
  local function allowed(sent: string): string?
    if sent == "null" then
      return if origins["null"] then "null" else nil end
    end
    local normal = Origin.normalize(sent)
    if normal == nil then return nil end
    if wildcard then return "*" end
    if origins[normal] or (predicate ~= nil and predicate(normal)) then return sent end
    return nil
  end

  --- Adds the headers every CORS answer to `origin` carries.
  local function mark(res: Types.Response, origin: string?)
    Response.add_header(res, "Vary", "Origin")
    if origin == nil then return end
    Response.set_header(res, "Access-Control-Allow-Origin", origin)
    if credentials then Response.set_header(res, "Access-Control-Allow-Credentials", "true") end
  end

  --- Answers a preflight: 204 with the grant, or 403 with none.
  local function preflight(req: Types.Request, origin: string): Types.Response
    local ask = req.headers["access-control-request-method"]
    local headers_asked = req.headers["access-control-request-headers"]
    local pass = ask ~= nil and method_set[ask] == true
    local echo: mut {string} = {}
    if pass and headers_asked ~= nil and headers_asked ~= "" then
      if #headers_asked > 2048 then
        pass = false
      else
        for piece in headers_asked:gmatch("[^,]+") do
          local name = piece:match("^%s*(.-)%s*$")
          if not token(name) then
            pass = false
            break
          end
          local lower = name:lower()
          if not (any_header or header_set[lower] or SAFELISTED[lower]) then
            pass = false
            break
          end
          echo[#echo + 1] = lower
        end
      end
    end
    -- A refusal and an answer both depend on the three request headers.
    local out = Response.empty(if pass then 204 else 403 end)
    Response.add_header(out, "Vary", "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")
    if not pass then return out end
    Response.set_header(out, "Access-Control-Allow-Origin", origin)
    if credentials then Response.set_header(out, "Access-Control-Allow-Credentials", "true") end
    Response.set_header(out, "Access-Control-Allow-Methods", table.concat(methods, ", "))
    if #echo > 0 then
      Response.set_header(out, "Access-Control-Allow-Headers", table.concat(echo, ", "))
    elseif #listed_headers > 0 then
      Response.set_header(out, "Access-Control-Allow-Headers", table.concat(listed_headers, ", "))
    end
    Response.set_header(out, "Access-Control-Max-Age", tostring(max_age))
    return out
  end

  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local sent = req.headers["origin"]
      if sent == nil then
        local res = Response.copy(inner(req))
        Response.add_header(res, "Vary", "Origin")
        return res
      end
      local origin = allowed(sent)
      if req.method == "OPTIONS" and req.headers["access-control-request-method"] ~= nil then
        if origin == nil then
          local res = Response.empty(403)
          Response.add_header(res, "Vary", "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")
          return res
        end
        return preflight(req, origin)
      end
      local res = Response.copy(inner(req))
      mark(res, origin)
      if origin ~= nil and exposed ~= nil then
        Response.set_header(res, "Access-Control-Expose-Headers", exposed)
      end
      return res
    end
  end
end

return Cors
