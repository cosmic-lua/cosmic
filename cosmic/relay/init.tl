--- The sandbox's network relay, the part a policy with `connect` and a
--- program that reads its grants share: what a program held by a policy
--- with `connect` reaches the network through ([`Child.start`]) is an HTTP
--- CONNECT and a SOCKS5 listener that match each request against the
--- policy's grants and connect only what they allow.
---
--- This entry reaches no network and starts nothing. It carries:
---
--- - `Address`, the address classes the relay refuses and how it parses
---   and picks an address ([`cosmic.relay.address`]);
--- - `Grant`, a policy's `connect` target read once
---   ([`cosmic.relay.grant`]).
---
--- The relay's startup, its config, its protocol and its serving core
--- are internal to the standard library.
---
---     local bytes = Relay.Address.parse("127.0.0.1")
---     print(#bytes) -- 4

local Address = require("cosmic.relay.address")
local Grant = require("cosmic.relay.grant")

local record Relay
  --- The address classes the relay refuses, and how it parses an address
  --- and picks one of a name's answers: the package's
  --- [`cosmic.relay.address`], each documented there.
  Address: Address

  --- A policy's `connect` target, read once: the package's
  --- [`cosmic.relay.grant`], documented there.
  Grant: Grant
end

Relay.Address = Address
Relay.Grant = Grant

return Relay
