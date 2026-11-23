--- The request a handler is given: the server's, wrapped, with the
--- canonical path, the client and the scheme resolved, and the typed
--- per-request state of [`Web.key`].

local Grant = require("cosmic.relay.grant")
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
  for _, octet in ipairs({ a, b, c, d }) do -- checked: array_of_optional
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
function Request.parse_host(value: string): Request.HostPort?
  local lower = value:lower()
  local host, tail: string, string
  if lower:sub(1, 1) == "[" then
    local inner, rest = lower:match("^%[([%x:.]+)%](.*)$")
    if inner == nil or rest == nil or not inner:find(":", 1, true) or not ip_literal(inner) then
      return nil
    end
    host, tail = "[" .. inner .. "]", rest
  else
    local name, after = lower:match("^([%w.%-]+)(.*)$")
    if name == nil or after == nil then return nil end
    host, tail = name, after
  end
  if tail == "" then return { host = host } end
  local digits = tail:match("^:(%d+)$")
  if digits == nil or #digits > 5 then return nil end
  local port = math.tointeger(tonumber(digits))
  if port == nil or port > 65535 then return nil end
  return { host = host, port = port }
end

--- What [`Request.new`] makes.
local class Made is Types.Request
  function header(self, name: string): string?
    return self.headers[name:lower()]
  end

  function bytes(self): string?, string
    local body_text = self.body_text
    if body_text ~= nil then return body_text, "" end
    local body_failure = self.body_failure
    if body_failure ~= nil then return nil, body_failure end
    local data, why = Stream.read_all(self.raw.body)
    if data == nil then
      -- The reader is spent: a second call answers the same failure.
      self.body_failure = tostring(why)
      return nil, tostring(why)
    end
    self.body_text = data
    self.raw.body = Stream.from_string(data)
    return data, ""
  end

  function text(self): string?, string
    local data, why = self:bytes()
    if data == nil then return nil, why end
    if not utf8.len(data) then return nil, "web: the body is not valid UTF-8" end
    return data, ""
  end

  function get<T>(self, key: Types.Key<T>): T?
    -- cast: a slot holds the T that `set` stored under this very key.
    return self.slots[key] as T -- checked: cast_refused
  end

  function set<T>(self, key: Types.Key<T>, value: T)
    self.slots[key] = value
  end

  function query(self): Url.Query?, string
    local cached = self:get(QUERY)
    if cached ~= nil then return cached, "" end
    local decoded, why = Url.decode_query(self.query_string)
    if decoded == nil then return nil, tostring(why) end
    self:set(QUERY, decoded)
    return decoded, ""
  end

  function accepts(self, offers: {string}): string?
    return Negotiate.best(self.headers["accept"], offers)
  end

  function url_for(self, name: string, params?: {string: string | integer},
                   queries?: {string:string}): string?, string
    return self.app:url_for(name, params, queries)
  end

  function base_url(self): string?, string
    if self.app.spec.trusted_hosts == nil then
      return nil, "web: base_url needs trusted_hosts, since the Host header is the client's"
    end
    local host = self.host
    if host == nil then return nil, "web: the request names no host" end
    local parsed = Request.parse_host(host)
    if parsed == nil then return nil, "web: the request's host is not a host name" end
    local port = parsed.port
    return self.scheme .. "://" .. parsed.host .. (if port ~= nil then ":" .. tostring(port) else "" end), ""
  end
end

