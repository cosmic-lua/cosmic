--- Constructors for the [`Web.Response`] a handler returns, and the helpers
--- that read and add its headers. A constructor builds the table the
--- server expects and touches no connection.

local Html = require("cosmic.html")
local Json = require("cosmic.json")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")

local record Response
  --- What [`Web.abort`] raises, for the exception layer to answer.
  record Abort
    --- Marks the table as an abort.
    web_abort: boolean
    --- The status to answer.
    status: integer
    --- What to tell the client, or nil.
    detail: string
    --- More members of a problem body.
    extra: {string:any}
  end
end

local REDIRECTS <const>: {integer:boolean} = {
  [301] = true, [302] = true, [303] = true, [307] = true, [308] = true,
}

--- The name under which `headers` holds `name`, in any case, or nil.
local function key_of(headers: {string: string | {string}}, name: string): string | nil
  local want = name:lower()
  local found: string = nil
  for key in pairs(headers) do
    if key:lower() == want and (found == nil or key < found) then found = key end
  end
  return found
end

--- Sets header `name` of `res` to a string or a list, replacing the
--- header in any case; the first of the two helpers below.
local function put(res: Types.Response, name: string, value: string | {string})
  if res.headers == nil then res.headers = {} end
  local headers = res.headers
  local want = name:lower()
  local stale: {string} = {}
  for key in pairs(headers) do
    if key:lower() == want then stale[#stale + 1] = key end
  end
  for _, key in ipairs(stale) do headers[key] = nil end
  if value is string then
    headers[name] = value
  else
    local copy: {string} = {}
    for i, line in ipairs(value) do copy[i] = line end
    headers[name] = copy
  end
end

--- The first value of header `name` of `res`, matched in any case; nil
--- when it has none.
--- @param res Types.Response The response
--- @param name string The header's name
--- @return string | nil The first line of its value
function Response.header(res: Types.Response, name: string): string | nil
  if res.headers == nil then return nil end
  local key = key_of(res.headers, name)
  if key == nil then return nil end
  local value = res.headers[key]
  if value is string then return value end
  return value[1]
end

--- Sets header `name` to `value`, replacing the header in every case of
--- its name. Raises for Set-Cookie, whose every line this would drop:
--- append one with [`Web.add_header`].
--- @param res Types.Response The response
--- @param name string The header's name
--- @param value string The value
function Response.set_header(res: Types.Response, name: string, value: string)
  if name:lower() == "set-cookie" then
    error("web: set_header on Set-Cookie would replace every cookie; use add_header", 2)
  end
  put(res, name, value)
end

--- The tokens of a Vary line, lowercase.
local function tokens(value: string): {string}
  local out: {string} = {}
  for token in value:gmatch("[^,%s]+") do out[#out + 1] = token:lower() end
  return out
end

--- A copy of `res` with headers of its own, which a middleware may add to
--- without touching the original: a handler may return a response it shares
--- (a module-level `Web.text("not found")`), and a `Set-Cookie` or a CSP
--- added to that one would go to every later request. The body is shared (a
--- Reader is not copied), and the copy holds every field of a reply, as the
--- server refuses one it does not know.
--- @param res Types.Response The response
--- @return Types.Response The copy
function Response.copy(res: Types.Response): Types.Response
  local headers: {string: string | {string}} = {}
  for name, value in pairs(res.headers or {}) do
    if value is string then
      headers[name] = value
    else
      local lines: {string} = {}
      for i, line in ipairs(value) do lines[i] = line end
      headers[name] = lines
    end
  end
  return { status = res.status, headers = headers, body = res.body, length = res.length, close = res.close }
end

--- Appends `value` to header `name`, which keeps the lines it has: a
--- string value becomes a list. `Vary` is merged instead of repeated: a
--- token already listed (in any case) is not added again, and `*` absorbs
--- every other. This is how a `Set-Cookie` line or a `Vary` token is added.
--- It changes `res` in place, headers and all: a response shared between
--- requests (a module-level `Web.text("not found")`) gets the line for every
--- later request too, so a middleware that adds to a response it did not
--- make copies it first with [`Response.copy`], as [`cosmic.web.session`]'s
--- does.
--- @param res Types.Response The response
--- @param name string The header's name
--- @param value string The line to add
function Response.add_header(res: Types.Response, name: string, value: string)
  if res.headers == nil then res.headers = {} end
  local headers = res.headers
  local key = key_of(headers, name)
  if name:lower() == "vary" then
    local old = ""
    if key ~= nil then
      local lines = headers[key]
      if lines is string then
        old = lines
      else
        old = table.concat(lines, ", ")
      end
    end
    local have: {string:boolean} = {}
    for _, token in ipairs(tokens(old)) do have[token] = true end
    if have["*"] then return end
    local add: {string} = {}
    for piece in value:gmatch("[^,%s]+") do
      local token = piece:lower()
      if token == "*" then
        put(res, key or name, "*")
        return
      end
      if not have[token] then
        have[token] = true
        add[#add + 1] = piece
      end
    end
    if #add == 0 then return end
    local line = table.concat(add, ", ")
    put(res, key or name, old == "" and line or (old .. ", " .. line))
    return
  end
  if key == nil then
    headers[name] = value
    return
  end
  local old = headers[key]
  if old is string then
    headers[key] = { old, value }
  else
    old[#old + 1] = value
  end
end

--- `why`, [`Json.encode`]'s, without the "json: " it starts with.
local function unprefixed(why: string): string
  return (why:gsub("^json: ", ""))
end

--- Raises, for the constructor's caller, where `status` is no status the
--- server can send: [`Server.Reply`] takes an integer from 200 to 999.
local function check_status(status: any, level: integer)
  if not (status is integer and status >= 200 and status <= 999) then
    error("web: a response's status must be an integer from 200 to 999, not " .. tostring(status), level)
  end
end

--- Applies `opts` to `res`.
local function finish(res: Types.Response, opts: Types.ResponseOptions | nil): Types.Response
  if opts == nil then return res end
  if opts.status ~= nil then
    check_status(opts.status, 4)
    res.status = opts.status
  end
  if opts.close ~= nil then res.close = opts.close end
  if opts.length ~= nil then res.length = opts.length end
  if opts.headers ~= nil then
    for name, value in pairs(opts.headers) do put(res, name, value) end
  end
  return res
end

--- `body` as an HTML page or fragment, `text/html; charset=utf-8`. Only
--- [`Html.SafeHtml`] is taken: a string is a type error, and
--- [`Html.trust`] is the greppable way to vouch for one.
--- @param body Html.SafeHtml The markup
--- @param opts ResponseOptions | nil Status 200 unless it says
--- @return Types.Response The response
function Response.html(body: Html.SafeHtml, opts?: Types.ResponseOptions): Types.Response
  return finish({ status = 200, headers = { ["Content-Type"] = "text/html; charset=utf-8" },
    body = Html.raw(body) }, opts)
end

--- `value` encoded by [`Json.encode`], `application/json` with
--- `X-Content-Type-Options: nosniff`. A value that cannot be encoded (a
--- cycle, a function) is the program's fault: this raises, and the
--- exception layer answers 500.
--- @param value any The value
--- @param opts ResponseOptions | nil Status 200 unless it says
--- @return Types.Response The response
function Response.json(value: any, opts?: Types.ResponseOptions): Types.Response
  local text, why = Json.encode(value)
  if text == nil then error("web: json: " .. unprefixed(why), 2) end
  return finish({ status = 200, headers = { ["Content-Type"] = "application/json",
    ["X-Content-Type-Options"] = "nosniff" }, body = text }, opts)
end

--- `body` as `text/plain; charset=utf-8`, with `X-Content-Type-Options:
--- nosniff`.
--- @param body string The text
--- @param opts ResponseOptions | nil Status 200 unless it says
--- @return Types.Response The response
function Response.text(body: string, opts?: Types.ResponseOptions): Types.Response
  return finish({ status = 200, headers = { ["Content-Type"] = "text/plain; charset=utf-8",
    ["X-Content-Type-Options"] = "nosniff" }, body = body }, opts)
end

--- Whether `target` is a path on this origin: it starts with exactly one
--- "/" (`//host` and `/\host` are read by a browser as another origin)
--- and holds no control byte.
--- @param target string The text
--- @return boolean Whether it is a local path
function Response.local_path(target: string): boolean
  if target:sub(1, 1) ~= "/" then return false end
  local second = target:sub(2, 2)
  if second == "/" or second == "\\" then return false end
  return not target:find("[%z\1-\31\127]")
end

--- Whether `target` is an absolute http or https URL; if it is not, why,
--- or "" where it does not even start as one.
local function absolute_url(target: string): boolean, string
  if not target:find("^[Hh][Tt][Tt][Pp][Ss]?://") then return false, "" end
  if target:find("[%z\1-\31\127]") then return false, "it holds a control byte" end
  local parts, why = Url.parse(target)
  if parts == nil then return false, why end
  return true, ""
end

--- A redirect to `location`, 303 See Other by default, which a browser
--- follows with a GET after a POST; `opts.status` may be 301, 302, 303,
--- 307 or 308. The location must be a local path ([`Web.local_path`]) or an
--- absolute http or https URL, or this raises. An absolute URL passes, to
--- any host: a program redirects to one it chose, and takes a target a
--- client sent through [`Web.safe_next`], which accepts a local path alone
--- and is the guard against an open redirect (`next=//evil.com`,
--- `next=https://evil.com`); this raising is only a check of the
--- program's own targets.
--- @param location string Where to
--- @param opts ResponseOptions | nil Status 303 unless it says
--- @return Types.Response The response
function Response.redirect(location: string, opts?: Types.ResponseOptions): Types.Response
  if type(location) ~= "string" then error("web: redirect takes a string location", 2) end
  local status = opts and opts.status or 303
  if not REDIRECTS[status] then
    error("web: a redirect's status must be 301, 302, 303, 307 or 308, not " .. tostring(status), 2)
  end
  if not Response.local_path(location) then
    local absolute, why = absolute_url(location)
    if not absolute then
      error(("web: redirect to %q: not a local path or an http(s) URL%s"):format(location,
        why ~= "" and " (" .. why .. ")" or ""), 2)
    end
  end
  return finish({ status = status, headers = { Location = location } }, opts)
end

--- `input` where it is a local path, else `default`: for a redirect target
--- a client sent, such as a login's `next`.
--- @param input string | nil What the client sent
--- @param default string Where to go otherwise, a local path
--- @return string The target
function Response.safe_next(input: string | nil, default: string): string
  if input ~= nil and Response.local_path(input) then return input end
  return default
end

--- An empty reply, 204 No Content by default. `status = 200` gives an
--- empty 200 with `Content-Length: 0`.
--- @param status integer | nil The status
--- @param opts ResponseOptions | nil More
--- @return Types.Response The response
function Response.empty(status?: integer, opts?: Types.ResponseOptions): Types.Response
  if status ~= nil then check_status(status, 3) end
  return finish({ status = status or 204, headers = {} }, opts)
end

--- A reply whose body is a Reader the server reads as it writes: chunked
--- unless `opts.length` says its size, and closed by the server when sent
--- or abandoned. `X-Content-Type-Options: nosniff` is set, as for the
--- other constructors.
--- @param body Stream.Reader The body
--- @param content_type string Its Content-Type
--- @param opts ResponseOptions | nil Status 200 unless it says
--- @return Types.Response The response
function Response.stream(body: Stream.Reader, content_type: string, opts?: Types.ResponseOptions): Types.Response
  return finish({ status = 200, headers = { ["Content-Type"] = content_type,
    ["X-Content-Type-Options"] = "nosniff" }, body = body }, opts)
end

-- TODO: Web.file (ETag, Last-Modified, 304 and Range by Server.none_match and
-- Server.range, the type from cosmic.mime) for a handler that serves one
-- file; cosmic.web.static has the conditional and range logic, to be shared
-- once a second caller needs it.

--- An RFC 9457 `application/problem+json` reply:
--- `{type:"about:blank", title:<reason>, status, detail, ...extra}`. A
--- member of `extra` named `status` is ignored; the others, `type` and
--- `title` included, replace the defaults.
--- @param status integer The status
--- @param detail string | nil What the client may be told
--- @param extra {string:any} | nil More members
--- @return Types.Response The response
function Response.problem(status: integer, detail?: string, extra?: {string:any}): Types.Response
  check_status(status, 3)
  local reason = Server.reason(status)
  local body: {string:any} = { type = "about:blank", title = reason ~= "" and reason or "Error" }
  if extra ~= nil then
    for name, value in pairs(extra) do body[name] = value end
  end
  body.status = status
  body.detail = detail
  local text, why = Json.encode(body)
  if text == nil then error("web: problem: " .. unprefixed(why), 2) end
  return { status = status, headers = { ["Content-Type"] = "application/problem+json",
    ["X-Content-Type-Options"] = "nosniff" }, body = text }
end

--- Ends the request with `status`: raises, and the exception layer answers
--- with the app's error page for it, negotiated by Accept, with `detail`
--- (and `extra` in a problem body). It is declared to return a response so
--- `return Web.abort(404)` type-checks.
--- @param status integer The status
--- @param detail string | nil What the client may be told
--- @param extra {string:any} | nil More members of a problem body
--- @return Types.Response Never
function Response.abort(status: integer, detail?: string, extra?: {string:any}): Types.Response
  if not (math.type(status) == "integer" and status >= 400 and status <= 599) then
    error("web: abort takes an error status, from 400 to 599", 2)
  end
  local abort: Response.Abort = { web_abort = true, status = status, detail = detail, extra = extra }
  error(abort, 0)
end

--- The abort `err` is, or nil when it is any other raise.
--- @param err any What was raised
--- @return Response.Abort | nil The abort
function Response.aborted(err: any): Response.Abort | nil
  if not (err is {string:any} and err.web_abort == true) then return nil end
  local status, detail, extra = err.status, err.detail, err.extra
  if not status is integer then return nil end
  local abort: Response.Abort = { web_abort = true, status = status }
  if detail is string then abort.detail = detail end
  if extra is {string:any} then abort.extra = extra end
  return abort
end

return Response
