--- The request a handler is given: the server's, wrapped, with the
--- canonical path, the client and the scheme resolved, and the typed
--- per-request state of [`Web.key`].

local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")
local Negotiate = require("cosmic.web.negotiate")
local Server = require("cosmic.http.server")
local Url = require("cosmic.url")
local String = require("cosmic.string")

local record Request
  --- A path as the app resolved it: what [`Request.new`] is built from.
  record Parts
    --- The canonical path.
    path: string
    --- Its decoded segments.
    segments: {string}
    --- Whether it ends in "/" after a segment.
    trailing: boolean
  end

  --- A Host header read: see [`Request.parse_host`].
  record HostPort
    --- The lowercase host: a name, or an IPv6 literal in brackets.
    host: string
    --- The port, or nil where the header names none.
    port?: integer
  end
end

local type Req = Types.Request

--- A key for a typed value of the request or the app: see [`Web.key`].
--- @param name string The name, for messages
--- @return Types.Key<T> The key
function Request.key<T>(name: string): Types.Key<T>
  if type(name) ~= "string" or name == "" then
    error("web: key takes a name", 2)
  end
  return { name = name }
end

--- The key under which a request keeps its decoded query.
local QUERY: Types.Key<Url.Query> = Request.key("query")

--- Whether `text` is an IPv4 address in dotted decimal.
local function ipv4(text: string): boolean
  local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil then return false end
  for _, octet in ipairs({ a, b, c, d }) do
    if #octet > 3 or (math.tointeger(tonumber(octet)) or 256) > 255 then return false end
  end
  return true
end

--- Whether `text` is an IPv4 or IPv6 address literal, without brackets.
local function ip_literal(text: string): boolean
  if text:find(":", 1, true) then
    local parts, _ = Url.parse("http://[" .. text .. "]/")
    return parts ~= nil
  end
  return ipv4(text)
end

--- Reads `value`, a Host header, whole: a name of letters, digits, "." and
--- "-", or an IPv6 literal in brackets, then optionally ":" and a port of
--- one to five digits, 65535 at most. Nothing else is a host, so what
--- follows a host cannot smuggle in userinfo or a path (`good.com:@evil.com`).
--- @param value string The header's value
--- @return Request.HostPort | nil The host and port, nil where `value` is neither
function Request.parse_host(value: string): Request.HostPort | nil
  local lower = value:lower()
  local host, tail: string, string
  if lower:sub(1, 1) == "[" then
    local inner, rest = lower:match("^%[([%x:.]+)%](.*)$")
    if inner == nil or not inner:find(":", 1, true) or not ip_literal(inner) then return nil end
    host, tail = "[" .. inner .. "]", rest
  else
    host, tail = lower:match("^([%w.%-]+)(.*)$")
    if host == nil then return nil end
  end
  if tail == "" then return { host = host } end
  local digits = tail:match("^:(%d+)$")
  if digits == nil or #digits > 5 then return nil end
  local port = math.tointeger(tonumber(digits))
  if port == nil or port > 65535 then return nil end
  return { host = host, port = port }
end

local function header(self: Req, name: string): string | nil
  return self.headers[name:lower()]
end

local function bytes(self: Req): string | nil, string
  if self.body_text ~= nil then return self.body_text, "" end
  if self.body_failure ~= nil then return nil, self.body_failure end
  local data, why = Stream.read_all(self.raw.body)
  if data == nil then
    -- The reader is spent: a second call answers the same failure.
    self.body_failure = why
    return nil, why
  end
  self.body_text = data
  self.raw.body = Stream.from_string(data)
  return data, ""
end

local function text(self: Req): string | nil, string
  local data, why = bytes(self)
  if data == nil then return nil, why end
  if not utf8.len(data) then return nil, "web: the body is not valid UTF-8" end
  return data, ""
end

local function get<T>(self: Req, key: Types.Key<T>): T | nil
  -- cast: a slot holds the T that `set` stored under this very key.
  return self.slots[key] as T
end

local function set<T>(self: Req, key: Types.Key<T>, value: T)
  self.slots[key] = value
end

local function query(self: Req): Url.Query | nil, string
  local cached = get(self, QUERY)
  if cached ~= nil then return cached, "" end
  local decoded, why = Url.decode_query(self.query_string)
  if decoded == nil then return nil, why end
  set(self, QUERY, decoded)
  return decoded, ""
end

local function accepts(self: Req, offers: {string}): string | nil
  return Negotiate.best(self.headers["accept"], offers)
end

local function url_for(self: Req, name: string, params?: {string: string | integer},
                       queries?: {string:string}): string | nil, string
  return self.app:url_for(name, params, queries)
end

local function base_url(self: Req): string | nil, string
  if self.app.spec.trusted_hosts == nil then
    return nil, "web: base_url needs trusted_hosts, since the Host header is the client's"
  end
  if self.host == nil then return nil, "web: the request names no host" end
  local parsed = Request.parse_host(self.host)
  if parsed == nil then return nil, "web: the request's host is not a host name" end
  return self.scheme .. "://" .. parsed.host .. (parsed.port ~= nil and ":" .. parsed.port or ""), ""
end

local methods = {
  header = header, bytes = bytes, text = text, query = query, accepts = accepts,
  url_for = url_for, get = get, set = set, base_url = base_url,
}

local request_mt: metatable<Req> = { __index = methods }

--- The last entry of a comma-separated forwarding header: the one the
--- proxy next to the app added, since the entries before it are the
--- client's to write. Nil for none.
local function last_entry(value: string | nil): string | nil
  if value == nil then return nil end
  -- Found from the end: `([^,]*)$` retries at every byte of a long entry.
  local comma = value:reverse():find(",", 1, true)
  local entry = String.trim(comma == nil and value or value:sub(#value - comma + 2))
  if entry == "" then return nil end
  return entry
end

--- Wraps `raw`, the server's request, for `app`, with the path `parts`
--- the app made canonical.
--- @param app Types.App The app serving the request
--- @param raw Server.Request The request
--- @param parts Request.Parts The canonical path
--- @return Types.Request The request
function Request.new(app: Types.App, raw: Server.Request, parts: Request.Parts): Types.Request
  local headers = raw.headers
  local scheme = "http"
  local host = headers["host"]
  local client: Types.Client = nil
  if raw.peer ~= nil and raw.peer.kind == "tcp" then
    client = { host = raw.peer.host, port = raw.peer.port }
  end
  if app.spec.trusted_proxy then
    local proto = last_entry(headers["x-forwarded-proto"])
    if proto ~= nil and proto:lower() == "https" then scheme = "https" end
    host = last_entry(headers["x-forwarded-host"]) or host
    local from = last_entry(headers["x-forwarded-for"])
    if from ~= nil and ip_literal(from) then client = { host = from } end
  end
  local request: Types.Request = {
    raw = raw, method = raw.method, path = parts.path, segments = parts.segments,
    query_string = raw.query, headers = headers, params = {}, mount_path = "", app = app,
    state = {}, client = client, scheme = scheme, host = host, trailing = parts.trailing,
    slots = {}, bodies = {},
  }
  return setmetatable(request, request_mt)
end

return Request
