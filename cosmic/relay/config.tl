--- What [`Child.start`] and the network relay's process agree on, for a
--- policy whose `connect` the relay serves ([`cosmic.relay.main`]): the
--- ports the program reaches the relay at, the proxy environment it is
--- given, the host's own addresses the relay refuses, the config the
--- relay is handed on its standard input, and the descriptors its
--- connectors' control streams are handed at ([`cosmic.sandbox.relay`]).
---
--- The program is told of the relay through the variables a proxy client
--- reads (`HTTPS_PROXY`, `ALL_PROXY` and their lower-case spellings); a
--- policy with `connect` that sets any of them for itself is refused, since
--- the program would then be pointed past the relay or off it.
---
---     local env = relay_config.proxy_env({ "127.0.0.2" })
---     print(env.HTTPS_PROXY) -- http://127.0.0.1:3128

local Address = require("cosmic.relay.address")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Grant = require("cosmic.relay.grant")
local Json = require("cosmic.json")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")

local record relay_config
  --- One numeric endpoint of a connector's table: a numeric `host` and a
  --- `port`, 0 for any ([`Net.Endpoint`]).
  type Endpoint = raw_process.ConnectorEndpoint

  --- The proxy a caller's `https_proxy` names, and the hosts `no_proxy`
  --- says to reach directly.
  record Upstream
    --- The proxy's host: a name or an address.
    host: string
    --- The proxy's port.
    port: integer
    --- The `Proxy-Authorization` header value to send it, or nil.
    authorization: string
    --- The `no_proxy` entries: hosts, domains (leading dot or not, which
    --- match their subdomains too), `host:port`, addresses, or "*".
    no_proxy: {string}
    --- The numeric addresses `host` was resolved to, once, by the caller
    --- (the sandbox's relay is told them by its starter, which put them in
    --- its connector's table): connected to in their order, as a name's
    --- answers are, and `host` is resolved never. Nil to resolve `host`
    --- for each connection through it ([`cosmic.relay.server`]).
    addresses: {string}
  end

  --- What the relay process is told, as JSON on its standard input.
  record Config
    --- The policy's `connect` targets, `host:port`.
    grants: {string}
    --- The upstream proxy the relay reaches the network through
    --- ([`cosmic.relay.server`]'s `upstream`), parsed once by the starter
    --- ([`relay_config.upstream`]) with its `addresses` resolved; nil for
    --- none. [`decode`] refuses a record without them.
    upstream: Upstream
    --- The host's own addresses, which the relay never connects to
    --- ([`cosmic.relay.address`]'s `own_addresses`).
    own_addresses: {string}
    --- Where the relay's decision lines go: "stderr" or "null".
    log: string
    --- The table of the connector whose control stream is at
    --- [`relay_config.connector_fd`], which holds the addresses `grants`
    --- names literally and the upstream's. Nil where it has none.
    table: {Endpoint}
    --- Whether that connector is public, reaching any address its deny
    --- list allows beside its table, for the names `grants` opens and the
    --- relay reaches directly. With neither a `table` nor `public`, no
    --- connector is handed.
    public: boolean
    --- The name servers of the connector whose stream is at
    --- [`relay_config.name_server_fd`], its whole table; nil where none is handed.
    name_servers: {Endpoint}
    --- That connector's wait for each server's connection, in nanoseconds.
    name_server_wait_ns: integer
    --- Why no name is resolved, or nil: the relay then reaches only what
    --- a grant names literally, and the upstream.
    unresolved: string
    --- Whether the relay serves on the host's loopback, as macOS's start
    --- has it ([`Child.start`]): it is handed `listeners` listening sockets
    --- from descriptor 3, at one port of 127.0.0.1 and ::1, each for both
    --- protocols, behind `token`; and it connects and resolves itself, as its
    --- own profile allows, rather than through connectors it is handed.
    --- False for Linux's relay, which is handed the program's listeners
    --- over a channel.
    direct: boolean
    --- With `direct`, how many listening sockets it is handed, from
    --- descriptor 3: 1 or 2.
    listeners: integer
    --- The per-sandbox token every connection must present
    --- ([`cosmic.relay.server`]'s `token`), or nil for none: a `direct`
    --- relay's listener is one every user of the host can reach.
    token: string
  end

  --- What the relay's starter, [`Child.start`], makes for it before the
  --- relay starts, from what [`cosmic.sandbox.relay`] answers.
  record Handover
    --- What the relay is told of what it is handed: `upstream`,
    --- `table`, `public`, `name_servers`, `name_server_wait_ns`
    --- and `unresolved` are set; the starter sets the rest.
    config: Config
    --- The starter's ends of the connectors' control streams, by the
    --- descriptor of the relay's each is handed at.
    fds: {integer: integer}
    --- Ends the connectors and reaps them, once the relay has ended or
    --- will not start. Safe to call more than once.
    close: function()
  end

  --- The port the program reaches the relay's HTTP CONNECT listener at,
  --- in the sandbox's own network.
  http_port: integer
  --- The port of the relay's SOCKS5 listener.
  socks_port: integer
  --- The relay's descriptor of the control stream of its name servers'
  --- connector ([`Config.name_servers`]).
  name_server_fd: integer
  --- Of its one connector, of the table and, where public, the public
  --- lists ([`Config.table`], [`Config.public`]).
  connector_fd: integer
  --- The longest wait for each connection the connector makes, in
  --- nanoseconds (10 seconds): the starter starts it with it, and a
  --- request of the relay's that asks for less is given less.
  connect_ns: integer
end

relay_config.http_port = 3128
relay_config.socks_port = 1080
relay_config.name_server_fd = 4
relay_config.connector_fd = 5
relay_config.connect_ns = 10000000000

--- The variables the relay sets for the program, which a policy with
--- `connect` may not set itself.
local RESERVED <const>: {string} = {
  "ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "NODE_USE_ENV_PROXY", "NO_PROXY",
  "all_proxy", "http_proxy", "https_proxy", "no_proxy",
}

--- The key of an address's bytes: its octets, an IPv4-mapped IPv6 address
--- as the IPv4 address it carries.
local function address_key(bytes: {integer}): string
  if #bytes == 16 then
    local mapped = bytes[11] == 0xff and bytes[12] == 0xff
    for i = 1, 10 do
      if bytes[i] ~= 0 then mapped = false end
    end
    if mapped then return table.concat({ bytes[13], bytes[14], bytes[15], bytes[16] }, ".") end
  end
  return table.concat(bytes, ".")
end

--- The first `connect` target of `connect` that names the address `host`
--- (numeric text) at any port, or "" for none: compared by the address's
--- bytes, so every spelling of it is the one, and an IPv4-mapped IPv6
--- address is the IPv4 address it carries.
--- @param connect {string} A policy's `connect` targets
--- @param host string A numeric address
--- @return string The target that names it, or ""
function relay_config.naming(connect: {string}, host: string): string
  local wanted = Grant.address(host)
  if wanted == nil then return "" end
  local key = address_key(wanted)
  for _, target in ipairs(connect) do
    local parsed, _ = Grant.parse(target)
    if parsed ~= nil and parsed.bytes ~= nil and address_key(parsed.bytes) == key then
      return target
    end
  end
  return ""
end

--- The environment a program of a policy with `connect` is given: every
--- proxy client's variable, pointing at the relay's listeners, and
--- `NO_PROXY` naming the program's own network. `loopback` is the
--- policy's declared addresses, which stay direct. A loopback address a
--- `connect` target names is the host's own service, so it is left out of
--- `NO_PROXY` and a client sends it to the relay; `localhost` is left out
--- only with 127.0.0.1, as a client reads it as that address first: with
--- just ::1 granted, `localhost` stays direct, for the sandbox's own
--- 127.0.0.1 services, which a granted ::1 is not. A relay on the host's
--- loopback (`port`, macOS's) is at that one port for both protocols, and
--- with a `token` each variable carries it as the password of the user
--- "cosmic": a token is drawn in hex, which a URL holds as it is.
--- @param loopback {string} The policy's `loopback` addresses
--- @param port integer|nil The one port of a relay on the host's loopback, nil for Linux's two
--- @param token string|nil The relay's token, nil for none
--- @param connect {string}|nil The policy's `connect` targets, nil for none
--- @return {string:string} The variables, by name
function relay_config.proxy_env(loopback: {string}, port?: integer, token?: string,
                                connect?: {string}): {string:string}
  local userinfo = token ~= nil and ("cosmic:" .. token .. "@") or ""
  local http = "http://" .. userinfo .. "127.0.0.1:" .. (port or relay_config.http_port)
  local socks = "socks5h://" .. userinfo .. "127.0.0.1:" .. (port or relay_config.socks_port)
  local targets = connect or {}
  local direct: {string} = {}
  local listed: {string:boolean} = {}
  local function keep(address: string)
    if not listed[address] and relay_config.naming(targets, address) == "" then
      listed[address] = true
      direct[#direct + 1] = address
    end
  end
  if relay_config.naming(targets, "127.0.0.1") == "" then keep("localhost") end
  keep("127.0.0.1")
  keep("::1")
  for _, address in ipairs(loopback) do keep(address) end
  local skipped = table.concat(direct, ",")
  return {
    HTTPS_PROXY = http, https_proxy = http, HTTP_PROXY = http, http_proxy = http,
    ALL_PROXY = socks, all_proxy = socks, NO_PROXY = skipped, no_proxy = skipped,
    NODE_USE_ENV_PROXY = "1",
  }
end

--- The first of `names` that is a variable the relay sets for the program,
--- or "" for none.
--- @param names {string} Variable names, a policy's `env` and `set_env`
--- @return string The reserved name, or ""
function relay_config.reserved(names: {string}): string
  for _, name in ipairs(names) do
    for _, taken in ipairs(RESERVED) do
      if name == taken then return name end
    end
  end
  return ""
end

--- A 32-digit hex address of /proc/self/net/if_inet6 as colon-separated groups.
local function grouped(hex: string): string
  local groups: {string} = {}
  for i = 1, 32, 4 do groups[#groups + 1] = hex:sub(i, i + 3) end
  return table.concat(groups, ":")
end

--- The addresses of the host's interfaces, from the text of Linux's
--- /proc/self/net/fib_trie (the IPv4 addresses its LOCAL /32 entries name) and
--- /proc/self/net/if_inet6 (IPv6, one 32-digit hex address a line): sorted,
--- each once, numeric text. A line either holds that is none of these is
--- passed over.
--- @param fib_trie string The text of /proc/self/net/fib_trie
--- @param if_inet6 string The text of /proc/self/net/if_inet6
--- @return {string} The addresses
function relay_config.parse_addresses(fib_trie: string, if_inet6: string): {string}
  local seen: {string:boolean} = {}
  local found: {string} = {}
  local function add(address: string)
    if not seen[address] then
      seen[address] = true
      found[#found + 1] = address
    end
  end
  local last: string
  for line in fib_trie:gmatch("[^\n]+") do
    local address = line:match("^%s*|%-%- (%d+%.%d+%.%d+%.%d+)%s*$")
    if address ~= nil then
      last = address
    elseif last ~= nil and line:match("^%s*/32 host LOCAL%s*$") then
      add(last)
    end
  end
  for line in if_inet6:gmatch("[^\n]+") do
    local hex = line:match("^(%x+)%s")
    if hex ~= nil and #hex == 32 then add(grouped(hex:lower())) end
  end
  table.sort(found)
  return found
end

--- The addresses of this host's interfaces: sorted, each once, numeric
--- text. Darwin's come from [`sys.getifaddrs`]; Linux's are read from
--- /proc/self/net ([`parse_addresses`]), since Linux's getifaddrs asks the
--- kernel over a netlink socket, which a sandboxed process's filter refuses,
--- and a sandboxed program may start a relay of its own. Nil and why where
--- they cannot be read (on Linux, /proc/self/net/fib_trie): the relay must
--- not run without knowing them, since it would then connect to the host's
--- own addresses where it should refuse. An absent /proc/self/net/if_inet6
--- is a host with no IPv6.
--- @return {string}|nil The addresses
--- @return string Why they cannot be read, "" otherwise
function relay_config.host_addresses(): {string} | nil, string
  local listed, listed_why, errno = sys.getifaddrs()
  if listed ~= nil then
    local seen: {string:boolean} = {}
    local found: {string} = {}
    for _, entry in ipairs(listed) do
      if not seen[entry.address] then
        seen[entry.address] = true
        found[#found + 1] = entry.address
      end
    end
    table.sort(found)
    return found, ""
  elseif errno ~= sys.ENOSYS then
    return nil, "getifaddrs: " .. listed_why
  end
  local trie, trie_why = Fs.read("/proc/self/net/fib_trie")
  if trie == nil then return nil, "/proc/self/net/fib_trie: " .. trie_why end
  local inet6 = ""
  local present, _ = sys.stat("/proc/self/net/if_inet6")
  if present ~= nil then
    local text, text_why = Fs.read("/proc/self/net/if_inet6")
    if text == nil then return nil, "/proc/self/net/if_inet6: " .. text_why end
    inet6 = text
  end
  return relay_config.parse_addresses(trie, inet6), ""
end

--- `text` in lower case.
local function lower(text: string): string
  return (text:gsub("%u", string.lower))
end

--- A decimal port from 1 to 65535 with no leading zero, or nil.
local function number_of(text: string): integer | nil
  if not text:find("^[1-9]%d*$") or #text > 5 then return nil end
  local port = math.tointeger(tonumber(text))
  if port == nil or port < 1 or port > 65535 then return nil end
  return port
end

local function percent_decoded(text: string): string
  return (text:gsub("%%(%x%x)", function(hex: string): string
    return string.char(tonumber(hex, 16))
  end))
end

--- The upstream a caller's environment names, and nil when it names none:
--- `https_proxy` (or `HTTPS_PROXY`) as `http://[user:password@]host[:port]`
--- (the scheme and the port, 80, may be left out) and `no_proxy` (or
--- `NO_PROXY`). `https://` proxies are refused, as the relay speaks plain
--- HTTP to its upstream.
---
---     local upstream = assert(relay_config.upstream({ https_proxy = "http://proxy.example:3128" }))
--- @param env {string:string} The caller's environment
--- @return Upstream|nil The upstream, nil for none
--- @return string Why the variable cannot be used, "" otherwise
function relay_config.upstream(env: {string:string}): relay_config.Upstream | nil, string
  local value = env.https_proxy or env.HTTPS_PROXY
  if value == nil or value == "" then return nil, "" end
  local scheme, rest = value:match("^(%a[%w+.-]*)://(.*)$")
  if scheme ~= nil then
    if lower(scheme) ~= "http" then
      -- No reason below repeats the value: it may hold a password, and no
      -- pattern that hides one is right for every place an "@" or "/" may fall.
      return nil, ("https_proxy has the scheme \"%s\", not http:// (the relay speaks plain HTTP to its upstream)"):format(scheme)
    end
  else
    rest = value
  end
  rest = rest:gsub("/.*$", "")
  local userinfo, hostport = rest:match("^(.*)@(.-)$")
  if userinfo == nil then hostport = rest end
  local host: string
  local port: integer | nil = 80
  local bracketed, after = hostport:match("^%[([^%]]*)%](.*)$")
  if bracketed ~= nil then
    host = bracketed
    if after ~= "" then
      port = after:sub(1, 1) == ":" and number_of(after:sub(2)) or nil
    end
  else
    local name, at = hostport:match("^([^:]*):?(.*)$")
    host = name
    if at ~= "" then port = number_of(at) end
  end
  if host == nil or host == "" or port == nil then
    return nil, "https_proxy has no usable host:port (http://[user:password@]host[:port])"
  end
  local upstream: relay_config.Upstream = { host = lower(host), port = port, no_proxy = {} }
  if userinfo ~= nil and userinfo ~= "" then
    local user, password = userinfo:match("^([^:]*):?(.*)$")
    upstream.authorization = "Basic " .. Codec.base64(percent_decoded(user) .. ":" .. percent_decoded(password))
  end
  for entry in ((env.no_proxy or env.NO_PROXY or "") .. ","):gmatch("([^,]*),") do
    local trimmed = String.trim(entry)
    if trimmed ~= "" then upstream.no_proxy[#upstream.no_proxy + 1] = lower(trimmed) end
  end
  return upstream, ""
end

--- `up` as the record [`decode`] reads, or nil for none.
local function upstream_record(up: relay_config.Upstream | nil): any
  if up == nil then return nil end
  return {
    host = up.host,
    port = up.port,
    authorization = up.authorization,
    no_proxy = Json.array(up.no_proxy),
    addresses = up.addresses ~= nil and Json.array(up.addresses) or nil,
  }
end

--- `config` as one line of JSON, the text the relay reads from its
--- standard input.
--- @param config Config What the relay is told
--- @return string The line, with no newline
function relay_config.encode(config: relay_config.Config): string
  local function endpoints(list: {relay_config.Endpoint}): any
    if list == nil then return nil end
    local out: {any} = {}
    for i, entry in ipairs(list) do out[i] = { host = entry.host, port = entry.port } end
    return Json.array(out)
  end
  local encoded, why = Json.encode({
    grants = Json.array(config.grants),
    own_addresses = Json.array(config.own_addresses),
    log = config.log,
    upstream = upstream_record(config.upstream),
    table = endpoints(config.table),
    public = config.public,
    name_servers = endpoints(config.name_servers),
    name_server_wait_ns = config.name_server_wait_ns,
    unresolved = config.unresolved,
    direct = config.direct,
    listeners = config.listeners,
    token = config.token,
  })
  if encoded == nil then error("relay_config: " .. tostring(why), 2) end
  return encoded
end

--- The strings of `value`, a list, or nil and why.
local function strings(value: any, name: string): {string} | nil, string
  if not value is {any} then return nil, name .. " is not a list" end
  local out: {string} = {}
  for i, entry in ipairs(value) do
    if not entry is string then return nil, name .. "[" .. i .. "] is not a string" end
    out[i] = entry
  end
  return out, ""
end

--- The endpoints of `value`, a list of at most 128, or nil and why.
local function endpoints_of(value: any, name: string): {relay_config.Endpoint} | nil, string
  if not value is {any} then return nil, name .. " is not a list" end
  if #value > 128 then return nil, name .. " holds more than 128 endpoints" end
  local out: {relay_config.Endpoint} = {}
  for i, entry in ipairs(value) do
    if not entry is {string: any} then return nil, name .. "[" .. i .. "] is not an endpoint" end
    local host, port = entry.host, entry.port
    if not host is string or not port is integer or port < 0 or port > 65535 then
      return nil, name .. "[" .. i .. "] is not a host and a port from 0 to 65535"
    end
    out[i] = { host = host, port = port }
  end
  return out, ""
end

--- The [`Upstream`] `value` holds, or nil and why. No reason repeats a
--- value: `authorization` is a credential.
local function upstream_of(value: any): relay_config.Upstream | nil, string
  if not value is {string: any} then return nil, "upstream is not an object" end
  local host, port, authorization = value.host, value.port, value.authorization
  if not host is string or host == "" or host:find("[%c%s]") then
    return nil, "upstream.host is not a host name or address"
  end
  if not port is integer or port < 1 or port > 65535 then
    return nil, "upstream.port is not a port from 1 to 65535"
  end
  if authorization ~= nil and (not authorization is string or authorization:find("%c")) then
    return nil, "upstream.authorization is not a header value with no control bytes"
  end
  local skipped, skipped_why = strings(value.no_proxy, "upstream.no_proxy")
  if skipped == nil then return nil, skipped_why end
  local addresses, addresses_why = strings(value.addresses, "upstream.addresses")
  if addresses == nil then
    if value.addresses == nil then return nil, "upstream.addresses is not given" end
    return nil, addresses_why
  end
  if #addresses == 0 then return nil, "upstream.addresses holds no address" end
  for i, address in ipairs(addresses) do
    if Address.parse(address) == nil then
      return nil, "upstream.addresses[" .. i .. "] is not a numeric address"
    end
  end
  local up: relay_config.Upstream = { host = host, port = port, no_proxy = skipped, addresses = addresses }
  if authorization is string then up.authorization = authorization end
  return up, ""
end

--- A [`Config`] from the text [`encode`] wrote, or nil and what is wrong.
--- @param text string The config
--- @return Config|nil What it holds
--- @return string Why it is no config, "" otherwise
function relay_config.decode(text: string): relay_config.Config | nil, string
  local value, why = Json.decode_object(text)
  if value == nil then return nil, why end
  local grants, grants_why = strings(value.grants, "grants")
  if grants == nil then return nil, grants_why end
  local own, own_why = strings(value.own_addresses, "own_addresses")
  if own == nil then return nil, own_why end
  local log = value.log
  if not log is string or (log ~= "stderr" and log ~= "null") then
    return nil, "log is not \"stderr\" or \"null\""
  end
  local config: relay_config.Config = { grants = grants, own_addresses = own, log = log }
  if value.upstream ~= nil then
    local up, up_why = upstream_of(value.upstream)
    if up == nil then return nil, up_why end
    config.upstream = up
  end
  if value.table ~= nil then
    local listed, why_table = endpoints_of(value.table, "table")
    if listed == nil then return nil, why_table end
    config.table = listed
  end
  local public = value.public
  if public ~= nil and not public is boolean then return nil, "public is not a boolean" end
  config.public = public == true
  if value.name_servers ~= nil then
    local servers, why_servers = endpoints_of(value.name_servers, "name_servers")
    if servers == nil then return nil, why_servers end
    local wait = value.name_server_wait_ns
    if not wait is integer or wait < 1 then
      return nil, "name_server_wait_ns is not a positive integer"
    end
    config.name_servers, config.name_server_wait_ns = servers, wait
  end
  local unresolved = value.unresolved
  if unresolved ~= nil and not unresolved is string then
    return nil, "unresolved is not a string"
  end
  if unresolved is string then config.unresolved = unresolved end
  local direct = value.direct
  if direct ~= nil and not direct is boolean then return nil, "direct is not a boolean" end
  config.direct = direct == true
  local token = value.token
  if token ~= nil and not token is string then return nil, "token is not a string" end
  if token is string then config.token = token end
  local listeners = value.listeners
  if listeners ~= nil and (not listeners is integer or listeners < 1 or listeners > 2) then
    return nil, "listeners is not 1 or 2"
  end
  if listeners is integer then config.listeners = listeners end
  return config, ""
end

return relay_config