--- The last entry of a comma-separated forwarding header: the one the
--- proxy next to the app added, since the entries before it are the
--- client's to write. Nil for none.
local function last_entry(value: string?): string?
  if value == nil then return nil end
  -- Found from the end: `([^,]*)$` retries at every byte of a long entry.
  local comma = value:reverse():find(",", 1, true)
  local entry: string
  if comma == nil then
    entry = String.trim(value)
  else
    entry = String.trim(value:sub(#value - comma + 2))
  end
  if entry == "" then return nil end
  return entry
end

--- The bytes of the numeric address `host` ([`Grant.address`]), an IPv4
--- address mapped into IPv6 (`::ffff:192.0.2.1`, as a listener on `::`
--- names an IPv4 peer) as its 4, so that it meets the IPv4 prefixes. Nil
--- for no address.
local function address_bytes(host: string): {integer}?
  local octets = Grant.address(host)
  if octets == nil or #octets == 4 then return octets end
  for i = 1, 10 do
    if octets[i] ~= 0 then return octets end
  end
  if octets[11] ~= 0xff or octets[12] ~= 0xff then return octets end
  return { table.unpack(octets, 13, 16) }
end

--- Whether `octets` lie in `prefix`.
local function within(octets: {integer}, prefix: Types.ProxyPrefix): boolean
  if #octets ~= #prefix.octets then return false end
  local whole = prefix.bits // 8
  for i = 1, whole do
    if octets[i] ~= prefix.octets[i] then return false end
  end
  local rest = prefix.bits % 8
  if rest == 0 then return true end
  local mask = (0xff << (8 - rest)) & 0xff
  return (octets[whole + 1] or 0) & mask == (prefix.octets[whole + 1] or 0) & mask
end

--- Whether `host`, a numeric address, lies in a prefix of `proxies`.
local function proxy_address(proxies: Types.Proxies, host: string): boolean
  local octets = address_bytes(host)
  if octets == nil then return false end
  for _, prefix in ipairs(proxies.prefixes) do
    if within(octets, prefix) then return true end
  end
  return false
end

--- What "loopback" stands for in a `trusted_proxy`.
local LOOPBACK <const>: {string} = { "127.0.0.0/8", "::1/128" }

--- The prefix `entry` names, an address or "address/bits", or nil and
--- why not.
local function proxy_prefix(entry: string): Types.ProxyPrefix?, string
  if entry:find("%", 1, true) then return nil, "names a zone, which a proxy's address cannot" end
  local address, bits_text = entry:match("^([^/]*)/(%d+)$")
  local spelled = Grant.address(address or entry)
  if spelled == nil then return nil, "is no address, prefix, \"loopback\" or \"unix\"" end
  local octets = assert(address_bytes(address or entry))
  -- An IPv4 address mapped into IPv6 is matched as IPv4 ([`address_bytes`]),
  -- so a prefix of the mapped range is the IPv4 prefix it spells.
  local shift = #spelled * 8 - #octets * 8
  local bits = #octets * 8
  if bits_text ~= nil then
    local given = math.tointeger(tonumber(bits_text))
    if given == nil or given > #spelled * 8 then
      return nil, "has a prefix longer than its address"
    end
    if given < shift then
      return nil, "is an IPv4-mapped prefix shorter than /96, which spans more than IPv4: name the IPv4 prefix"
    end
    bits = given - shift
    for i, byte in ipairs(octets) do
      local kept = math.max(0, math.min(8, bits - (i - 1) * 8))
      if byte & (0xff >> kept) ~= 0 then return nil, "has bits set past its prefix" end
    end
  end
  return { octets = octets, bits = bits }, ""
end

--- The peers `list` names, an app's [`Types.AppSpec.trusted_proxy`]: nil
--- for none (nil, `false` or an empty list), or nil and why for a `list`
--- that is no list (`true`) or holds an entry of none of the forms it
--- describes.
--- @param list {string} | boolean | nil The entries. A Lua caller may pass
--- a boolean.
--- @return Types.Proxies | nil The peers
--- @return string Why not, "" for none
function Request.proxies(list: ({string} | boolean)?): Types.Proxies?, string
  if list == nil or list == false then return nil, "" end
  if type(list) ~= "table" then
    return nil, ("web: trusted_proxy lists the proxy's peers, such as { \"loopback\" }, " ..
      "{ \"10.0.0.2\" }, { \"10.0.0.0/8\" } or { \"unix\" }, not %s"):format(tostring(list))
  end
  local unix = false
  local prefixes: mut {Types.ProxyPrefix} = {}
  for _, entry in ipairs(list) do
    if type(entry) ~= "string" then
      return nil, ("web: trusted_proxy: %s is no address, prefix, \"loopback\" or \"unix\""):format(tostring(entry))
    elseif entry == "unix" then
      unix = true
    else
      local texts: {string} = if entry == "loopback" then LOOPBACK else { entry } end
      for _, spelled in ipairs(texts) do
        local prefix, why = proxy_prefix(spelled)
        if prefix == nil then return nil, ("web: trusted_proxy: %q %s"):format(entry, why) end
        prefixes[#prefixes + 1] = prefix
      end
    end
  end
  if not unix and #prefixes == 0 then return nil, "" end
  return { unix = unix, prefixes = prefixes }, ""
end

--- Whether `raw` came from one of `proxies`: a TCP peer at one of their
--- addresses, or a connection to a unix-socket listener where they hold
--- "unix".
local function from_proxy(proxies: Types.Proxies, raw: Server.Request): boolean
  local peer = raw.peer
  if peer ~= nil and peer.kind == "tcp" then
    local host = peer.host
    return host ~= nil and proxy_address(proxies, host)
  end
  local listener = raw.listener
  return proxies.unix and listener ~= nil and listener.kind == "unix"
end

--- The client `X-Forwarded-For`'s `value` names, behind `proxies`: the
--- right-most entry that is none of their addresses, since each proxy
--- appends the address it was reached from and everything left of the
--- first stranger is the stranger's to write. An IPv6 entry is lower-cased,
--- so one client has one spelling. Nil, so the client is the peer, where an
--- entry met before that one is no bare address (a port, brackets, a zone
--- or junk), or every entry is a proxy's: the left-most is then still
--- one the client could have written.
local function forwarded_client(proxies: Types.Proxies, value: string?): string?
  if value == nil then return nil end
  local entries: mut {string} = {}
  local from = 1
  while true do
    local comma = value:find(",", from, true)
    entries[#entries + 1] = String.trim(value:sub(from, (comma or #value + 1) - 1))
    if comma == nil then break end
    from = comma + 1
  end
  for i = #entries, 1, -1 do
    local entry = assert(entries[i])
    if address_bytes(entry) == nil then return nil end
    if not proxy_address(proxies, entry) then return entry:lower() end
  end
  return nil
end

--- Wraps `raw`, the server's request, for `app`, with the path `parts`
--- the app made canonical.
--- @param app Types.App The app serving the request
--- @param raw Server.Request The request
--- @param parts Request.Parts The canonical path
--- @return Types.Request The request
function Request.new(app: Types.App, raw: Server.Request, parts: Request.Parts): Types.Request
  local headers = raw.headers
  local scheme = if raw.tls ~= nil then "https" else "http" end
  local host = headers["host"]
  local client: Types.Client? = nil
  local peer = raw.peer
  local peer_host = if peer ~= nil then peer.host else nil end
  if peer ~= nil and peer.kind == "tcp" and peer_host ~= nil then
    client = { host = peer_host, port = peer.port }
  end
  local proxies = app.proxies
  if proxies ~= nil and from_proxy(proxies, raw) then
    local proto = last_entry(headers["x-forwarded-proto"])
    if proto ~= nil and proto:lower() == "https" then scheme = "https" end
    host = last_entry(headers["x-forwarded-host"]) or host
    local from = forwarded_client(proxies, headers["x-forwarded-for"])
    if from ~= nil then client = { host = from } end
  end
  local request: Made = {
    raw = raw, method = raw.method, path = parts.path, segments = parts.segments,
    query_string = raw.query, headers = headers, params = {}, mount_path = "", app = app,
    state = {}, client = client, scheme = scheme, host = host, trailing = parts.trailing,
    slots = {}, bodies = {}, route = nil, outcome = nil, body_text = nil, body_failure = nil,
  }
  return request
end

return Request
