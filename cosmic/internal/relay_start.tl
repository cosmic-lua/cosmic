--- What the sandbox relay's starter reads and decides before the relay
--- starts (the relay's own side is [`cosmic.internal.relay_main`]), which
--- cosmic.child calls to start the relay: the relay's policy, the config
--- it is handed ([`relay.handover`]), the one lookup of the upstream
--- proxy's host, and, on macOS, the listeners of a relay on the host's
--- loopback ([`relay.hold_loopback`]). It sits here, not in
--- cosmic.relay.address or cosmic.relay.grant, because what it makes is
--- the sandbox's: a [`rules.Policy`] for the relay. Those two hold what the
--- relay and this starter share, and require nothing of cosmic.sandbox.
---
--- The relay connects and resolves itself on every platform, checking
--- each address against the grants and the address classes first
--- ([`cosmic.internal.relay_server`]):
---
--- - on macOS Seatbelt holds it under [`relay.policy`], whose
---   profile lets it connect anywhere, and it listens on the host's
---   loopback behind a token;
--- - on Linux Landlock and seccomp hold it under [`relay.policy`], started
---   in the host's network with inet sockets (`spawn`'s `online`), and it
---   serves the listeners the program binds in its own network, handed
---   over a channel.
---
--- Neither kernel holds where the relay connects: its own checks are the
--- only ones. The program's network is what holds the program.
---
--- The upstream proxy the caller's `https_proxy` names is resolved once,
--- by the starter ([`relay.resolved_upstream`]), and the relay is told its
--- addresses, which it never resolves again.
---
---     local handover = assert(relay.handover({ "api.github.com:443" }, {}))
---     print(handover.config.grants[1]) -- api.github.com:443

local Clock = require("cosmic.clock")
local Config = require("cosmic.internal.relay_config")
local Address = require("cosmic.relay.address")
local Grant = require("cosmic.relay.grant")
local Resolv = require("cosmic.internal.relay_resolv")
local type rules = require("cosmic.sandbox")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

--- The raw socket module, cosmic.net's too.
local type raw_socket = require("cosmic.internal.socket")

local raw = require("cosmic.internal.socket")

local record relay
  --- The listening sockets of a relay on the host's loopback, as macOS's
  --- start makes them ([`relay.loopback_listeners`]).
  record Loopback
    --- 127.0.0.1's, then ::1's where the host has an IPv6 loopback: each
    --- owns its descriptor, which the start hands on and then closes.
    sockets: {raw_socket.Socket}
    --- The port both are at.
    port: integer
  end
end

--- The upstream's lookup's whole time.
local RESOLVE_NS <const> = Clock.seconds(5)

--- The files the relay's resolver reads, each granted to the relay's
--- process where the host has it: c-ares reads them as each lookup starts,
--- and fails one where a file is there and cannot be read.
-- TODO: grant the relay none of these once Net.resolve takes its options
-- and hosts from its caller (an ARES_OPT_* set that reads no system file)
-- and the starter reads the name servers once: the relay reads the host's
-- resolv.conf and hosts at every lookup.
local RELAY_FILES <const>: {string} = {
  "/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf", "/etc/host.conf",
}

