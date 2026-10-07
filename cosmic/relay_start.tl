--- What the sandbox relay's starter reads and decides before the relay
--- starts (the relay's own side is [`cosmic.relay_serve`]), below
--- cosmic.child, which starts it, and cosmic.net, which lists the name
--- servers through it: the relay's policy, the name servers and the
--- connector's wait for each, what a policy's `connect` targets open, the
--- table of the connector of the addresses they name literally and the
--- upstream proxy's, and the one lookup of the upstream's host.
---
--- The relay runs offline: under [`relay_start.policy`] it makes no
--- socket, and holds none but its listeners, the connections it accepts
--- and those it is handed. It reaches the network only through the native
--- connectors whose control streams [`Child.start`] hands it, which it
--- starts in its own process and network from what this module answers:
---
--- - the table's, whose table ([`relay_start.table`]) holds every address
---   a target names literally and the upstream proxy's, at most 128 in all;
--- - for a policy that grants a name ([`relay_start.Plan.names`]), a
---   public connector, which connects to any address its deny list
---   ([`relay_start.public`]) allows: what a granted name resolves to;
--- - for such a policy, the name servers' ([`relay_start.name_servers`]),
---   whose table holds the system's name servers alone, read once, over
---   which the relay resolves a name only once a grant opens it.
---
--- The upstream proxy the caller's `https_proxy` names is resolved once,
--- by the starter, through the name servers' connector
--- ([`relay_start.upstream_addresses`]), and the relay is told its
--- addresses, which it never resolves again.
---
---     local plan = assert(relay_start.plan({ "api.github.com:443" }, {}))
---     print(plan.names) -- true

local Clock = require("cosmic.clock")
local Address = require("cosmic.relay_address")
local Config = require("cosmic.relay_config")
local Sandbox = require("cosmic.sandbox")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

--- The raw module behind this one, as cosmic.net's is: it arrives as the
--- second argument `require` passes this chunk's loader.
local type raw_socket = require("cosmic.internal.socket")
local type raw_process = require("cosmic.internal.process")

local extra: any = select(2, ...)
local raw: raw_socket
if type(extra) == "table" then
  raw = extra as raw_socket
else
  raw = require("cosmic.internal.socket")
end

local record relay_start
  --- What a policy's `connect` targets open, as the relay reads them
  --- ([`cosmic.relay`]), and the upstream proxy the caller names.
  record Plan
    --- The endpoints of the addresses the targets name literally, each
    --- once, in the form a connector's table takes, a port of "*" as 0.
    literals: {Config.Endpoint}
    --- Whether a target opens a name (`*` included).
    names: boolean
    --- The upstream proxy, nil for none; its `addresses` not yet set.
    upstream: Config.Upstream
  end

  --- Where [`relay_start.name_servers`] reads, and the lookup's time.
  record NameServerOptions
    --- A resolv.conf to read in place of the system's, for tests.
    resolv_conf: string
    --- The lookup's whole time (5 seconds), which the connector's wait for
    --- each server is a share of: a positive integer of nanoseconds.
    resolve: integer
    --- The servers in place of the system's, for tests.
    servers: {Config.Endpoint}
  end

  --- The name servers a lookup through a connector asks, and that
  --- connector's wait for each server's connection.
  record NameServers
    --- The servers, each at its TCP port, at most 128: the connector's
    --- table.
    servers: {Config.Endpoint}
    --- The connector's wait for each server's connection, in nanoseconds.
    wait_ns: integer
  end

  --- A name servers' connector's control stream, and what it was started
  --- with.
  record Through
    --- The stream's descriptor, the caller's.
    fd: integer
    --- What the connector was started with.
    name_servers: NameServers
  end
end

--- The most endpoints a connector's table holds.
local MOST_ENDPOINTS <const> = 128

--- The least a lookup's connector waits for a server to take its
--- connection, however many servers share the lookup's time.
local NAME_SERVER_WAIT_LEAST <const> = Clock.ms(500)

--- A lookup's whole time, by default.
local RESOLVE_NS <const> = Clock.seconds(5)

--- The grace a lookup gives each of the connector's replies past its own
--- wait, as cosmic.net's lookups through a connector do.
local REPLY_GRACE_MS <const> = 1000

--- The files the relay's resolver reads, each granted to the relay's
--- process where the host has it: c-ares reads them as each lookup starts,
--- and fails one where a file is there and cannot be read.
-- TODO: grant the relay none of these once Net.resolve through a connector
-- takes its options and hosts from its caller (an ARES_OPT_* set that reads
-- no system file): the name servers come from the starter already, and the
-- relay still reads the host's resolv.conf and hosts at every lookup.
local RELAY_FILES <const>: {string} = {
  "/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf", "/etc/host.conf",
}

--- The policy the relay's process is started under, on the database at
--- `database` (whose SHA-256 is `digest`, in hex): this program's core on
--- it, a pid namespace of its own, the resolver's files read-only, and no
--- promise beyond the basics a policy gives. It declares no network, so
--- its filter refuses every socket it would make: the relay holds only
--- what it is handed, and every connection it makes is a connector's.
--- @param database string The relay's sealed database
--- @param digest string The database's SHA-256, in hex
--- @return Sandbox.Policy The policy
function relay_start.policy(database: string, digest: string): Sandbox.Policy
  local grants: {Sandbox.Grant} = {}
  for _, file in ipairs(RELAY_FILES) do
    local there, _ = sys.stat(file)
    if there ~= nil then grants[#grants + 1] = { path = file, letters = "r" } end
  end
  local policy: Sandbox.Policy = { database = database, isolate = { "proc" }, grants = grants }
  Sandbox.expect_digest(policy, digest)
  return policy
end

--- One entry of c-ares's server list: the numeric host and the TCP port,
--- or nil for an entry of none of the list's forms or a link-local server
--- written with its interface (a "%" and its name), which a connector's
--- endpoint cannot carry.
local function nameserver_of(entry: string): Config.Endpoint | nil
  local host, port, rest: string, string, string
  local uri = entry:match("^dns://(.*)$")
  if uri ~= nil then
    local tcp = uri:match("[?&]tcpport=(%d+)")
    host, port, rest = uri:match("^%[([%x:%.]+)%]:(%d+)(.*)$")
    if host == nil then host, port, rest = uri:match("^([%d%.]+):(%d+)(.*)$") end
    if rest ~= nil and rest:sub(1, 1) == "?" then rest = "" end
    port = tcp or port
  else
    host, port, rest = entry:match("^%[([%x:%.]+)%]:(%d+)(.*)$")
    if host == nil then host, port, rest = entry:match("^([%d%.]+):(%d+)(.*)$") end
  end
  if host == nil or rest ~= "" then return nil end
  local number = math.tointeger(tonumber(port))
  if number == nil or number < 1 or number > 65535 or Address.parse(host) == nil then
    return nil
  end
  return { host = host, port = number }
end

--- The name servers the system's configuration names, as [`Net.nameservers`]
--- answers them (it is this): each a numeric endpoint at its TCP port.
--- Nil and why where they cannot be listed: the system's words where the
--- configuration cannot be read.
--- @param resolv_conf string|nil A resolv.conf to read in place of the system's
--- @return {Config.Endpoint}|nil The servers
--- @return string Why there are none, "" otherwise
-- TODO: reach a link-local name server (fe80::1%eth0) through a connector
-- once a connector's endpoint carries an interface: it is left out today.
function relay_start.nameservers(resolv_conf?: string): {Config.Endpoint} | nil, string
  local listed, trouble = raw.nameservers(resolv_conf)
  if listed == nil then return nil, trouble end
  local servers: {Config.Endpoint} = {}
  local skipped = ""
  for entry in listed:gmatch("[^,]+") do
    local server = nameserver_of(entry)
    if server ~= nil then
      servers[#servers + 1] = server
    elseif entry:find("%", 1, true) ~= nil then
      skipped = "net: the name server " .. entry .. " is scoped to an interface, which a connector cannot reach"
    else
      return nil, "net: the resolver lists a server as " .. entry
    end
  end
  if #servers == 0 then
    return nil, skipped ~= "" and skipped or "net: the resolver lists no name server"
  end
  return servers, ""
end

--- The name servers a lookup asks, read now, and the wait a connector of
--- them gives each server's connection: the lookup's time divided by one
--- more than the servers (at least half a second, at most a minute), so
--- that servers that do not answer leave the last one time to. Nil and why
--- where they cannot be read or are more than a connector holds (128). A
--- `resolve` that is no positive integer raises.
--- @param opts relay_start.NameServerOptions|nil Where to read, and the lookup's time
--- @return relay_start.NameServers|nil The servers and the wait
--- @return string Why there are none, "" otherwise
function relay_start.name_servers(opts?: relay_start.NameServerOptions): relay_start.NameServers | nil, string
  opts = opts or {}
  local resolve = opts.resolve or RESOLVE_NS
  if math.type(resolve) ~= "integer" or resolve <= 0 then
    error("relay: name_servers' resolve must be a positive integer of nanoseconds", 2)
  end
  local listed = opts.servers
  if listed == nil then
    local read, why = relay_start.nameservers(opts.resolv_conf)
    if read == nil then return nil, why end
    listed = read
  end
  if #listed > MOST_ENDPOINTS then
    return nil, "the system names " .. String.counted(#listed, "name server") .. ", more than a connector holds (128)"
  end
  local wait = math.min(Clock.seconds(60), math.max(NAME_SERVER_WAIT_LEAST, resolve // (#listed + 1)))
  return { servers = listed, wait_ns = wait }, ""
end

--- `bytes`, an address [`Address.parse`] read, as the numeric text a
--- connector's table takes: four decimal octets, or eight hex groups.
local function numeric(bytes: {integer}): string
  if #bytes == 4 then return table.concat(bytes, ".") end
  local groups: {string} = {}
  for i = 1, 16, 2 do groups[#groups + 1] = ("%x"):format(bytes[i] << 8 | bytes[i + 1]) end
  return table.concat(groups, ":")
end

--- A decimal port from 1 to 65535 with no leading zero, "*" as 0, or nil.
local function port_of(text: string): integer | nil
  if text == "*" then return 0 end
  if not text:find("^[1-9]%d*$") or #text > 5 then return nil end
  local port = math.tointeger(tonumber(text))
  if port == nil or port > 65535 then return nil end
  return port
end

--- What the `connect` targets `grants` open, as the relay reads them, and
--- the upstream proxy `env` names (`https_proxy`, `no_proxy` and their
--- upper-case spellings; [`Relay.upstream`]). A target that opens nothing
--- is in neither. Nil and why where the upstream cannot be used, or the
--- targets name more addresses literally than a connector holds (128).
--- @param grants {string} The policy's `connect` targets
--- @param env {string:string} The caller's proxy variables
--- @return relay_start.Plan|nil What they open
--- @return string Why the start cannot go on, "" otherwise
function relay_start.plan(grants: {string}, env: {string: string}): relay_start.Plan | nil, string
  local up, up_why = Config.upstream(env)
  if up == nil and up_why ~= "" then return nil, up_why end
  local literals: {Config.Endpoint} = {}
  local seen: {string: boolean} = {}
  local names = false
  local function literal(bytes: {integer}, port: integer)
    local entry: Config.Endpoint = { host = numeric(bytes), port = port }
    local key = entry.host .. " " .. port
    if not seen[key] then
      seen[key] = true
      literals[#literals + 1] = entry
    end
  end
  for _, grant in ipairs(grants) do
    local host, at = grant:match("^(.+):([^:]+)$")
    local port = at ~= nil and port_of(at) or nil
    if host ~= nil and port ~= nil then
      local inner = host:match("^%[(.*)%]$")
      if inner ~= nil then
        -- Only IPv6 is written in brackets.
        local bytes = inner:find(":", 1, true) and Address.parse(inner) or nil
        if bytes ~= nil then literal(bytes, port) end
      elseif not host:find(":", 1, true) then
        local bytes = Address.parse(host)
        if bytes ~= nil then
          literal(bytes, port)
        elseif host == "*" or not host:find("[%*%[%]]") then
          names = true
        end
      end
    end
  end
  if #literals > MOST_ENDPOINTS then
    return nil, ("connect names %s literally, more than the relay's connector holds (%d): grant fewer " ..
      "addresses, or names"):format(String.counted(#literals, "address", "addresses"), MOST_ENDPOINTS)
  end
  return { literals = literals, names = names, upstream = up }, ""
end

--- The addresses of `up`'s host, resolved now and once: a numeric host is
--- its own address, and a name is resolved over TCP through the name
--- servers' connector `through`, the lookup's sockets that connector's.
--- Nil and why where the host is a name and there is no `through`
--- (`unresolved` says why), or it does not resolve.
--- @param up Config.Upstream The upstream
--- @param through relay_start.Through|nil The name servers' connector
--- @param unresolved string Why there is no `through`
--- @return {string}|nil The addresses, numeric text
--- @return string Why there are none, "" otherwise
function relay_start.upstream_addresses(up: Config.Upstream, through: relay_start.Through | nil,
                                        unresolved: string): {string} | nil, string
  local bytes = Address.parse(up.host)
  if bytes ~= nil then return { numeric(bytes) }, "" end
  if through == nil then
    return nil, "https_proxy's host " .. up.host .. " cannot be resolved: " .. unresolved
  end
  local servers: {raw_socket.ThroughServer} = {}
  for i, server in ipairs(through.name_servers.servers) do
    servers[i] = { host = server.host, port = server.port, index = i }
  end
  local reply_ms = (through.name_servers.wait_ns + 999999) // 1000000 + REPLY_GRACE_MS
  local found, trouble = raw.resolve_through(up.host, RESOLVE_NS // 1000000, through.fd, reply_ms, servers)
  if found == nil then
    return nil, "https_proxy's host " .. up.host .. " does not resolve: " .. trouble
  end
  local addresses: {string} = {}
  for i, answer in ipairs(found) do addresses[i] = answer.address end
  return addresses, ""
end

--- The table of the connector of `plan`'s literal addresses and the
--- upstream's `addresses` at its port: each endpoint once. Nil and why
--- where they are more than a connector holds (128).
--- @param plan relay_start.Plan What the targets open
--- @param addresses {string}|nil The upstream's addresses, nil for none
--- @return {Config.Endpoint}|nil The table
--- @return string Why there is none, "" otherwise
function relay_start.table(plan: relay_start.Plan, addresses: {string} | nil): {Config.Endpoint} | nil, string
  local rows: {Config.Endpoint} = {}
  local seen: {string: boolean} = {}
  local function add(entry: Config.Endpoint)
    local key = entry.host .. " " .. entry.port
    if not seen[key] then
      seen[key] = true
      rows[#rows + 1] = entry
    end
  end
  for _, entry in ipairs(plan.literals) do add(entry) end
  for _, address in ipairs(addresses or {}) do
    local bytes = Address.parse(address)
    if bytes ~= nil then add({ host = numeric(bytes), port = plan.upstream.port }) end
  end
  if #rows > MOST_ENDPOINTS then
    return nil, ("connect names %s literally, with the upstream proxy's: %s, more than the relay's " ..
      "connector holds (%d); grant fewer addresses, or names"):format(
        String.counted(#plan.literals, "address", "addresses"), String.counted(#rows, "endpoint"), MOST_ENDPOINTS)
  end
  return rows, ""
end

--- What the public connector refuses: the relay's deny list
--- ([`cosmic.relay_address`]'s `deny_cidrs`) and the host's own addresses
--- `own`.
--- @param own {string} The host's own addresses
--- @return raw_process.ConnectorPublic The lists
function relay_start.public(own: {string}): raw_process.ConnectorPublic
  return { deny = Address.deny_cidrs(), own = own }
end

return relay_start
