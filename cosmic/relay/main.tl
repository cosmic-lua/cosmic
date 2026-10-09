--- The network relay's process: what [`Child.start`] runs, as this program's
--- core on a database sealed with this module as its main, for a policy
--- whose `connect` the relay serves ([`cosmic.relay.server`]).
---
--- It is handed, by the process that starts it:
---
--- - descriptor 3: the channel that carries the relay's HTTP CONNECT and
---   SOCKS5 listeners, bound in the program's network namespace and passed
---   out of it ([`Net.receive_listeners`] adopts them);
--- - from descriptor 4, where the config says it is handed them, the
---   control streams of the connectors its starter started
---   ([`cosmic.sandbox.relay`]), which it adopts:
---   at 4 the name servers'; at 5 the table's, of the addresses a grant
---   names literally and the upstream proxy's; and at 6 the public one,
---   for what a granted name resolves to;
--- - standard input: one line of JSON, a [`cosmic.relay.config`] `Config`,
---   and then nothing more until the process is to end. The grants, a
---   proxy's password and the rest are never in the arguments or the
---   environment, which other users' processes can read.
---
--- A `direct` config (macOS's start, [`cosmic.relay.config`]'s `direct`) hands it
--- neither: from descriptor 3 it is handed the listening sockets its
--- starter bound at one port of 127.0.0.1 and ::1 ([`cosmic.sandbox.relay`]'s
--- `loopback_listeners`), each for both protocols, which it serves behind
--- the config's token, refusing a config without one; and it connects and
--- resolves itself, as the profile it is held by allows.
---
--- It says `opened` on standard output once it runs (its database is open),
--- `ready` once it serves, or `error: <why>` and
--- ends with status 1, and it ends with status 0 when standard input
--- reaches end of file: the starter holds the pipe's write end for as long
--- as the program lives, and its death closes it.
---
--- Once the connector it was handed has ended ([`Relay.Handed.lost`]), or
--- its name servers' connector has ([`Relay.Spec.lost`]), it logs why,
--- stops serving and ends with status 1, as `error: <why>`, and its
--- starter then ends the program. It does so even where the other
--- still works: none is ever started anew,
--- so the program would be refused what the lost one reached for the rest
--- of its life, a failure that looks like the remote's, and an ended
--- program says plainly that its network is gone.
---
--- On Linux the process runs offline: its filter refuses every socket it would
--- make ([`cosmic.sandbox.relay`]'s `policy`), so what it reaches is what
--- the connectors it is handed reach. Every connection is checked against
--- the grants and the address classes by [`cosmic.relay.server`] and made by its
--- one connector ([`Relay.handed`]), and every name is resolved, once a grant
--- names it, over TCP through the name servers' connector, whose table
--- the starter read once. Where it had none to hand -- the name servers
--- could not be read, or nothing names a host -- the relay serves still,
--- refusing every name and saying why. It resolves the upstream proxy
--- never: it is told the addresses its starter resolved.

local Config = require("cosmic.relay.config")
local Connector = require("cosmic.internal.connector")
local Log = require("cosmic.log")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay.server")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

--- The most bytes of config the relay reads.
local MOST_CONFIG <const> = 1024 * 1024

--- The descriptor of the channel the sandbox's listeners come over.
local CHANNEL_FD <const> = 3

--- Says `line` on standard output, which the starter reads.
local function say(line: string)
  local _, _ = sys.write(1, line .. "\n")
end

--- Says `error: why` and answers the status of a relay that did not start.
local function failed(why: string): integer
  say("error: " .. (why:gsub("%c", " ")))
  return 1
end

--- One line from standard input, without its newline, or nil and why.
local function read_line(): string | nil, string
  local chunks: {string} = {}
  local size = 0
  while true do
    local data, why = sys.read(0, 4096)
    if data == nil then return nil, why end
    if data == "" then return nil, "standard input ended before the config" end
    local at = data:find("\n", 1, true)
    if at ~= nil then
      chunks[#chunks + 1] = data:sub(1, at - 1)
      return table.concat(chunks), ""
    end
    chunks[#chunks + 1] = data
    size = size + #data
    if size > MOST_CONFIG then
      return nil, "the config is past " .. String.counted(MOST_CONFIG, "byte")
    end
  end
end

--- Waits for standard input to end, in a task of the run.
local function until_end_of_input()
  while true do
    local ready, _ = Poll.readable(0)
    if not ready then return end
    local data, _ = sys.read(0, 4096)
    if data == nil or data == "" then return end
  end
end

--- [`Relay.start`], answering a spec it refuses (it raises) as nil and why.
local function started(spec: Relay.Spec): Relay.Serving | nil, string
  local server: Relay.Serving
  local ok, why = pcall(function()
    server = Relay.start(spec)
  end)
  if not ok then return nil, tostring(why) end
  return server, ""
end

--- `rows` as the endpoints [`Net`] takes.
local function endpoints_of(rows: {Config.Endpoint}): {Net.Endpoint}
  local out: {Net.Endpoint} = {}
  for i, row in ipairs(rows) do out[i] = { host = row.host, port = row.port } end
  return out
end

--- `rows` as the table a connector was started with.
local function table_of(rows: {Config.Endpoint}): {Connector.Endpoint}
  local out: {Connector.Endpoint} = {}
  for i, row in ipairs(rows) do out[i] = { host = row.host, port = row.port } end
  return out
end

--- The connector `config` says the relay is handed, adopted: what
--- [`Relay.handed`] takes, and the name servers' connector, or nil where
--- none is handed. Nil and why where one cannot be adopted.
local function adopted(config: Config.Config): Relay.Handed | nil, Net.Connector | nil, string
  local handed: Relay.Handed = {}
  if config.table ~= nil or config.public then
    local made, why = Connector.adopted(Config.connector_fd, config.table ~= nil and table_of(config.table) or nil, config.public,
      Config.connect_ns)
    if made == nil then return nil, nil, "the connector: " .. why end
    handed.connector = made
  end
  local dns: Net.Connector
  if config.name_servers ~= nil then
    local made, why = Connector.adopted(Config.name_server_fd, table_of(config.name_servers), false,
      config.name_server_wait_ns)
    if made == nil then return nil, nil, "the name servers' connector: " .. why end
    dns = made
  end
  return handed, dns, ""
end

--- Serves the relay `config` describes until standard input ends.
local function serve(config: Config.Config): integer
  local status = 1
  -- A listener on the host's loopback is one every user of the host reaches.
  if config.direct and (config.token == nil or config.listeners == nil) then
    return failed("a relay on the host's loopback needs its token and its listeners")
  end
  local adopting, dns, adopted_why = adopted(config)
  if adopting == nil then return failed(adopted_why) end
  local handed: Relay.Handed = adopting
  local logger = Log.new("relay")
  local log = function(line: string)
    local _, _ = logger:complain(line)
  end
  if config.log == "null" then log = function(_: string) end end
  local serving: Relay.Serving
  local lost: string
  -- No connector is started anew, so one that has ended, the name
  -- servers' among them, reaches nothing again:
  -- the relay ends rather than refuse each connection that needs it, and
  -- its starter ends the program with it.
  local function lose(why: string)
    if lost ~= nil then return end
    lost = why
    log(why .. ": the relay ends")
    if serving ~= nil then serving:stop() end
  end
  handed.lost = lose
  Poll.run(function()
    local http, socks: Net.Listener, Net.Listener
    local mixed: {Net.Listener}
    if config.direct then
      mixed = {}
      for i = 1, config.listeners or 0 do
        local listener, adopt_why = Net.listener_from(CHANNEL_FD + i - 1)
        if listener == nil then
          status = failed(adopt_why)
          return
        end
        if listener.address.port ~= (mixed[1] or listener).address.port then
          status = failed("the loopback listeners are at two ports")
          return
        end
        mixed[#mixed + 1] = listener
      end
    else
      local listeners, listeners_why = Net.receive_listeners(CHANNEL_FD)
      if listeners == nil then
        status = failed(listeners_why)
        return
      end
      http, socks = listeners[1], listeners[2]
      if http.address.port ~= Config.http_port or socks.address.port ~= Config.socks_port then
        status = failed("the listeners are at ports " .. http.address.port .. " and " ..
            socks.address.port .. ", not " .. Config.http_port .. " and " .. Config.socks_port)
        return
      end
    end
    -- With no connector handed, nothing a grant opens can be reached.
    local connect: Relay.Connector = function(address: string, port: integer, _: integer): Net.Conn | nil, string
      return nil, "relay: no connector was handed for " .. address .. ":" .. port
    end
    if config.direct then
      -- The address is one the relay has checked; the profile lets it
      -- connect anywhere.
      connect = function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
        return Net.connect(Net.tcp(address, port), { timeout_ns = timeout_ns })
      end
    elseif handed.connector ~= nil then
      connect = Relay.handed(handed)
    end
    -- Without the name servers' connector the relay serves still, and every
    -- name fails with the starter's why: an address a grant names needs no
    -- lookup. Where nothing names a host, no name passes the grants to be
    -- looked up, and the starter gives no why.
    local resolve: Net.ResolveOptions
    if dns ~= nil then
      resolve = { connector = dns, servers = endpoints_of(config.name_servers) }
    end
    local running, start_why = started({
      http = http, socks = socks, mixed = mixed, token = config.token, grants = config.grants, connector = connect,
      resolve = resolve, unresolved = config.unresolved,
      own_addresses = config.own_addresses, upstream = config.upstream, log = log, lost = lose,
    })
    if running == nil then
      status = failed(start_why)
      return
    end
    serving = running
    local ended = false
    local watch = Poll.spawn(function()
      until_end_of_input()
      ended = true
      serving:stop()
    end)
    say("ready")
    serving:wait()
    watch:cancel()
    if handed.connector ~= nil then local _, _ = handed.connector:close() end
    if dns ~= nil then local _, _ = dns:close() end
    status = ended and 0 or failed(lost or "the relay's listeners ended")
  end)
  return status
end

--- Reads the config and serves the relay. The sealed database's main.
--- @param _args {integer:string} The command line, which carries nothing
--- @return integer The exit status
local function main(_args: {integer:string}): integer
  -- The core has opened the database this runs on, which its starter now
  -- removes, so that no program can swap it; this process never reads its
  -- path again.
  say("opened")
  local line, why = read_line()
  if line == nil then return failed(why) end
  local config, config_why = Config.decode(line)
  if config == nil then return failed("config: " .. config_why) end
  return serve(config)
end

return main
