--- What [`Child.start`] and the network relay's process agree on, for a
--- policy whose `connect` the relay serves ([`cosmic.internal.relay_main`]): the
--- ports the program reaches the relay at, the proxy environment it is
--- given, the host's own addresses the relay refuses, the config the
--- relay is handed on its standard input, and the listening sockets a
--- relay on the host's loopback is handed ([`cosmic.internal.relay_start`]).
---
--- The program is told of the relay through the variables a proxy client
--- reads (`HTTPS_PROXY`, `ALL_PROXY` and their lower-case spellings); a
--- policy with `connect` that sets any of them for itself is refused, since
--- the program would then be pointed past the relay or off it. The program
--- has no DNS of its own: a client that honours the variables hands the
--- relay the name, which is checked against the grants before anything
--- resolves it, and one that ignores them reaches nothing.
---
---     local env = relay_config.proxy_env({ "127.0.0.2" })
---     print(env["HTTPS_PROXY"]) -- http://127.0.0.1:3128

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Address = require("cosmic.relay.address")
local Grant = require("cosmic.relay.grant")
local Wire = require("cosmic.internal.relay_wire")
local String = require("cosmic.string")
local Url = require("cosmic.url")
local sys = require("cosmic.sys")

local lower <const> = Wire.lower
local number_of <const> = Wire.number_of

