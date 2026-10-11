--- Security headers and a Content-Security-Policy for [`cosmic.web`], set
--- by one middleware on every response that passes out through it.
---
---     middleware = {
---       Headers.middleware{
---         csp = Headers.Csp.htmx_default(),
---         hsts = { max_age = 31536000 },
---       },
---     }
---
--- A header is set only where the response has none (in any case of its
--- name), so a handler, or a [`Headers.middleware`] nearer the handler (a
--- route's own `middleware`), keeps what it set: an embeddable widget route
--- answers its own CSP and `frame_options = ""`. The response is copied
--- before a header is added, so one a handler shares between requests is
--- not changed. Errors and 304s get the headers; a reply the server makes
--- itself (a 400 for a request it could not read) does not.
---
--- On by default: `X-Content-Type-Options: nosniff`, `Referrer-Policy:
--- strict-origin-when-cross-origin`, `X-Frame-Options: DENY`,
--- `Cross-Origin-Opener-Policy: same-origin` and a `Permissions-Policy` that
--- turns the camera, the microphone and geolocation off. A field set to ""
--- omits its header. Off until asked for: `Cross-Origin-Resource-Policy` (it
--- breaks cross-origin API clients and CDN images), HSTS (it sticks in a
--- browser for the whole `max_age`) and the CSP (it wants testing, so try it
--- with `csp_report_only`). HSTS is sent only on a request that came over
--- https, which `trusted_proxy` decides behind a proxy.
---
--- With `nonce`, each request draws one in [`Headers.NONCE`]; a layout reads
--- `req:get(Headers.NONCE)` and writes it as the `nonce` of its inline
--- scripts and to [`Htmx.head`]'s `nonce`, and a policy's `{nonce}` source
--- becomes `'nonce-<value>'`. A page that carries a nonce is not for a
--- shared cache: whatever its type, a response without a Cache-Control gets
--- `private`, and one whose Cache-Control says `public` or `s-maxage` has
--- them replaced by `private`.

local Codec = require("cosmic.codec")
local Rand = require("cosmic.rand")
local Request = require("cosmic.web.request")
local Response = require("cosmic.web.response")
local Types = require("cosmic.web.types")

--- A Content-Security-Policy as data.
local record Csp
  --- A policy: the directives and their sources.
  record Policy
    --- Directive name to its sources. A directive with {} is written bare
    --- ("upgrade-insecure-requests"). The source "{nonce}" is replaced by
    --- "'nonce-<value>'" for each request. A name that is no directive name,
    --- or a source holding a space, ";", "," or a control byte, raises when
    --- the policy is formatted: it could end the directive and start another.
    directives: {string:{string}}
  end
end

local record Headers
  --- A Strict-Transport-Security policy.
  record Hsts
    --- Seconds the browser remembers (required).
    max_age: integer
    --- Add `includeSubDomains` (false).
    include_subdomains: boolean
    --- Add `preload` (false); needs `include_subdomains` and a `max_age`
    --- of a year or more.
    preload: boolean
  end

  --- What [`Headers.middleware`] takes; every field is optional.
  record Options
    --- X-Content-Type-Options: nosniff (true).
    nosniff: boolean
    --- Referrer-Policy ("strict-origin-when-cross-origin"; "" omits).
    referrer_policy: string
    --- X-Frame-Options: "DENY" (default), "SAMEORIGIN" or "" for none. A
    --- `csp` without a `frame-ancestors` directive gets the matching one
    --- ('none' or 'self').
    frame_options: string
    --- Cross-Origin-Opener-Policy ("same-origin"; "" omits).
    coop: string
    --- Cross-Origin-Resource-Policy: omitted unless set to "same-origin",
    --- "same-site" or "cross-origin".
    corp: string
    --- Permissions-Policy ("camera=(), microphone=(), geolocation=()"; "" omits).
    permissions_policy: string
    --- Strict-Transport-Security, sent on https requests only; nil omits.
    hsts: Hsts
    --- The Content-Security-Policy; nil sends none.
    csp: Csp.Policy
    --- Send the policy as Content-Security-Policy-Report-Only (false).
    csp_report_only: boolean
    --- Draw a nonce for each request (false): see [`Headers.NONCE`].
    nonce: boolean
  end

  --- The request's CSP nonce, "" where no [`Headers.middleware`] with `nonce`
  --- is above the handler.
  NONCE: Types.Key<string>
  --- The Content-Security-Policy builder.
  Csp: Csp
end

Headers.NONCE = Request.key("csp-nonce")
Headers.Csp = Csp

local DIRECTIVE <const> = "^[a-z][a-z0-9-]*$"

--- A policy that lets an htmx app load its own scripts, styles, images, fonts
--- and connections and nothing else: no inline script or style, no plugins,
--- no `<base>`, forms only to this origin, never framed. Put `{nonce}` in
--- `script-src` to allow the layout's inline scripts.
--- @return Csp.Policy The policy
function Csp.htmx_default(): Csp.Policy
  return { directives = {
    ["default-src"] = { "'self'" },
    ["script-src"] = { "'self'" },
    ["style-src"] = { "'self'" },
    ["img-src"] = { "'self'", "data:" },
    ["font-src"] = { "'self'" },
    ["connect-src"] = { "'self'" },
    ["object-src"] = { "'none'" },
    ["base-uri"] = { "'none'" },
    ["form-action"] = { "'self'" },
    ["frame-ancestors"] = { "'none'" },
  } }
end

--- Whether the policy has a "{nonce}" source.
local function uses_nonce(p: Csp.Policy): boolean
  for _, sources in pairs(p.directives) do
    for _, source in ipairs(sources) do
      if source == "{nonce}" then return true end
    end
  end
  return false
end

--- The policy as a header value: directives in name order, each name then
--- its sources, joined by "; ". Raises for a name or source that could
--- end its directive, and for a "{nonce}" source with no `nonce`.
--- @param p Csp.Policy The policy
--- @param nonce string | nil The request's nonce, base64url
--- @return string The header value
function Csp.format(p: Csp.Policy, nonce?: string): string
  local names: {string} = {}
  for name in pairs(p.directives) do
    if type(name) ~= "string" or not name:find(DIRECTIVE) then
      error(("csp: %q is not a directive name"):format(tostring(name)), 2)
    end
    names[#names + 1] = name
  end
  table.sort(names)
  local out: {string} = {}
  for _, name in ipairs(names) do
    local parts: {string} = { name }
    for _, source in ipairs(p.directives[name]) do
      if source == "{nonce}" then
        if nonce == nil or nonce == "" then
          error("csp: the policy has a {nonce} source and no nonce was given", 2)
        end
        source = "'nonce-" .. nonce .. "'"
      elseif type(source) ~= "string" or source == "" or source:find("[%c%s;,]") then
        error(("csp: %s: %q is not a source"):format(name, tostring(source)), 2)
      end
      parts[#parts + 1] = source
    end
    out[#out + 1] = table.concat(parts, " ")
  end
  return table.concat(out, "; ")
end

--- `value` for `what`, raising where it could not be a header value.
local function plain(value: any, what: string): string
  if type(value) ~= "string" or value:find("[^\32-\126]") then
    error(("headers: %s is printable ASCII text"):format(what), 3)
  end
  return value
end

--- One of `allowed` (or "" for none), else raises.
local function one_of(value: string, allowed: {string}, what: string): string
  for _, each in ipairs(allowed) do
    if value == each then return value end
  end
  error(("headers: %s is one of %s, not %q"):format(what, table.concat(allowed, ", "), value), 3)
end

--- `cache`, a Cache-Control value (nil for none), made unfit for a shared
--- cache: `public` and `s-maxage` dropped and `private` added unless it or
--- `no-store` is there.
local function privately(cache: string | nil): string
  if cache == nil then return "private" end
  local kept: {string} = {}
  local safe, dropped = false, false
  for directive in cache:gmatch("[^,]+") do
    local trimmed = directive:match("^%s*(.-)%s*$")
    local name = trimmed:lower():match("^[^=]*")
    if name == "private" or name == "no-store" then safe = true end
    if name == "public" or name == "s-maxage" then
      dropped = true
    elseif trimmed ~= "" then
      kept[#kept + 1] = trimmed
    end
  end
  if safe and not dropped then return cache end
  if not safe then kept[#kept + 1] = "private" end
  return table.concat(kept, ", ")
end

--- Builds the middleware: see this module's description. Raises, naming the
--- field, for an option that cannot work.
--- @param opts Headers.Options | nil What to send
--- @return Types.Middleware The middleware
function Headers.middleware(opts?: Headers.Options): Types.Middleware
  opts = opts or {}
  local fixed: {{string}} = {}
  if opts.nosniff ~= false then fixed[#fixed + 1] = { "X-Content-Type-Options", "nosniff" } end
  local function add(name: string, value: string | nil, default: string)
    local text = plain(value == nil and default or value, name)
    if text ~= "" then fixed[#fixed + 1] = { name, text } end
  end
  add("Referrer-Policy", opts.referrer_policy, "strict-origin-when-cross-origin")
  local frame = opts.frame_options == nil and "DENY" or opts.frame_options
  one_of(frame, { "DENY", "SAMEORIGIN", "" }, "frame_options")
  if frame ~= "" then fixed[#fixed + 1] = { "X-Frame-Options", frame } end
  local coop = opts.coop == nil and "same-origin" or opts.coop
  one_of(coop, { "same-origin", "same-origin-allow-popups", "unsafe-none", "" }, "coop")
  if coop ~= "" then fixed[#fixed + 1] = { "Cross-Origin-Opener-Policy", coop } end
  if opts.corp ~= nil then
    one_of(opts.corp, { "same-origin", "same-site", "cross-origin" }, "corp")
    fixed[#fixed + 1] = { "Cross-Origin-Resource-Policy", opts.corp }
  end
  add("Permissions-Policy", opts.permissions_policy, "camera=(), microphone=(), geolocation=()")

  local hsts: string = nil
  if opts.hsts ~= nil then
    local h = opts.hsts
    if math.type(h.max_age) ~= "integer" or h.max_age < 0 then
      error("headers: hsts.max_age is a number of seconds, 0 or more", 2)
    end
    if h.preload and not (h.include_subdomains and h.max_age >= 31536000) then
      error("headers: hsts.preload needs include_subdomains and a max_age of a year (31536000) or more", 2)
    end
    hsts = "max-age=" .. h.max_age .. (h.include_subdomains and "; includeSubDomains" or "") ..
      (h.preload and "; preload" or "")
  end

  local policy = opts.csp
  local csp_name = opts.csp_report_only and "Content-Security-Policy-Report-Only" or "Content-Security-Policy"
  if policy ~= nil then
    local directives: {string:{string}} = {}
    for name, sources in pairs(policy.directives) do directives[name] = sources end
    if directives["frame-ancestors"] == nil and frame ~= "" then
      directives["frame-ancestors"] = { frame == "DENY" and "'none'" or "'self'" }
    end
    policy = { directives = directives }
    local ok, why = pcall(Csp.format, policy, "x")
    if not ok then error("headers: " .. tostring(why), 2) end
    if uses_nonce(policy) and not opts.nonce then
      error("headers: the csp has a {nonce} source and nonce is not set", 2)
    end
  end
  local draw = opts.nonce == true
  -- Without a nonce the policy is one string for every request.
  local fixed_csp: string = nil
  if policy ~= nil and not uses_nonce(policy) then fixed_csp = Csp.format(policy) end

  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local nonce = req:get(Headers.NONCE) or ""
      if draw and nonce == "" then
        nonce = Codec.base64url((assert(Rand.entropy(16))))
      end
      req:set(Headers.NONCE, nonce)
      local res = inner(req)
      local adds: {{string}} = {}
      for _, each in ipairs(fixed) do
        if Response.header(res, each[1]) == nil then adds[#adds + 1] = each end
      end
      if hsts ~= nil and req.scheme == "https" and Response.header(res, "Strict-Transport-Security") == nil then
        adds[#adds + 1] = { "Strict-Transport-Security", hsts }
      end
      if policy ~= nil and Response.header(res, csp_name) == nil then
        adds[#adds + 1] = { csp_name, fixed_csp or Csp.format(policy, nonce ~= "" and nonce or nil) }
      end
      if draw then
        local cache = Response.header(res, "Cache-Control")
        local private = privately(cache)
        if private ~= cache then adds[#adds + 1] = { "Cache-Control", private } end
      end
      if #adds == 0 then return res end
      local out = Response.copy(res)
      for _, each in ipairs(adds) do Response.set_header(out, each[1], each[2]) end
      return out
    end
  end
end

return Headers
