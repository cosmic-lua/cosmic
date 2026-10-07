--- The starter's side of the sandbox's network relay (the relay's own is
--- [`cosmic.relay_serve`]): what [`Child.start`] makes in its own process,
--- and so in its own network, before it starts the relay's process for a
--- policy's `connect`. The relay runs offline: under [`relay_start.policy`]
--- it makes no socket, and holds none but its listeners, the connections
--- it accepts and those it is handed. It reaches the network only through
--- the connectors whose control streams it is handed, each a native
--- connector process ([`Net.connector`]) this process starts and keeps
--- ([`relay_start.prepare`]):
---
--- - the table's, whose table holds every address a grant names literally
---   and the upstream proxy's, at most 128 in all;
--- - for a policy that grants a name, a public connector, which connects
---   to any address its deny list ([`cosmic.relay_address`]'s `deny_cidrs`
---   and the host's own addresses) allows: what a granted name resolves to;
--- - for a policy that grants a name, the name servers', whose table holds
---   the system's name servers alone, read once, here
---   ([`Relay.name_server_plan`]), over which the relay resolves a name
---   only once it is granted.
---
--- The upstream proxy the caller's `https_proxy` names is resolved here,
--- once, through a connector of the name servers of its own that is ended
--- with the lookup, and the relay is told its addresses, which it never
--- resolves again.
---
--- [`Child.start`] loads this module by its name: cosmic.child cannot
--- require it, as it requires cosmic.child through cosmic.net.
---
---     local handover = assert(relay_start.prepare({ "api.github.com:443" }, own_addresses))
---     -- hand each of handover.fds to the relay at its key, with handover.config
---     handover.close()

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Relay = require("cosmic.relay")
local Address = require("cosmic.relay_address")
local Config = require("cosmic.relay_config")
local Sandbox = require("cosmic.sandbox")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

local record relay_start
  --- What [`relay_start.prepare`] and [`relay_start.upstream`] read in
  --- place of the system's, for tests.
  record Options
    --- The variables the upstream is read from (`https_proxy`, `no_proxy`
    --- and their upper-case spellings), in place of this process's
    --- environment.
    env: {string: string}
    --- A resolv.conf to read the name servers from.
    resolv_conf: string
    --- The name servers, in place of those resolv.conf names.
    servers: {Net.Endpoint}
  end
end

--- The most endpoints a connector's table holds.
local MOST_ENDPOINTS <const> = 128

--- How long the starter's lookup of the upstream's host may take.
local UPSTREAM_RESOLVE_NS <const> = Clock.seconds(5)

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

--- What a policy's `connect` targets open, as the relay reads them
--- ([`cosmic.relay`]): the addresses named literally, each as the
--- endpoint a table holds, and whether any grant opens a name. A target
--- that opens nothing is in neither.
local function opened(grants: {string}): {Config.Endpoint}, boolean
  local literals: {Config.Endpoint} = {}
  local names = false
  for _, grant in ipairs(grants) do
    local host, at = grant:match("^(.+):([^:]+)$")
    local port = at ~= nil and port_of(at) or nil
    if host ~= nil and port ~= nil then
      local inner = host:match("^%[(.*)%]$")
      if inner ~= nil then
        -- Only IPv6 is written in brackets.
        local bytes = inner:find(":", 1, true) and Address.parse(inner) or nil
        if bytes ~= nil then literals[#literals + 1] = { host = numeric(bytes), port = port } end
      elseif not host:find(":", 1, true) then
        local bytes = Address.parse(host)
        if bytes ~= nil then
          literals[#literals + 1] = { host = numeric(bytes), port = port }
        elseif host == "*" or not host:find("[%*%[%]]") then
          names = true
        end
      end
    end
  end
  return literals, names
end

--- The variables the upstream is read from: `opts.env`, or this process's.
local function proxy_env(opts: relay_start.Options): {string: string}
  if opts.env ~= nil then return opts.env end
  local env: {string: string} = {}
  for _, name in ipairs({ "https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY" }) do
    env[name] = sys.getenv(name)
  end
  return env
end

--- The upstream proxy the caller's environment names, with the addresses
--- of its host ([`Relay.Upstream.addresses`]), resolved now and once: a
--- numeric host is its own address, and a name is resolved over TCP
--- through a connector of the system's name servers alone
--- ([`Relay.name_servers`]), ended with the lookup. Nil and "" for none;
--- nil and why where `https_proxy` cannot be used or its host does not
--- resolve. `opts` is for tests.
--- @param opts relay_start.Options|nil What to read in place of the system's
--- @return Relay.Upstream|nil The upstream, nil for none
--- @return string Why it cannot be used, "" otherwise
function relay_start.upstream(opts?: relay_start.Options): Relay.Upstream | nil, string
  opts = opts or {}
  local up, why = Relay.upstream(proxy_env(opts))
  if up == nil then return nil, why end
  local bytes = Address.parse(up.host)
  if bytes ~= nil then
    up.addresses = { numeric(bytes) }
    return up, ""
  end
  local servers, servers_why = Relay.name_servers({ resolv_conf = opts.resolv_conf, servers = opts.servers,
    resolve = UPSTREAM_RESOLVE_NS })
  if servers == nil then
    return nil, "https_proxy's host " .. up.host .. " cannot be resolved: " .. servers_why
  end
  local found, found_why = Net.resolve(up.host, { timeout_ns = UPSTREAM_RESOLVE_NS, connector = servers.connector,
    servers = servers.servers })
  local _, _ = servers.connector:close()
  if found == nil then
    return nil, "https_proxy's host " .. up.host .. " does not resolve: " .. found_why
  end
  local addresses: {string} = {}
  for i, answer in ipairs(found) do addresses[i] = answer.address end
  up.addresses = addresses
  return up, ""
end

--- Starts a connector of `endpoints` (and `public`'s lists, if given),
--- waiting `wait_ns` for each connection: the process, or nil and why. A
--- table or list the core refuses is a why too.
local function started(endpoints: {Config.Endpoint}, wait_ns: integer,
                       public?: Child.ConnectorPublic): Child.ConnectorProcess | nil, string
  local ms = (wait_ns + 999999) // 1000000
  local called, process, why = pcall(Child.start_connector, endpoints, ms, public)
  if not called then return nil, (tostring(process):gsub("^.-:%d+: ", "")) end
  if process == nil then return nil, why end
  return process, ""
end

--- What a relay for the `connect` targets `grants` is handed, made now:
--- the connectors of this module's header, started, the upstream proxy
--- resolved, and the config's fields that say what the relay is handed
--- ([`Config.Handover`]). `own` is the host's own addresses
--- ([`Config.host_addresses`]), which the public connector refuses. Nil
--- and why, with nothing left running, where the upstream cannot be used
--- (as [`relay_start.upstream`] says), the table would hold more than 128
--- addresses, or a connector cannot start. Name servers that cannot be
--- read are no failure: the relay is told why
--- ([`Config.Config.unresolved`]), and reaches only what a grant names
--- literally, and the upstream. The caller closes the handover once the
--- relay has ended. `opts` is for tests.
--- @param grants {string} The policy's `connect` targets
--- @param own {string} The host's own addresses
--- @param opts relay_start.Options|nil What to read in place of the system's
--- @return Config.Handover|nil What the relay is handed
--- @return string Why there is none, "" otherwise
function relay_start.prepare(grants: {string}, own: {string}, opts?: relay_start.Options): Config.Handover | nil, string
  opts = opts or {}
  local up, up_why = relay_start.upstream(opts)
  if up == nil and up_why ~= "" then return nil, up_why end
  local literals, names = opened(grants)
  local table_rows: {Config.Endpoint} = {}
  local seen: {string: boolean} = {}
  local function add(entry: Config.Endpoint)
    local key = entry.host .. " " .. entry.port
    if not seen[key] then
      seen[key] = true
      table_rows[#table_rows + 1] = entry
    end
  end
  for _, entry in ipairs(literals) do add(entry) end
  if up ~= nil then
    for _, address in ipairs(up.addresses) do
      add({ host = numeric(assert(Address.parse(address))), port = up.port })
    end
  end
  if #table_rows > MOST_ENDPOINTS then
    return nil, ("connect names %s literally%s: %s, more than the relay's connector holds (%d); " ..
      "grant fewer addresses, or names"):format(String.counted(#literals, "address", "addresses"),
        up ~= nil and ", with the upstream proxy's" or "", String.counted(#table_rows, "endpoint"), MOST_ENDPOINTS)
  end
  local processes: {Child.ConnectorProcess} = {}
  local closed = false
  local function close()
    if closed then return end
    closed = true
    for _, process in ipairs(processes) do local _ = process:close() end
  end
  local function fail(why: string): nil, string
    close()
    return nil, why
  end
  local config: Config.Config = { grants = grants, own_addresses = own, log = "null", public = false }
  local fds: {integer: integer} = {}
  if up ~= nil then config.upstream_addresses = up.addresses end
  if #table_rows > 0 then
    local process, why = started(table_rows, Config.connect_ns)
    if process == nil then return fail("the connector of the addresses granted: " .. why) end
    processes[#processes + 1] = process
    config.table, fds[Config.table_fd] = table_rows, process.fd
  end
  if names then
    -- TODO: hand the relay several public connectors, and Relay.handed a
    -- free one for each connection: one process makes one connection at a
    -- time, so a connect that hangs holds every other connection to a
    -- granted name for up to Config.connect_ns.
    local process, why = started({}, Config.connect_ns, { deny = Address.deny_cidrs(), own = own })
    if process == nil then return fail("the public connector: " .. why) end
    processes[#processes + 1] = process
    config.public, fds[Config.public_fd] = true, process.fd
    local plan, plan_why = Relay.name_server_plan({ resolv_conf = opts.resolv_conf, servers = opts.servers })
    if plan == nil then
      config.unresolved = plan_why
    else
      local servers: {Config.Endpoint} = {}
      for i, server in ipairs(plan.servers) do
        servers[i] = { host = server.host, port = server.port }
      end
      local dns, dns_why = started(servers, plan.wait_ns)
      if dns == nil then return fail("the name servers' connector: " .. dns_why) end
      processes[#processes + 1] = dns
      config.name_servers, config.name_server_wait_ns, fds[Config.name_server_fd] = servers, plan.wait_ns, dns.fd
    end
  end
  return { config = config, fds = fds, close = close }, ""
end

return relay_start