--- The policy the relay's process is started under, on the database at
--- `database` (whose SHA-256 is `digest`, in hex): this program's core on
--- it, the resolver's files read-only, and no promise beyond the basics a
--- policy gives. On Linux it has a pid namespace of its own; on macOS,
--- where Seatbelt holds it (`seatbelt`, [`Seatbelt.compile`]), the
--- "system" profile its core loads from. Its network is not the policy's
--- to say: the start of the relay gives it inet sockets in the host's own
--- network (`spawn`'s `online`), or on macOS what
--- [`Seatbelt.Options.serves_relay`] names, since it connects and
--- resolves itself, and no filter then holds where it connects, what it
--- sends over UDP, or what it binds and listens at.
--- @param database string The relay's sealed database
--- @param digest string The database's SHA-256, in hex
--- @param seatbelt boolean|nil Whether Seatbelt holds it (macOS)
--- @return rules.Policy The policy
function relay.policy(database: string, digest: string, seatbelt?: boolean): rules.Policy
  local grants: mut {rules.Grant} = {}
  for _, file in ipairs(RELAY_FILES) do
    local there, _ = sys.stat(file)
    if there ~= nil then grants[#grants + 1] = { path = file, letters = "r" } end
  end
  local held: rules.Database = { path = database, sha256 = digest }
  if seatbelt == true then
    grants[#grants + 1] = { profile = "system" }
    return { setup = { database = held }, grants = grants }
  end
  return { setup = { database = held }, isolate = { "proc" }, grants = grants }
end

--- How many ports [`relay.loopback_listeners`] tries before it gives up
--- finding one free on both loopbacks.
local LOOPBACK_TRIES <const> = 16

--- How many connections may wait at a relay's listener to be accepted.
local LOOPBACK_BACKLOG <const> = 128

--- Listening sockets at one port of 127.0.0.1 the kernel chooses and the
--- same port of ::1, for a relay on the host's loopback (macOS's start).
--- A program's profile allows it `localhost:PORT`, which Seatbelt reads as
--- both addresses, so a port of either that another process held would be
--- reachable from the program: the start holds both, and hands them to the
--- relay, so the port stays this sandbox's while either lives. Never hand
--- one to the program: Seatbelt does not refuse accept() on an inherited
--- listener, and any user of the host can connect to the port. Neither is bound with SO_REUSEPORT, so no other socket can
--- take the same address and port meanwhile. Where the port is taken on
--- ::1 another is tried, at most 16 times. Where the host has no IPv6
--- loopback (no port of ::1 can be bound) the 127.0.0.1 socket is alone:
--- no process can listen on ::1 there either, so the program's connects to
--- it reach nothing. Nil and why where no port is free on both.
--- @return relay.Loopback|nil The sockets and their port
--- @return string Why there are none, "" otherwise
function relay.loopback_listeners(): relay.Loopback?, string
  local last = ""
  for _ = 1, LOOPBACK_TRIES do
    local v4, why = raw.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, LOOPBACK_BACKLOG)
    if v4 == nil then return nil, "127.0.0.1: " .. why end
    local bound, bound_why = raw.bound(v4:fd())
    if bound == nil then
      local _, _ = v4:close()
      return nil, "127.0.0.1: " .. bound_why
    end
    local port = bound.port
    if port == nil then
      local _, _ = v4:close()
      return nil, "127.0.0.1: the kernel bound no port"
    end
    local v6, v6_why, errno = raw.listen({ kind = "tcp", host = "::1", port = port }, LOOPBACK_BACKLOG)
    if v6 ~= nil then return { sockets = { v4, v6 }, port = port }, "" end
    if errno ~= raw.EADDRINUSE then
      -- Another port of ::1 says whether this one is refused or ::1 is not there.
      local probe, _ = raw.listen({ kind = "tcp", host = "::1", port = 0 }, 1)
      if probe == nil then return { sockets = { v4 }, port = port }, "" end
      local _, _ = probe:close()
    end
    local _, _ = v4:close()
    last = v6_why
  end
  return nil, "no port of 127.0.0.1 the kernel chose was free on ::1 too, in " ..
    String.counted(LOOPBACK_TRIES, "try", "tries") .. ": " .. last
end

--- The addresses of `up`'s host, resolved now and once, as the system's
--- resolver gives them to this process, or `servers` (c-ares's server
--- list, for tests) where given: what the start tells its relay. A numeric
--- host is its own address. Nil and why where it does not resolve.
--- @param up Config.Upstream The upstream
--- @param servers string|nil Name servers in place of the system's
--- @return {string}|nil The addresses, numeric text
--- @return string Why there are none, "" otherwise
function relay.resolved_upstream(up: Config.Upstream, servers?: string): {string}?, string
  local bytes = Address.parse(up.host)
  if bytes ~= nil then
    return { if #bytes == 4 then table.concat(bytes, ".") else Grant.ipv6_text(bytes) end }, ""
  end
  local found, trouble = Resolv.lookup(up.host, { timeout_ns = RESOLVE_NS, servers = servers })
  if found == nil then
    return nil, "https_proxy's host " .. up.host .. " does not resolve: " .. trouble
  end
  local addresses: mut {string} = {}
  for i, answer in ipairs(found) do addresses[i] = answer.address end
  return addresses, ""
end

--- `up` with the numeric `addresses` its host resolved to, the value the
--- relay is handed.
local function completed_upstream(up: Config.Upstream, addresses: {string}): Config.Upstream
  return { host = up.host, port = up.port, authorization = up.authorization, no_proxy = up.no_proxy,
    addresses = addresses }
end

--- What the relay of the `connect` targets `connect` is told, `own` being
--- the host's own addresses, which it refuses: the targets, and the
--- upstream proxy the caller's `https_proxy` names, with its addresses
--- resolved once, here. It is handed no descriptor yet. Nil and why where
--- the upstream cannot be used or does not resolve.
--- @param connect {string} The policy's `connect` targets
--- @param own {string} The host's own addresses
--- @return Config.Handover|nil What the relay is told and handed
--- @return string Why the start cannot go on, "" otherwise
function relay.handover(connect: {string}, own: {string}): Config.Handover?, string
  local env: mut {string: string} = {}
  for _, name in ipairs({ "https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY" }) do
    local value = sys.getenv(name)
    if value ~= nil then env[name] = value end
  end
  local up, up_why = Config.upstream(env)
  if up == nil and up_why ~= "" then return nil, up_why end
  local config: Config.Config = { grants = connect, own_addresses = own, log = "null" }
  if up ~= nil then
    local found, found_why = relay.resolved_upstream(up)
    if found == nil then return nil, found_why end
    config.upstream = completed_upstream(up, found)
  end
  return { config = config, fds = {}, close = function() end }, ""
end

--- Binds the listening sockets of a relay on the host's loopback
--- ([`cosmic.internal.relay_start`]'s [`loopback_listeners`]) into `handover`: its config's
--- `listeners`, its descriptors from 3, and its `close`, which closes this
--- process's own hold of the port once the relay ends; the relay holds it
--- beside. The port, or nil and why.
function relay.hold_loopback(handover: Config.Handover): integer?, string
  local loopback, trouble = relay.loopback_listeners()
  if loopback == nil then return nil, trouble end
  local sockets, port = loopback.sockets, loopback.port
  handover.config.listeners = #sockets
  for i, socket in ipairs(sockets) do handover.fds[2 + i] = socket:fd() end
  local closing_closed: boolean = false
  handover.close = function()
    if closing_closed == true then return end
    closing_closed = true
    for _, socket in ipairs(sockets) do local _, _ = socket:close() end
  end
  return port, ""
end

return relay
