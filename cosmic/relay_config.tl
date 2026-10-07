--- What [`Child.start`] and the network relay's process agree on, for a
--- policy whose `connect` the relay serves ([`cosmic.relay_serve`]): the
--- ports the program reaches the relay at, the proxy environment it is
--- given, the host's own addresses the relay refuses, and the config the
--- relay is handed on its standard input.
---
--- The program is told of the relay through the variables a proxy client
--- reads (`HTTPS_PROXY`, `ALL_PROXY` and their lower-case spellings); a
--- policy with `connect` that sets any of them for itself is refused, since
--- the program would then be pointed past the relay or off it.
---
---     local env = relay_config.proxy_env({ "127.0.0.2" })
---     print(env.HTTPS_PROXY) -- http://127.0.0.1:3128

local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local sys = require("cosmic.sys")

local record relay_config
  --- What the relay process is told, as JSON on its standard input.
  record Config
    --- The policy's `connect` targets, `host:port`.
    grants: {string}
    --- The caller's `https_proxy` (or `HTTPS_PROXY`), which the relay
    --- reaches the network through ([`cosmic.relay`]'s `upstream`); nil for
    --- none.
    https_proxy: string
    --- The caller's `no_proxy` (or `NO_PROXY`); nil for none.
    no_proxy: string
    --- The host's own addresses, which the relay never connects to
    --- ([`cosmic.relay_address`]'s `own_addresses`).
    own_addresses: {string}
    --- Where the relay's decision lines go: "stderr" or "null".
    log: string
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

--- The environment a program of a policy with `connect` is given: every
--- proxy client's variable, pointing at the relay's listeners, and
--- `NO_PROXY` naming the program's own network. `loopback` is the
--- policy's declared addresses, which stay direct.
--- @param loopback {string} The policy's `loopback` addresses
--- @return {string:string} The variables, by name
function relay_config.proxy_env(loopback: {string}): {string:string}
  local http = "http://127.0.0.1:" .. relay_config.http_port
  local socks = "socks5h://127.0.0.1:" .. relay_config.socks_port
  local direct: {string} = { "localhost", "127.0.0.1", "::1" }
  local listed: {string:boolean} = { ["localhost"] = true, ["127.0.0.1"] = true, ["::1"] = true }
  for _, address in ipairs(loopback) do
    if not listed[address] then
      listed[address] = true
      direct[#direct + 1] = address
    end
  end
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

-- TODO: read the host's own addresses with getifaddrs once cosmic.sys carries
-- it: /proc/self/net is Linux's, and shows the network of the process that
-- reads it, which is the relay's too (it keeps the host's).
--- The addresses of this host's interfaces ([`parse_addresses`]), read from
--- /proc/self/net. Nil and why where /proc/self/net/fib_trie cannot be read: the relay
--- must not run without knowing them, since it would then connect to the
--- host's own addresses where it should refuse. An absent
--- /proc/self/net/if_inet6 is a host with no IPv6.
--- @return {string}|nil The addresses
--- @return string Why they cannot be read, "" otherwise
function relay_config.host_addresses(): {string} | nil, string
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

--- `config` as one line of JSON, the text the relay reads from its
--- standard input.
--- @param config Config What the relay is told
--- @return string The line, with no newline
function relay_config.encode(config: relay_config.Config): string
  local encoded, why = Json.encode({
    grants = Json.array(config.grants), https_proxy = config.https_proxy, no_proxy = config.no_proxy,
    own_addresses = Json.array(config.own_addresses), log = config.log,
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
  local https_proxy, no_proxy = value.https_proxy, value.no_proxy
  if https_proxy ~= nil and not https_proxy is string then
    return nil, "https_proxy is not a string"
  end
  if no_proxy ~= nil and not no_proxy is string then return nil, "no_proxy is not a string" end
  local config: relay_config.Config = { grants = grants, own_addresses = own, log = log }
  if https_proxy is string then config.https_proxy = https_proxy end
  if no_proxy is string then config.no_proxy = no_proxy end
  return config, ""
end

return relay_config
