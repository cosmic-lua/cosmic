--- htmx for a [`cosmic.web`] app: what a request says in its `HX-*`
--- headers, the response headers a handler answers with, a fragment or a
--- whole page by header, and the head of a page that loads the htmx the
--- binary carries.
---
---     local Htmx = require("cosmic.web.htmx")
---
---     local function items(req: Web.Request): Web.Response
---       local rows = Html.trust("<li>one</li>")
---       return Htmx.page(req, rows, function(content: Html.SafeHtml): Html.SafeHtml
---         return Html.concat({ Html.trust("<!doctype html><head>"), Htmx.head(),
---           Html.trust("</head><body><ul>"), content, Html.trust("</ul></body>") })
---       end)
---     end
---
--- - [`Htmx.request`] reads the headers htmx sends; [`Htmx.partial`] says
---   whether a request wants a fragment. Every one is client-controlled:
---   they pick a presentation and authorize nothing, and they are no
---   defense against cross-site requests.
--- - [`Htmx.apply`] writes a [`Htmx.Reply`]'s headers to a response,
---   refusing a redirect to another origin; [`Htmx.redirect_to`] answers
---   a redirect an htmx request can follow; [`Htmx.stop_polling`] ends an
---   `every 2s` poll.
--- - [`Htmx.head`] writes the `htmx-config` meta tag and the script tags,
---   with `integrity` values the binary computed from the bytes it serves
---   under `/_web/` ([`Web.app`]).

local Html = require("cosmic.html")
local Json = require("cosmic.json")
local Response = require("cosmic.web.response")
local Store = require("cosmic.store")
local Types = require("cosmic.web.types")

