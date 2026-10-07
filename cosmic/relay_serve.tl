--- The network relay's process: what [`Child.start`] runs, as this program's
--- core on a database sealed with this module as its main, for a policy
--- whose `connect` the relay serves ([`cosmic.relay`]).
---
--- It is handed, by the process that starts it:
---
--- - descriptor 3: the channel that carries the relay's HTTP CONNECT and
---   SOCKS5 listeners, bound in the program's network namespace and passed
---   out of it ([`Net.receive_listeners`] adopts them);
--- - standard input: one line of JSON, a [`cosmic.relay_config`] `Config`,
---   and then nothing more until the process is to end. The grants, a
---   proxy's password and the rest are never in the arguments or the
---   environment, which other users' processes can read.
---
--- It says `opened` on standard output once it runs (its database is open),
--- `ready` once it serves, or `error: <why>` and
--- ends with status 1, and it ends with status 0 when standard input
--- reaches end of file: the starter holds the pipe's write end for as long
--- as the program lives, and its death closes it.
---
--- The process keeps the host's network, and so reaches the network the
--- program may not. What holds it is its own code: every connection is
--- checked against the grants and the address classes by [`cosmic.relay`]
--- and made by [`Net.connector`], and every name is resolved over TCP
--- through a connector whose table holds the host's name servers alone,
--- read once as it starts ([`Net.nameservers`]), so the resolver's sockets
--- reach nothing else.
-- TODO: drop the host network from this process once its starter (Child.start's
-- relay, cosmic/child.tl) starts its connectors and passes their control
-- streams, which it adopts with Net.connector_from (the TODO at spawn's
-- `host_network` in core/syscalls.c), so that it holds no inet socket of its
-- own in the host's network.

local Config = require("cosmic.relay_config")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
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

--- Serves the relay `config` describes until standard input ends.
local function serve(config: Config.Config): integer
  local status = 1
  local env: {string:string} = {}
  env.https_proxy, env.no_proxy = config.https_proxy, config.no_proxy
  local upstream, upstream_why = Relay.upstream(env)
  if upstream == nil and upstream_why ~= "" then return failed(upstream_why) end
  Poll.run(function()
    local listeners, listeners_why = Net.receive_listeners(CHANNEL_FD)
    if listeners == nil then
      status = failed(listeners_why)
      return
    end
    local http, socks = listeners[1], listeners[2]
    if http.address.port ~= Config.http_port or socks.address.port ~= Config.socks_port then
      status = failed("the listeners are at ports " .. http.address.port .. " and " ..
          socks.address.port .. ", not " .. Config.http_port .. " and " .. Config.socks_port)
      return
    end
    local connector, connector_why = Net.connector()
    if connector == nil then
      status = failed(connector_why)
      return
    end
    local made: Net.Connector = connector
    -- TODO: adopt this connector's control stream with Net.connector_from,
    -- once the relay's starter (cosmic/child.tl) starts it with the name
    -- servers it read, as the relay is to read no resolv.conf and start no
    -- process of its own.
    local nameservers, nameservers_why = Net.nameservers()
    if nameservers == nil then
      status = failed("the name servers: " .. nameservers_why)
      return
    end
    local dns, dns_why = Net.connector(nameservers)
    if dns == nil then
      status = failed("the name servers' connector: " .. dns_why)
      return
    end
    local resolver: Net.Connector = dns
    local connect = made:as_function()
    local log: function(line: string)
    if config.log == "null" then log = function(_: string) end end
    local serving, start_why = started({
      http = http, socks = socks, grants = config.grants, connector = connect,
      resolve = { connector = resolver },
      own_addresses = config.own_addresses, upstream = upstream, log = log,
    })
    if serving == nil then
      status = failed(start_why)
      return
    end
    local ended = false
    local watch = Poll.spawn(function()
      until_end_of_input()
      ended = true
      serving:stop()
    end)
    say("ready")
    serving:wait()
    watch:cancel()
    local _, _ = made:close()
    local _, _ = resolver:close()
    status = ended and 0 or failed("the relay's listeners ended")
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
