--- The sandbox's network relay: what a program held by a policy with
--- `connect` reaches the network through ([`Child.start`]), an HTTP CONNECT
--- and a SOCKS5 listener that match each request against the policy's
--- grants and connect only what they allow.
---
--- This entry is the part both sides of the relay share, which reaches no
--- network and starts nothing, so that the modules beneath the relay --
--- cosmic.net, cosmic.child and the starter in cosmic.sandbox -- can read
--- it without requiring what serves:
---
--- - `Address`, the address classes the relay refuses and how it parses
---   and picks an address ([`cosmic.relay.address`]);
--- - `Grant`, a policy's `connect` target read once
---   ([`cosmic.relay.grant`]);
--- - `Config`, what the starter and the relay's process agree on: its
---   ports, the proxy environment, the config it is handed
---   ([`cosmic.relay.config`]);
--- - `Wire`, the readers and writers of what the relay and its clients say
---   ([`cosmic.relay.wire`]);
--- - `nameservers`, the system's name servers as a connector's table
---   ([`cosmic.relay.resolv`]).
---
--- The relay that serves ([`cosmic.relay.server`]) and its process's main
--- ([`cosmic.relay.main`]) are members this entry does not carry: the
--- server requires cosmic.net, which requires this entry, so an entry that
--- carried the server would require itself. [`Child.start`] runs the main
--- by its name, on a database sealed with it as the main.
---
---     local env = Relay.Config.proxy_env({})
---     print(env.ALL_PROXY) -- socks5h://127.0.0.1:1080

local Address = require("cosmic.relay.address")
local Config = require("cosmic.relay.config")
local Grant = require("cosmic.relay.grant")
local Resolv = require("cosmic.relay.resolv")
local Wire = require("cosmic.relay.wire")

local record Relay
  --- The address classes the relay refuses, and how it parses an address
  --- and picks one of a name's answers: the package's
  --- [`cosmic.relay.address`], each documented there.
  Address: Address

  --- A policy's `connect` target, read once: the package's
  --- [`cosmic.relay.grant`], documented there.
  Grant: Grant

  --- What the relay's starter and its process agree on: the package's
  --- [`cosmic.relay.config`], each documented there.
  Config: Config

  --- What the relay reads from a program and answers it, and what a client
  --- of the relay sends: the package's [`cosmic.relay.wire`], each
  --- documented there.
  Wire: Wire

  --- One numeric endpoint of a connector's table ([`Net.Endpoint`]).
  type Endpoint = Resolv.Endpoint
end

Relay.Address = Address
Relay.Config = Config
Relay.Grant = Grant
Relay.Wire = Wire

--- The name servers the system's configuration names, each a numeric
--- endpoint at its TCP port: the table of a connector for
--- [`Net.ResolveOptions.connector`] that reaches nothing else
--- ([`Resolv.nameservers`], where the forms it reads and leaves out are
--- documented). Nil and why where they cannot be listed.
--- @param resolv_conf string|nil A resolv.conf to read in place of the system's
--- @return {Endpoint}|nil The servers
--- @return string Why there are none, "" otherwise
function Relay.nameservers(resolv_conf?: string): {Relay.Endpoint} | nil, string
  return Resolv.nameservers(resolv_conf)
end

return Relay