local record Htmx
  --- What an htmx request says of itself, from its `HX-*` headers.
  record Request
    --- `HX-Request: true`: htmx made the request.
    active: boolean
    --- `HX-Boosted: true`: the request is a boosted link or form.
    boosted: boolean
    --- `HX-History-Restore-Request: true`: htmx lost its cached page and
    --- asks for the whole document.
    history_restore: boolean
    --- `HX-Target`: the id of the target element.
    target: string
    --- `HX-Trigger`: the id of the element that triggered the request.
    trigger: string
    --- `HX-Trigger-Name`: the name of that element.
    trigger_name: string
    --- `HX-Current-URL`: the URL of the page, untrusted text: take it
    --- through [`Html.local_href`] before redirecting to it.
    current_url: string
    --- `HX-Prompt`: the answer to an `hx-prompt`.
    prompt: string
  end

  --- A named browser event for a `HX-Trigger` header.
  record Event
    --- The event's name: not empty, no comma, quote or control byte.
    name: string
    --- Becomes `event.detail`; nil sends an empty one.
    detail: any
  end

  --- The object form of `HX-Location`: a client-side navigation with
  --- htmx's options.
  record Location
    --- Where to go: a local path or a [`Html.SafeUrl`].
    path: string | Html.SafeUrl
    --- A CSS selector for the target element.
    target?: string
    --- How to swap, as `hx-swap`.
    swap?: string
    --- A CSS selector for the part of the response to swap.
    select?: string
    --- A CSS selector for the element the request is said to come from.
    source?: string
    --- An event to trigger on the source.
    event?: string
    --- Values to submit with the request.
    values: any
    --- Headers to send with the request.
    headers: any
  end

  --- The effects of a response on the page, each optional; written by
  --- [`Htmx.apply`].
  record Reply
    --- `HX-Redirect`: navigate the whole window.
    redirect?: string | Html.SafeUrl
    --- `HX-Location`: navigate without a reload.
    location?: string | Html.SafeUrl | Htmx.Location
    --- `HX-Push-Url`: push this URL, or with `false` push none.
    push_url?: string | Html.SafeUrl | boolean
    --- `HX-Replace-Url`: replace the URL in place, or with `false` leave it.
    replace_url?: string | Html.SafeUrl | boolean
    --- `HX-Refresh`: reload the page.
    refresh?: boolean
    --- `HX-Retarget`: a CSS selector to swap into instead.
    retarget?: string
    --- `HX-Reswap`: how to swap, as `hx-swap`.
    reswap?: string
    --- `HX-Reselect`: a CSS selector for the part of the response to swap.
    reselect?: string
    --- `HX-Trigger`: events to fire on receipt.
    trigger?: {Htmx.Event}
    --- `HX-Trigger-After-Swap`: events to fire after the swap.
    trigger_after_swap?: {Htmx.Event}
    --- `HX-Trigger-After-Settle`: events to fire after the settle.
    trigger_after_settle?: {Htmx.Event}
  end

  --- Overrides of the configuration [`Htmx.head`] writes; nil keeps each
  --- default.
  record Config
    --- `allowEval` (false): `hx-on`, trigger filters and `js:` values
    --- need it, and so does a CSP that allows `'unsafe-eval'`.
    allow_eval?: boolean
    --- `allowScriptTags` (false): run a `<script>` in swapped HTML.
    allow_script_tags?: boolean
    --- `historyCacheSize` (htmx's own); 0 keeps no snapshot of a page.
    history_cache_size?: integer
  end

  --- What [`Htmx.head`] takes.
  record HeadOptions
    --- Also load the SSE extension. The page still writes `hx-ext="sse"`.
    sse?: boolean
    --- Overrides of the configuration.
    config?: Htmx.Config
    --- A CSP nonce for the tags, also written as `inlineScriptNonce`.
    nonce?: string
    --- A URL prefix for the script paths (""): the files are served under
    --- `/_web/` at the app's root.
    prefix?: string
  end

  --- The file [`Htmx.path`] and [`Htmx.integrity`] name.
  enum Asset
    "htmx"
    "sse"
  end
  --- The version of htmx the binary serves.
  version: string
  --- The version of the SSE extension the binary serves.
  sse_version: string
end

--- A response header's value: no CR, LF or NUL, which the server would
--- refuse later, and no other control byte.
local function plain(value: string): boolean
  return not value:find("[%z\1-\31\127]")
end

--- The file `name` of the binary's web assets, else an error saying to
--- rebuild: a binary written before the table has none.
local function carried(name: string): Store.WebAsset
  local file, why = Store.web_asset(name)
  if file == nil then
    error("cosmic.web.htmx: " .. why .. " (a binary from before cosmic.web carries no web assets: rebuild it)", 0)
  end
  return file
end

local htmx_file = carried("htmx.min.js")
local sse_file = carried("htmx-ext-sse.min.js")

Htmx.version = htmx_file.version
Htmx.sse_version = sse_file.version

--- The path of an asset, which carries its version so its content never
--- changes there.
--- @param which Htmx.Asset | nil "htmx" (the default) or "sse"
--- @return string The path, for example `/_web/htmx-2.0.11.min.js`
function Htmx.path(which?: Htmx.Asset): string
  if which == "sse" then return "/_web/htmx-ext-sse-" .. sse_file.version .. ".min.js" end
  return "/_web/htmx-" .. htmx_file.version .. ".min.js"
end

--- The `integrity` attribute value of an asset: `sha384-` and the base64
--- SHA-384 of the bytes served at [`Htmx.path`], as the binary computed
--- them. For a layout that writes its own script tag.
--- @param which Htmx.Asset | nil "htmx" (the default) or "sse"
--- @return string The value
function Htmx.integrity(which?: Htmx.Asset): string
  if which == "sse" then return "sha384-" .. sse_file.sha384 end
  return "sha384-" .. htmx_file.sha384
end

--- The files the app serves under `/_web/`, by path.
--- @return {string: Store.WebAsset} The files and their hashes
function Htmx.assets(): {string: Store.WebAsset}
  return { [Htmx.path()] = htmx_file, [Htmx.path("sse")] = sse_file }
end

local function flag(request: Types.Request, name: string): boolean
  return request.headers[name] == "true"
end

--- What `req` says of itself in its `HX-*` headers. It reads, and raises
--- on no input.
---
--- Every field is chosen by the client: they say which presentation to
--- answer with and never who may do what.
--- @param req Types.Request The request
--- @return Htmx.Request What it says
function Htmx.request(req: Types.Request): Htmx.Request
  local headers = req.headers
  return {
    active = flag(req, "hx-request"), boosted = flag(req, "hx-boosted"),
    history_restore = flag(req, "hx-history-restore-request"),
    target = headers["hx-target"], trigger = headers["hx-trigger"],
    trigger_name = headers["hx-trigger-name"], current_url = headers["hx-current-url"],
    prompt = headers["hx-prompt"],
  }
end

--- Whether `req` wants a fragment: an htmx request that is neither
--- boosted nor a history restore, both of which swap a whole page.
--- @param req Types.Request The request
--- @return boolean Whether to answer with a fragment
function Htmx.partial(req: Types.Request): boolean
  local seen = Htmx.request(req)
  return seen.active and not seen.boosted and not seen.history_restore
end

--- A URL for a header that htmx follows: a string must be a reference
--- on this origin ([`Html.local_href`]); a [`Html.SafeUrl`] was vouched for.
local function url_of(what: string, url: string | Html.SafeUrl): string | nil, string
  if url is string then
    local checked = Html.raw_url(Html.local_href(url))
    if checked == "about:invalid" or checked == "" then
      return nil, "htmx: " .. what .. " is not a same-origin reference"
    end
    return checked
  end
  local raw = Html.raw_url(url)
  if raw == "" or not plain(raw) then
    return nil, "htmx: " .. what .. " is empty or holds a control byte"
  end
  return raw
end

--- A selector or other free text: not empty, no control byte.
local function text_of(what: string, value: any): string | nil, string
  if not (value is string) or value == "" or not plain(value) then
    return nil, "htmx: " .. what .. " is not a non-empty text without control bytes"
  end
  return value
end

local SWAPS <const>: {string} = { "innerHTML", "outerHTML", "textContent", "beforebegin",
  "afterbegin", "beforeend", "afterend", "delete", "none" }

--- Whether `value` starts with a style `hx-swap` knows, as a word.
local function swap_ok(value: string): boolean
  if not plain(value) then return false end
  for _, style in ipairs(SWAPS) do
    if value == style or value:sub(1, #style + 1) == style .. " " then return true end
  end
  return false
end

--- The JSON text of `value` for a header: ASCII only, as the header's
--- bytes reach htmx as Latin-1.
local function header_json(what: string, value: any): string | nil, string
  local text, why = Json.encode(value, { ascii = true })
  if text == nil then return nil, "htmx: " .. what .. ": " .. why end
  return text
end

--- The value of an event header: the names alone where no event has a
--- detail, else a JSON object of detail by name.
local function events_of(what: string, events: {Htmx.Event}): string | nil, string
  if #events == 0 then return nil, "htmx: " .. what .. " names no event" end
  local detailed = false
  for _, event in ipairs(events) do
    local name = event.name
    if not (name is string) or name == "" or name:find("[,\"'\\%z\1-\31\127]") or
        name:find("^{") then
      return nil, "htmx: " .. what .. ": an event name is empty, starts with a brace or holds a comma, a quote or a control byte"
    end
    if event.detail ~= nil then detailed = true end
  end
  local parts: {string} = {}
  for i, event in ipairs(events) do
    if not detailed then
      if event.name:find("[\128-\255]") then
        return nil, "htmx: " .. what .. ": an event name without a detail holds a byte past ASCII"
      end
      parts[i] = event.name
    else
      local key, key_why = header_json(what, event.name)
      if key == nil then return nil, key_why end
      local body = "{}"
      if event.detail ~= nil then
        local encoded, why = header_json(what, event.detail)
        if encoded == nil then return nil, why end
        body = encoded
      end
      parts[i] = key .. ":" .. body
    end
  end
  if not detailed then return table.concat(parts, ", ") end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- Writes `reply` to `res` as `HX-*` headers. Nothing is written where
--- anything is refused: a URL that is not a reference on this origin
--- (a `javascript:` URL or `//evil.example` would be an XSS or an open
--- redirect, as htmx navigates to it by script) unless it is a
--- [`Html.SafeUrl`] the program vouched for; a selector or a swap htmx
--- would not read; an event with a bad name; a value JSON cannot hold.
--- Header JSON is ASCII, escaped as `\uXXXX`, because htmx reads the bytes as
--- Latin-1.
--- @param res Types.Response The response to write to
--- @param reply Htmx.Reply The effects
--- @return Types.Response | nil The same response, or nil
--- @return string Why it was refused
function Htmx.apply(res: Types.Response, reply: Htmx.Reply): Types.Response | nil, string
  local lines: {{string}} = {}
  local function put(name: string, value: string)
    lines[#lines + 1] = { name, value }
  end
  if reply.redirect ~= nil then
    local url, why = url_of("redirect", reply.redirect)
    if url == nil then return nil, why end
    put("HX-Redirect", url)
  end
  if reply.location ~= nil then
    local location = reply.location
    if location is Htmx.Location then
      local path, why = url_of("location path", location.path)
      if path == nil then return nil, why end
      local object: {string: any} = { path = path, values = location.values, headers = location.headers }
      for _, pair in ipairs({ { "target", location.target }, { "swap", location.swap },
          { "select", location.select }, { "source", location.source }, { "event", location.event } }) do
        if pair[2] ~= nil then
          local ok, trouble = text_of("location " .. pair[1], pair[2])
          if ok == nil then return nil, trouble end
          object[pair[1]] = ok
        end
      end
      local text, json_why = header_json("location", object)
      if text == nil then return nil, json_why end
      put("HX-Location", text)
    else
      local url, why = url_of("location", location)
      if url == nil then return nil, why end
      put("HX-Location", url)
    end
  end
  local function url_field(label: string, header: string, value: string | Html.SafeUrl | boolean | nil): string | nil
    if value == nil then return nil end
    if value is boolean then
      put(header, value and "true" or "false")
      return nil
    end
    local url, why = url_of(label, value)
    if url == nil then return why end
    put(header, url)
    return nil
  end
  local trouble = url_field("push_url", "HX-Push-Url", reply.push_url) or
    url_field("replace_url", "HX-Replace-Url", reply.replace_url)
  if trouble ~= nil then return nil, trouble end
  if reply.refresh then put("HX-Refresh", "true") end
  if reply.retarget ~= nil then
    local text, why = text_of("retarget", reply.retarget)
    if text == nil then return nil, why end
    put("HX-Retarget", text)
  end
  if reply.reselect ~= nil then
    local text, why = text_of("reselect", reply.reselect)
    if text == nil then return nil, why end
    put("HX-Reselect", text)
  end
  local swap: any = reply.reswap
  if swap ~= nil then
    if type(swap) ~= "string" or not swap_ok(swap) then
      return nil, "htmx: reswap is not a swap style htmx knows, with modifiers"
    end
    put("HX-Reswap", swap)
  end
  local function events_field(label: string, header: string, events: {Htmx.Event} | nil): string | nil
    if events == nil then return nil end
    local text, why = events_of(label, events)
    if text == nil then return why end
    put(header, text)
    return nil
  end
  trouble = events_field("trigger", "HX-Trigger", reply.trigger) or
    events_field("trigger_after_swap", "HX-Trigger-After-Swap", reply.trigger_after_swap) or
    events_field("trigger_after_settle", "HX-Trigger-After-Settle", reply.trigger_after_settle)
  if trouble ~= nil then return nil, trouble end
  for _, line in ipairs(lines) do Response.set_header(res, line[1], line[2]) end
  return res
end

--- A redirect to `url` that the client follows: for an htmx request that
--- is not boosted, an empty 200 with `HX-Redirect` (an XHR would follow
--- a 302 and swap the other page into the target); otherwise the
--- ordinary 303 redirect, which a boosted request's XHR follows and
--- swaps whole. A string is checked as [`Htmx.apply`] checks one.
--- @param req Types.Request The request being answered
--- @param url string | Html.SafeUrl Where to
--- @return Types.Response | nil The response, or nil
--- @return string Why `url` was refused
function Htmx.redirect_to(req: Types.Request, url: string | Html.SafeUrl): Types.Response | nil, string
  local target, why = url_of("redirect", url)
  if target == nil then return nil, why end
  local seen = Htmx.request(req)
  if seen.active and not seen.boosted then
    return Htmx.apply(Response.empty(200), { redirect = Html.trust_url(target) })
  end
  local made: Types.Response | nil = nil
  local ok = pcall(function() made = Response.redirect(target) end)
  if not ok then return nil, "htmx: redirect is not a path or an http(s) URL" end
  return made
end

local VARY <const>: {string} = { "HX-Request", "HX-History-Restore-Request", "HX-Boosted" }

--- Answers `req` with `content` alone when it is a fragment request
--- ([`Htmx.partial`]), else with `wrap(content)`, the whole page. Both carry
--- `Vary` for the headers the choice reads, so a cache keeps the two
--- apart, and `Cache-Control: no-cache` unless the response has one, so
--- that Back never shows a stale fragment.
--- @param req Types.Request The request
--- @param content Html.SafeHtml The fragment
--- @param wrap function(Html.SafeHtml): Html.SafeHtml Makes the page of the fragment
--- @return Types.Response The response
function Htmx.page(req: Types.Request, content: Html.SafeHtml,
                   wrap: function(Html.SafeHtml): Html.SafeHtml): Types.Response
  local res = Response.html(Htmx.partial(req) and content or wrap(content))
  for _, token in ipairs(VARY) do Response.add_header(res, "Vary", token) end
  if Response.header(res, "Cache-Control") == nil then
    Response.set_header(res, "Cache-Control", "no-cache")
  end
  return res
end

--- A 286 response: htmx swaps it in and stops the `every` poll that asked.
--- A poll that goes on answers 200.
--- @param body Html.SafeHtml | nil The last content to swap, if any
--- @return Types.Response The response
function Htmx.stop_polling(body?: Html.SafeHtml): Types.Response
  return Response.html(body or Html.trust(""), { status = 286 })
end

--- The configuration of every page: the keys are htmx's own.
local function config_of(opts: Htmx.HeadOptions): {string: any}
  local config = opts.config or {}
  local out: {string: any} = {
    allowEval = config.allow_eval == true,
    allowScriptTags = config.allow_script_tags == true,
    includeIndicatorStyles = false,
    selfRequestsOnly = true,
    responseHandling = {
      { code = "204", swap = false },
      { code = "[23]..", swap = true },
      { code = "422", swap = true, error = true },
      { code = "[45]..", swap = false, error = true },
      { code = "...", swap = false },
    },
  }
  if config.history_cache_size ~= nil then out.historyCacheSize = config.history_cache_size end
  if opts.nonce ~= nil then out.inlineScriptNonce = opts.nonce end
  return out
end

--- One script tag: the parts are the binary's own or escaped.
local function script_tag(which: Htmx.Asset, opts: Htmx.HeadOptions): string
  local nonce = opts.nonce ~= nil and (' nonce="' .. Html.raw_attr(Html.escape_attr(opts.nonce)) .. '"') or ""
  local prefix = opts.prefix or ""
  return '<script src="' .. prefix .. Htmx.path(which) .. '" integrity="' .. Htmx.integrity(which) ..
    '" crossorigin="anonymous"' .. nonce .. " defer></script>"
end

--- The `<meta name="htmx-config">` tag and the script tags of htmx (and of
--- its SSE extension where `opts.sse`) for the head of a page. The
--- configuration is closed: no eval, no scripts in swapped HTML, no injected
--- style (see [`Htmx.indicator_css`]), same-origin requests only, and
--- responses swapped for 2xx and 422 and not for 204; a 4xx or 5xx other
--- than 422 fires `htmx:responseError` and is not swapped. `opts.config`
--- loosens only what [`Htmx.Config`] names. The script's `src` is
--- [`Htmx.path`] and its `integrity` [`Htmx.integrity`].
--- @param opts Htmx.HeadOptions | nil What to add or change; a `prefix` that is no path raises
--- @return Html.SafeHtml The tags
function Htmx.head(opts?: Htmx.HeadOptions): Html.SafeHtml
  opts = opts or {}
  if opts.prefix ~= nil and opts.prefix ~= "" and
      not (opts.prefix:find("^/[%w._~/-]*$") and not opts.prefix:find("^//") and opts.prefix:sub(-1) ~= "/") then
    error("htmx: head: the prefix is a path on this origin without a trailing slash, like /app", 2)
  end
  if opts.nonce ~= nil and opts.nonce:find("[%z\1-\31\127]") then
    error("htmx: head: the nonce is text without a control byte", 2)
  end
  local json = assert(Html.json(config_of(opts)))
  -- Everything written here is the binary's own constants or has been
  -- through Html.escape_attr.
  local tags = { '<meta name="htmx-config" content="' ..
      Html.raw_attr(Html.escape_attr(Html.raw_json(json))) .. '">', script_tag("htmx", opts) }
  if opts.sse then tags[#tags + 1] = script_tag("sse", opts) end
  return Html.trust(table.concat(tags, "\n"))
end

--- The CSS for the `htmx-indicator` class, which htmx would otherwise inject
--- as an inline `<style>` that a strict `style-src` refuses
--- ([`Htmx.head`] turns that off). Put it in the app's stylesheet.
--- @return string The rules
function Htmx.indicator_css(): string
  return ".htmx-indicator{opacity:0;visibility:hidden}\n" ..
    ".htmx-request .htmx-indicator,.htmx-request.htmx-indicator{opacity:1;" ..
    "visibility:visible;transition:opacity 200ms ease-in}\n"
end

return Htmx
