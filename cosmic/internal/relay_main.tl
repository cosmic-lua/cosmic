--- The network relay's process: what [`Child.start`] runs, as this program's
--- core on a database sealed with this module as its main, for a policy
--- whose `connect` the relay serves ([`cosmic.internal.relay_server`]).
---
--- It is handed, by the process that starts it:
---
--- - from descriptor 3, its listeners: on Linux, the channel that carries
---   the relay's HTTP CONNECT and SOCKS5 listeners, bound in the
---   program's network namespace and passed out of it
---   ([`Net.receive_listeners`] adopts them); where the config names
---   `listeners` (macOS's start), that many listening sockets its starter
---   bound at one port of 127.0.0.1 and ::1 ([`cosmic.internal.relay_start`]'s
---   `loopback_listeners`), each for both protocols, which it serves
---   behind the config's token, refusing a config without one;
--- - standard input: one line of JSON, a [`cosmic.internal.relay_config`] `Config`,
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
--- It connects and resolves itself, as the policy it is held by allows:
--- every connection is checked against the grants and the address
--- classes by [`cosmic.internal.relay_server`] before it is made, and
--- every name is resolved only once a grant names it. It resolves the
--- upstream proxy never: it is told the addresses its starter resolved.

local Config = require("cosmic.internal.relay_config")
local Log = require("cosmic.log")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.internal.relay_server")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

--- The most bytes of config the relay reads.
local MOST_CONFIG <const> = 1024 * 1024

--- The descriptor the relay's listeners come at: the channel they come
--- over, or the first of those a relay on the host's loopback is handed.
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
local function read_line(): string?, string
  local chunks: mut {string} = {}
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
local function started(spec: Relay.Spec): Relay.Serving?, string
  local ok, server = pcall(Relay.start, spec)
  if not ok then return nil, tostring(server) end
  return server, ""
end

--- What serving a relay leaves: the status to end with, the relay once it
--- is serving, and whether standard input ended.
local record Run
  mut status: integer
  mut serving?: Relay.Serving
  mut ended: boolean
end

--- Serves the relay `config` describes until standard input ends.
local function serve(config: Config.Config): integer
  -- A listener on the host's loopback is one every user of the host reaches.
  if config.listeners ~= nil and config.token == nil then
    return failed("a relay on the host's loopback needs its token")
  end
  local logger = Log.new("relay")
  local log = function(line: string)
    local _, _ = logger:complain(line)
  end
  if config.log == "null" then log = function(_: string) end end
  local run: Run = { status = 1, ended = false }
  Poll.run(function()
    local http, socks: Net.Listener?, Net.Listener?
    local mixed: mut {Net.Listener}?
    local count = config.listeners
    if count ~= nil then
      local gathered: mut {Net.Listener} = {}
      for i = 1, count do
        local listener, adopt_why = Net.listener_from(CHANNEL_FD + i - 1)
        if listener == nil then
          run.status = failed(tostring(adopt_why))
          return
        end
        if listener.address.port ~= (gathered[1] or listener).address.port then
          run.status = failed("the loopback listeners are at two ports")
          return
        end
        gathered[#gathered + 1] = listener
      end
      mixed = gathered
    else
      local listeners, listeners_why = Net.receive_listeners(CHANNEL_FD)
      if listeners == nil then
        run.status = failed(tostring(listeners_why))
        return
      end
      local first, second = listeners[1], listeners[2]
      if first == nil or second == nil then
        run.status = failed("the relay was handed fewer than its two listeners")
        return
      end
      http, socks = first, second
      if first.address.port ~= Config.http_port or second.address.port ~= Config.socks_port then
        run.status = failed("the listeners are at ports " .. tostring(first.address.port) .. " and " ..
            tostring(second.address.port) .. ", not " .. tostring(Config.http_port) .. " and " .. tostring(Config.socks_port))
        return
      end
    end
    -- The address is one the relay has checked; its policy lets it
    -- connect anywhere.
    local connect: Relay.Connect = function(address: string, port: integer, timeout_ns: integer): Net.Conn?, string
      local got, failure = Net.connect(Net.tcp(address, port), { timeout_ns = timeout_ns })
      if got == nil then return nil, tostring(failure) end
      return got, ""
    end
    local running, start_why = started({
      http = http, socks = socks, mixed = mixed, token = config.token, grants = config.grants, connect = connect,
      own_addresses = config.own_addresses, upstream = config.upstream, log = log,
    })
    if running == nil then
      run.status = failed(start_why)
      return
    end
    run.serving = running
    local watch = Poll.spawn(function()
      until_end_of_input()
      run.ended = true
      running:stop()
    end)
    say("ready")
    running:wait()
    watch:cancel()
    run.status = if run.ended then 0 else failed("the relay's listeners ended") end
  end)
  return run.status
end

--- Reads the config and serves the relay. The sealed database's main.
--- @param _args {string} The command line, which carries nothing
--- @return integer The exit status
local function main(_args: {string}): integer
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
