--- Security headers and a Content-Security-Policy for [`cosmic.web`], set
--- by one middleware on every response that passes out through it. The
--- policy is a [`cosmic.web.csp`] `Policy`.
---
---     local Csp = require("cosmic.web.csp")
---     middleware = {
---       Headers.middleware{
---         csp = Csp.htmx_default(),
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
local Csp = require("cosmic.web.csp")
local Rand = require("cosmic.rand")
local Request = require("cosmic.web.request")
local Response = require("cosmic.web.response")
local Types = require("cosmic.web.types")

local record Headers
  --- A Strict-Transport-Security policy.
  record Hsts
    --- Seconds the browser remembers (required).
    max_age: integer
    --- Add `includeSubDomains` (false).
    include_subdomains?: boolean
    --- Add `preload` (false); needs `include_subdomains` and a `max_age`
    --- of a year or more.
    preload?: boolean
  end

  --- What [`Headers.middleware`] takes; every field is optional.
  record Options
    --- X-Content-Type-Options: nosniff (true).
    nosniff?: boolean
    --- Referrer-Policy ("strict-origin-when-cross-origin"; "" omits).
    referrer_policy?: string
    --- X-Frame-Options: "DENY" (default), "SAMEORIGIN" or "" for none. A
    --- `csp` without a `frame-ancestors` directive gets the matching one
    --- ('none' or 'self').
    frame_options?: string
    --- Cross-Origin-Opener-Policy ("same-origin"; "" omits).
    coop?: string
    --- Cross-Origin-Resource-Policy: omitted unless set to "same-origin",
    --- "same-site" or "cross-origin".
    corp?: string
    --- Permissions-Policy ("camera=(), microphone=(), geolocation=()"; "" omits).
    permissions_policy?: string
    --- Strict-Transport-Security, sent on https requests only; nil omits.
    hsts?: Hsts
    --- The Content-Security-Policy; nil sends none.
    csp?: Csp.Policy
    --- Send the policy as Content-Security-Policy-Report-Only (false).
    csp_report_only?: boolean
    --- Draw a nonce for each request (false): see [`Headers.NONCE`].
    nonce?: boolean
  end

  --- The request's CSP nonce, "" where no [`Headers.middleware`] with `nonce`
  --- is above the handler.
  NONCE: Types.Key<string>
end

Headers.NONCE = Request.key("csp-nonce")

--- Whether the policy has a "{nonce}" source.
local function uses_nonce(p: Csp.Policy): boolean
  for _, sources in pairs(p.directives) do
    for _, source in ipairs(sources) do
      if source == "{nonce}" then return true end
    end
  end
  return false
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
local function privately(cache: string?): string
  if cache == nil then return "private" end
  local kept: mut {string} = {}
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
  local fixed: mut {{string}} = {}
  if opts.nosniff ~= false then fixed[#fixed + 1] = { "X-Content-Type-Options", "nosniff" } end
  local function add(name: string, value: string?, default: string)
    local text = plain(value == nil and default or value, name)
    if text ~= "" then fixed[#fixed + 1] = { name, text } end
  end
  add("Referrer-Policy", opts.referrer_policy, "strict-origin-when-cross-origin")
  local frame_options = opts.frame_options
  local frame = if frame_options == nil then "DENY" else frame_options end
  one_of(frame, { "DENY", "SAMEORIGIN", "" }, "frame_options")
  if frame ~= "" then fixed[#fixed + 1] = { "X-Frame-Options", frame } end
  local opts_coop = opts.coop
  local coop = if opts_coop == nil then "same-origin" else opts_coop end
  one_of(coop, { "same-origin", "same-origin-allow-popups", "unsafe-none", "" }, "coop")
  if coop ~= "" then fixed[#fixed + 1] = { "Cross-Origin-Opener-Policy", coop } end
  local corp = opts.corp
  if corp ~= nil then
    one_of(corp, { "same-origin", "same-site", "cross-origin" }, "corp")
    fixed[#fixed + 1] = { "Cross-Origin-Resource-Policy", opts.corp }
  end
  add("Permissions-Policy", opts.permissions_policy, "camera=(), microphone=(), geolocation=()")

  local hsts: string? = nil
  local opts_hsts = opts.hsts
  if opts_hsts ~= nil then
    local h = opts_hsts
    if math.type(h.max_age) ~= "integer" or h.max_age < 0 then
      error("headers: hsts.max_age is a number of seconds, 0 or more", 2)
    end
    if h.preload and not (h.include_subdomains and h.max_age >= 31536000) then
      error("headers: hsts.preload needs include_subdomains and a max_age of a year (31536000) or more", 2)
    end
    hsts = "max-age=" .. tostring(h.max_age) .. (if h.include_subdomains then "; includeSubDomains" else "" end) ..
      (if h.preload then "; preload" else "" end)
  end

  local policy = opts.csp
  local csp_name = if opts.csp_report_only then "Content-Security-Policy-Report-Only" else "Content-Security-Policy" end
  if policy ~= nil then
    local directives: mut {string:{string}} = {}
    for name, sources in pairs(policy.directives) do directives[name] = sources end
    if directives["frame-ancestors"] == nil and frame ~= "" then
      directives["frame-ancestors"] = { if frame == "DENY" then "'none'" else "'self'" end }
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
  local fixed_csp: string? = nil
  if policy ~= nil and not uses_nonce(policy) then fixed_csp = Csp.format(policy) end

  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local nonce = req:get(Headers.NONCE) or ""
      if draw and nonce == "" then
        nonce = Codec.base64url((assert(Rand.entropy(16))))
      end
      req:set(Headers.NONCE, nonce)
      local res = inner(req)
      local adds: mut {{string}} = {}
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