local record relay_config
  --- The proxy a caller's `https_proxy` names, and the hosts `no_proxy`
  --- says to reach directly.
  record Upstream
    --- The proxy's host: a name or an address.
    host: string
    --- The proxy's port.
    port: integer
    --- The `Proxy-Authorization` header value to send it, or nil.
    authorization?: string
    --- The `no_proxy` entries: hosts, domains (leading dot or not, which
    --- match their subdomains too), `host:port`, addresses, or "*".
    no_proxy: mut {string}
    --- The numeric addresses `host` was resolved to, once, by the caller
    --- (the sandbox's relay is told them by its starter): connected to in
    --- their order, as a name's addresses are, and `host` is resolved
    --- never. Nil only in what [`relay_config.upstream`] reads from an
    --- environment, before its starter resolves it: a relay refuses an
    --- upstream without them ([`relay_config.upstream_problem`]).
    addresses?: {string}
  end

  --- What the relay process is told, as one line of query text on its
  --- standard input ([`relay_config.encode`]).
  record Config
    --- The policy's `connect` targets, `host:port`.
    grants: {string}
    --- The upstream proxy the relay reaches the network through
    --- ([`cosmic.internal.relay_server`]'s `upstream`), parsed once by the starter
    --- ([`relay_config.upstream`]) with its `addresses` resolved; nil for
    --- none. [`decode`] refuses a record without them.
    mut upstream?: Upstream
    --- The host's own addresses, which the relay never connects to
    --- ([`cosmic.relay.address`]'s `own_addresses`).
    own_addresses: {string}
    --- Where the relay's decision lines go: "stderr" or "null".
    mut log: string
    --- How many listening sockets the relay is handed from descriptor 3,
    --- 1 or 2, where it serves on the host's loopback, as macOS's start
    --- has it ([`Child.start`]): at one port of 127.0.0.1 and ::1, each
    --- for both protocols, behind `token`. Nil for Linux's relay, which is
    --- handed the program's listeners over a channel at descriptor 3.
    mut listeners?: integer
    --- The per-sandbox token every connection must present
    --- ([`cosmic.internal.relay_server`]'s `token`), or nil for none: a
    --- listener on the host's loopback is one every user of the host can
    --- reach.
    mut token?: string
  end

  --- What the relay's starter, [`Child.start`], makes for it before the
  --- relay starts, from what [`cosmic.internal.relay_start`] gives.
  record Handover
    --- What the relay is told: `grants`, `own_addresses` and `upstream`
    --- are set; the starter sets the rest.
    config: Config
    --- The descriptors the relay is handed beside its standard streams,
    --- by the descriptor of the relay's each is handed at.
    fds: mut {integer: integer}
    --- Closes the starter's own hold of what `fds` names, once the relay
    --- has ended or will not start. Safe to call more than once.
    mut close: function()
  end

  --- The port the program reaches the relay's HTTP CONNECT listener at,
  --- in the sandbox's own network.
  http_port: integer
  --- The port of the relay's SOCKS5 listener.
  socks_port: integer
end

relay_config.http_port = 3128
relay_config.socks_port = 1080

--- The variables the relay sets for the program, which a policy with
--- `connect` may not set itself.
local RESERVED <const>: {string} = {
  "ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "NODE_USE_ENV_PROXY", "NO_PROXY",
  "all_proxy", "http_proxy", "https_proxy", "no_proxy",
}

--- The key of an address's bytes: its octets, an IPv4-mapped IPv6 address
--- as the IPv4 address it carries.
local function address_key(bytes: {integer}): string
  return table.concat(Grant.unmapped(bytes), ".")
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
    local bytes = parsed and parsed.bytes
    if parsed ~= nil and bytes ~= nil and address_key(bytes) == key then
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
  local userinfo = if token ~= nil then ("cosmic:" .. token .. "@") else "" end
  local http = "http://" .. userinfo .. "127.0.0.1:" .. tostring((port or relay_config.http_port))
  local socks = "socks5h://" .. userinfo .. "127.0.0.1:" .. tostring((port or relay_config.socks_port))
  local targets = connect or {}
  local direct: mut {string} = {}
  local listed: mut {string:boolean} = {}
  local function keep(address: string)
    if listed[address] ~= true and relay_config.naming(targets, address) == "" then
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
  local groups: mut {string} = {}
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
  local seen: mut {string:boolean} = {}
  local found: mut {string} = {}
  local function add(address: string)
    if seen[address] ~= true then
      seen[address] = true
      found[#found + 1] = address
    end
  end
  local last: string?
  for line in fib_trie:gmatch("[^\n]+") do
    local address = line:match("^%s*|%-%- (%d+%.%d+%.%d+%.%d+)%s*$")
    if address ~= nil then
      last = address
    elseif last ~= nil and line:match("^%s*/32 host LOCAL%s*$") ~= nil then
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
--- kernel over a netlink socket, which a sandboxed process's filter may
--- refuse, and a sandboxed program may start a relay of its own. Nil and why where
--- they cannot be read (on Linux, /proc/self/net/fib_trie): the relay must
--- not run without knowing them, since it would then connect to the host's
--- own addresses where it should refuse. An absent /proc/self/net/if_inet6
--- is a host with no IPv6.
--- @return {string}|nil The addresses
--- @return string Why they cannot be read, "" otherwise
function relay_config.host_addresses(): {string}?, string
  local listed, listed_why, errno = sys.getifaddrs()
  if listed ~= nil then
    local seen: mut {string:boolean} = {}
    local found: mut {string} = {}
    for _, entry in ipairs(listed) do
      if seen[entry.address] ~= true then
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
  if trie == nil then return nil, "/proc/self/net/fib_trie: " .. tostring(trie_why) end
  local inet6 = ""
  local present, _ = sys.stat("/proc/self/net/if_inet6")
  if present ~= nil then
    local text, text_why = Fs.read("/proc/self/net/if_inet6")
    if text == nil then return nil, "/proc/self/net/if_inet6: " .. tostring(text_why) end
    inet6 = text
  end
  return relay_config.parse_addresses(trie, inet6), ""
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
function relay_config.upstream(env: {string:string}): relay_config.Upstream?, string
  local value = env.https_proxy or env["HTTPS_PROXY"] -- checked: map_field
  if value == nil or value == "" then return nil, "" end
  local scheme, rest = value:match("^(%a[%w+.-]*)://(.*)$") -- untyped: call
  if scheme ~= nil then
    if lower(scheme) ~= "http" then
      -- No reason below repeats the value: it may hold a password, and no
      -- pattern that hides one is right for every place an "@" or "/" may fall.
      return nil, ("https_proxy has the scheme \"%s\", not http:// (the relay speaks plain HTTP to its upstream)"):format(scheme)
    end
  else
    rest = value
  end
  rest = rest:gsub("/.*$", "") -- untyped: call
  local userinfo, hostport = rest:match("^(.*)@(.-)$") -- untyped: call
  if userinfo == nil then hostport = rest end
  local host: string
  local port: integer? = 80
  local bracketed, after = hostport:match("^%[([^%]]*)%](.*)$") -- untyped: call
  if bracketed ~= nil then
    host = bracketed
    if after ~= "" then
      port = if after:sub(1, 1) == ":" then number_of(after:sub(2)) else nil end -- untyped: call*2
    end
  else
    local name, at = hostport:match("^([^:]*):?(.*)$") -- untyped: call
    host = name
    if at ~= "" then port = number_of(at) end
  end
  if host == nil or host == "" or port == nil then -- checked: compare_disjoint
    return nil, "https_proxy has no usable host:port (http://[user:password@]host[:port])"
  end
  local upstream: relay_config.Upstream = { host = lower(host), port = port, no_proxy = {} }
  if userinfo ~= nil and userinfo ~= "" then
    local user, password = userinfo:match("^([^:]*):?(.*)$") -- untyped: call
    local name, name_why = Url.unescape(user)
    if name == nil then return nil, "https_proxy's user: " .. tostring(name_why) end
    local secret, secret_why = Url.unescape(password)
    if secret == nil then return nil, "https_proxy's password: " .. tostring(secret_why) end
    upstream.authorization = "Basic " .. Codec.base64(name .. ":" .. secret) -- checked: field_fixed
  end
  for entry in ((env.no_proxy or env["NO_PROXY"] or "") .. ","):gmatch("([^,]*),") do -- checked: map_field -- untyped: call
    local trimmed = String.trim(entry)
    if trimmed ~= "" then
      local lowered = lower(trimmed)
      upstream.no_proxy[#upstream.no_proxy + 1] = lowered
    end
  end
  return upstream, ""
end

--- The names [`relay_config.decode`] reads, each to whether it may be
--- given more than once (a list).
local FIELDS <const>: {string: boolean} = {
  grants = true, own_addresses = true, log = false, listeners = false, token = false,
  ["upstream.host"] = false, ["upstream.port"] = false, ["upstream.authorization"] = false,
  ["upstream.no_proxy"] = true, ["upstream.addresses"] = true,
}

--- The pair `name`, `value` added to `out`.
local function add_one(out: mut {Url.Pair}, name: string, value: string)
  out[#out + 1] = { name = name, value = value }
end

--- `list`'s entries added to `out` under `name`, or one empty value
--- for an empty list, so that the field is always there. An empty entry
--- is the starter's error, and raised: it would read back as no entry.
local function add_list(out: mut {Url.Pair}, name: string, list: {string})
  if #list == 0 then
    out[#out + 1] = { name = name, value = "" }
    return
  end
  for i, entry in ipairs(list) do
    if entry == "" then error("relay_config: " .. name .. "[" .. tostring(i) .. "] is empty", 3) end
    out[#out + 1] = { name = name, value = entry }
  end
end

--- `config` as one line of query text (`grants=a%3A443&grants=...`,
--- [`Url.encode_query`]), the text the relay reads from its standard
--- input. A list is its name once an entry, or once with an empty value
--- when it holds none; an upstream's fields are named `upstream.host`
--- and so on. The relay has no JSON of its own to read, so the modules
--- that start it require none.
--- @param config Config What the relay is told
--- @return string The line, with no newline
function relay_config.encode(config: relay_config.Config): string
  local out: mut {Url.Pair} = {}
  add_list(out, "grants", config.grants)
  add_list(out, "own_addresses", config.own_addresses)
  add_one(out, "log", config.log)
  local listeners = config.listeners
  if listeners ~= nil then add_one(out, "listeners", tostring(listeners)) end
  local token = config.token
  if token ~= nil then add_one(out, "token", token) end
  local up = config.upstream
  if up ~= nil then
    add_one(out, "upstream.host", up.host)
    add_one(out, "upstream.port", tostring(up.port))
    local authorization = up.authorization
    if authorization ~= nil then add_one(out, "upstream.authorization", authorization) end
    add_list(out, "upstream.no_proxy", up.no_proxy)
    local addresses = up.addresses
    if addresses ~= nil then add_list(out, "upstream.addresses", addresses) end
  end
  return Url.encode_query(out)
end

--- The entries of the list `name` in `query`, or nil and why: one empty
--- value is the empty list, and an empty entry of a longer list is
--- refused. Nil and why where `name` is not given and `required`; nil and
--- "" where it is not given and may not be.
local function list_of(query: Url.Query, name: string, required: boolean): mut {string}?, string
  local values = query.by_name[name]
  if values == nil then return nil, if required then name .. " is not given" else "" end end
  if #values == 1 and values[1] == "" then return {}, "" end
  local out: mut {string} = {}
  for i, value in ipairs(values) do
    if value == "" then return nil, name .. "[" .. tostring(i) .. "] is empty" end
    out[i] = value
  end
  return out, ""
end

--- The one value of the field `name` in `query`, or nil (where it is not
--- given).
local function one_of(query: Url.Query, name: string): string?
  local values = query.by_name[name]
  return values and values[1]
end

--- `text` as a decimal integer from `low` to `high`, with no sign or
--- leading zero, or nil.
local function integer_of(text: string, low: integer, high: integer): integer?
  if text:find("^[1-9]%d?%d?%d?%d?$") == nil then return nil end
  local value = math.tointeger(tonumber(text))
  if value == nil or value < low or value > high then return nil end
  return value
end

--- What makes `up` no upstream a relay may connect through, naming the
--- field (`port is not a port ...`), or nil. Both the relay's spec
--- ([`cosmic.internal.relay_server`]'s `start`) and a decoded config are
--- held to it. No reason repeats a value: `authorization` is a credential.
function relay_config.upstream_problem(up: relay_config.Upstream): string?
  if up.host == "" or up.host:find("[%c%s]") ~= nil then
    return "host is not a host name or address"
  end
  if up.port < 1 or up.port > 65535 then
    return "port is not a port from 1 to 65535"
  end
  local authorization = up.authorization
  if authorization ~= nil and authorization:find("%c") ~= nil then
    return "authorization is not a header value with no control bytes"
  end
  local addresses = up.addresses
  if addresses == nil then return "addresses is not given" end
  if #addresses == 0 then return "addresses holds no address" end
  for i, address in ipairs(addresses) do
    if Address.parse(address) == nil then
      return "addresses[" .. tostring(i) .. "] is not a numeric address"
    end
  end
  return nil
end

--- The [`Upstream`] `query` holds, nil and "" where it holds none, or
--- nil and why ([`relay_config.upstream_problem`]).
local function upstream_of(query: Url.Query): relay_config.Upstream?, string
  local host = one_of(query, "upstream.host")
  if host == nil then
    for name in pairs(query.by_name) do
      if name:find("^upstream%.") ~= nil then return nil, "upstream.host is not given" end
    end
    return nil, ""
  end
  local port_text = one_of(query, "upstream.port")
  local port = if port_text == nil then nil else integer_of(port_text, 1, 65535) end
  if port == nil then return nil, "upstream.port is not a port from 1 to 65535" end
  local skipped, skipped_why = list_of(query, "upstream.no_proxy", true)
  if skipped == nil then return nil, skipped_why end
  local addresses, addresses_why = list_of(query, "upstream.addresses", false)
  if addresses == nil and addresses_why ~= "" then return nil, addresses_why end
  local up: relay_config.Upstream = { host = host, port = port, no_proxy = skipped, addresses = addresses }
  local authorization = one_of(query, "upstream.authorization")
  if authorization ~= nil then up.authorization = authorization end -- checked: field_fixed
  local problem = relay_config.upstream_problem(up)
  if problem ~= nil then return nil, "upstream." .. problem end
  return up, ""
end

--- A [`Config`] from the text [`encode`] wrote, or nil and what is wrong:
--- a field it does not know, a field that is not a list given twice, a
--- field it needs and is not given, or a value it does not take.
--- @param text string The config
--- @return Config|nil What it holds
--- @return string Why it is no config, "" otherwise
function relay_config.decode(text: string): relay_config.Config?, string
  local query, why = Url.decode_query(text, { max_pairs = #text + 1, utf8 = false })
  if query == nil then return nil, tostring(why) end
  for _, pair in ipairs(query.pairs) do
    local list = FIELDS[pair.name]
    if list == nil then return nil, "\"" .. pair.name .. "\" is not a field of the config" end
    if not list and #(query.by_name[pair.name] or {}) > 1 then
      return nil, pair.name .. " is given more than once"
    end
  end
  local grants, grants_why = list_of(query, "grants", true)
  if grants == nil then return nil, grants_why end
  local own, own_why = list_of(query, "own_addresses", true)
  if own == nil then return nil, own_why end
  local log = one_of(query, "log")
  if log ~= "stderr" and log ~= "null" then return nil, "log is not \"stderr\" or \"null\"" end
  local config: relay_config.Config = { grants = grants, own_addresses = own, log = log }
  local up, up_why = upstream_of(query)
  if up == nil and up_why ~= "" then return nil, up_why end
  config.upstream = up
  local token = one_of(query, "token")
  if token ~= nil then config.token = token end
  local listeners_text = one_of(query, "listeners")
  if listeners_text ~= nil then
    local listeners = integer_of(listeners_text, 1, 2)
    if listeners == nil then return nil, "listeners is not 1 or 2" end
    config.listeners = listeners
  end
  return config, ""
end

return relay_config
