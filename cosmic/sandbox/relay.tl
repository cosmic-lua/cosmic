--- What the sandbox relay's starter reads and decides before the relay
--- starts (the relay's own side is [`cosmic.relay.main`]), a member of
--- cosmic.sandbox reached outside it as [`Sandbox.Relay`] by cosmic.child,
--- which starts the relay. It holds the relay's policy, the name servers and the
--- connector's wait for each, what a policy's `connect` targets open, the
--- table of the connector of the addresses they name literally and the
--- upstream proxy's, and the one lookup of the upstream's host. It sits
--- here, not in cosmic.relay, because what it makes is the sandbox's: a
--- [`rules.Policy`] for the relay and the connectors cosmic.child starts.
--- cosmic.relay's entry holds what the relay and this starter share, and
--- requires nothing of cosmic.sandbox.
---
--- The relay runs offline: under [`relay.policy`] it makes no
--- socket, and holds none but its listeners, the connections it accepts
--- and those it is handed. It reaches the network only through the native
--- connectors whose control streams [`Child.start`] hands it, which it
--- starts in its own process and network from what this module answers:
---
--- - the table's, whose table
---   ([`relay.table`]) holds every address a target names literally and
---   the upstream proxy's, at most 128 in all;
--- - for a policy that grants a name ([`relay.Plan.names`]) the relay
---   reaches directly (with no upstream, or one `no_proxy` bypasses for
---   some), the name servers' ([`relay.name_servers`]), whose table holds
---   the system's name servers alone, read once, over which the relay
---   resolves a name only once a grant opens it, and, where those could be
---   read, a public connector, which connects to any address its deny list
---   ([`relay.public`]) allows: what a granted name resolves to.
---
--- Each makes several connections at once, so a connect that hangs holds
--- up no other.
---
--- The upstream proxy the caller's `https_proxy` names is resolved once,
--- by the starter, through a name servers' connector of its own
--- ([`relay.upstream_addresses`]), and the relay is told its
--- addresses, which it never resolves again.
---
---     local plan = assert(relay.plan({ "api.github.com:443" }, {}))
---     print(plan.names) -- true

local Clock = require("cosmic.clock")
local Relay = require("cosmic.relay")
local rules = require("cosmic.sandbox.policy")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

--- The raw socket module, cosmic.net's too: it arrives as the second
--- argument `require` passes this chunk's loader.
local type raw_socket = require("cosmic.internal.socket")
local type raw_process = require("cosmic.internal.process")

local extra: any = select(2, ...)
local raw: raw_socket
if type(extra) == "table" then
  raw = extra as raw_socket
else
  raw = require("cosmic.internal.socket")
end

local Address = Relay.Address
local Config = Relay.Config

local record relay
  --- What a policy's `connect` targets open, as the relay reads them
  --- ([`cosmic.relay.server`]), and the upstream proxy the caller names.
  record Plan
    --- The endpoints of the addresses the targets name literally, each
    --- once, in the form a connector's table takes, a port of "*" as 0.
    literals: {Config.Endpoint}
    --- Whether a target opens a name (`*` included).
    names: boolean
    --- The upstream proxy, nil for none; its `addresses` not yet set.
    upstream: Config.Upstream
  end

  --- Where [`relay.name_servers`] reads, and the lookup's time.
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
    --- The stream's descriptor, the caller's, of a connector just started:
    --- nothing has been read from it, what it says first included.
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
--- @return rules.Policy The policy
function relay.policy(database: string, digest: string): rules.Policy
  local grants: {rules.Grant} = {}
  for _, file in ipairs(RELAY_FILES) do
    local there, _ = sys.stat(file)
    if there ~= nil then grants[#grants + 1] = { path = file, letters = "r" } end
  end
  local policy: rules.Policy = { database = database, isolate = { "proc" }, grants = grants }
  rules.expect_digest(policy, digest)
  return policy
end

--- The policy the relay's process is started under on macOS, where
--- Seatbelt holds it ([`Seatbelt.compile`]) and no connector runs: this
--- program's core on the database at `database` (whose SHA-256 is `digest`,
--- in hex), the "system" profile its core loads from, and the resolver's
--- files read-only. Its network is not the policy's to say: the start of the
--- relay gives its profile what [`Seatbelt.Options.serves_relay`] names,
--- since it connects and resolves itself.
--- @param database string The relay's sealed database
--- @param digest string The database's SHA-256, in hex
--- @return rules.Policy The policy
function relay.seatbelt_policy(database: string, digest: string): rules.Policy
  local grants: {rules.Grant} = {}
  for _, file in ipairs(RELAY_FILES) do
    local there, _ = sys.stat(file)
    if there ~= nil then grants[#grants + 1] = { path = file, letters = "r" } end
  end
  local policy: rules.Policy = { database = database, profiles = { "system" }, grants = grants }
  rules.expect_digest(policy, digest)
  return policy
end

--- The name servers a lookup asks, read now, and the wait a connector of
--- them gives each server's connection: the lookup's time divided by one
--- more than the servers (at least half a second, at most a minute), so
--- that servers that do not answer leave the last one time to. Nil and why
--- where they cannot be read or are more than a connector holds (128). A
--- `resolve` that is no positive integer raises.
--- @param opts relay.NameServerOptions|nil Where to read, and the lookup's time
--- @return relay.NameServers|nil The servers and the wait
--- @return string Why there are none, "" otherwise
function relay.name_servers(opts?: relay.NameServerOptions): relay.NameServers | nil, string
  opts = opts or {}
  local resolve = opts.resolve or RESOLVE_NS
  if math.type(resolve) ~= "integer" or resolve <= 0 then
    error("relay: name_servers' resolve must be a positive integer of nanoseconds", 2)
  end
  local listed = opts.servers
  if listed == nil then
    local read, why = Relay.nameservers(opts.resolv_conf)
    if read == nil then return nil, why end
    listed = read
  end
  if #listed > MOST_ENDPOINTS then
    return nil, "the system names " .. String.counted(#listed, "name server") .. ", more than a connector holds (128)"
  end
  local wait = math.min(Clock.seconds(60), math.max(NAME_SERVER_WAIT_LEAST, resolve // (#listed + 1)))
  return { servers = listed, wait_ns = wait }, ""
end

--- `bytes`, an address [`cosmic.relay.address`]'s `parse` read, as the
--- numeric text a connector's table takes: four decimal octets, or eight
--- hex groups.
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
--- upper-case spellings; [`cosmic.relay.config`]'s `upstream`). A target
--- that opens nothing is in neither. Nil and why where the upstream cannot
--- be used, or the targets name more addresses literally than a connector
--- holds (128).
--- @param grants {string} The policy's `connect` targets
--- @param env {string:string} The caller's proxy variables
--- @return relay.Plan|nil What they open
--- @return string Why the start cannot go on, "" otherwise
function relay.plan(grants: {string}, env: {string: string}): relay.Plan | nil, string
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
--- @param through relay.Through|nil The name servers' connector
--- @param unresolved string Why there is no `through`
--- @return {string}|nil The addresses, numeric text
--- @return string Why there are none, "" otherwise
function relay.upstream_addresses(up: Config.Upstream, through: relay.Through | nil,
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
  local found, trouble = raw.resolve_through(up.host, RESOLVE_NS // 1000000, through.fd, reply_ms, servers, nil, true)
  if found == nil then
    return nil, "https_proxy's host " .. up.host .. " does not resolve: " .. trouble
  end
  local addresses: {string} = {}
  for i, answer in ipairs(found) do addresses[i] = answer.address end
  return addresses, ""
end

--- The addresses of `up`'s host, resolved now and once, as the system's
--- resolver answers this process: what macOS's start, which runs no
--- connector, tells its relay. A numeric host is its own address. Nil and
--- why where it does not resolve.
--- @param up Config.Upstream The upstream
--- @return {string}|nil The addresses, numeric text
--- @return string Why there are none, "" otherwise
function relay.resolved_upstream(up: Config.Upstream): {string} | nil, string
  local bytes = Address.parse(up.host)
  if bytes ~= nil then return { numeric(bytes) }, "" end
  local found, trouble = raw.resolve(up.host, RESOLVE_NS // 1000000)
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
--- @param plan relay.Plan What the targets open
--- @param addresses {string}|nil The upstream's addresses, nil for none
--- @return {Config.Endpoint}|nil The table
--- @return string Why there is none, "" otherwise
function relay.table(plan: relay.Plan, addresses: {string} | nil): {Config.Endpoint} | nil, string
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
--- ([`cosmic.relay.address`]'s `deny_cidrs`) and the host's own addresses
--- `own`.
--- @param own {string} The host's own addresses
--- @return raw_process.ConnectorPublic The lists
function relay.public(own: {string}): raw_process.ConnectorPublic
  return { deny = Address.deny_cidrs(), own = own }
end

return relay
