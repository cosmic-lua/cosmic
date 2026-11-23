--- The one spelling of a loopback IPv4 address that cosmic takes as one:
--- [`cosmic.net`]'s `is_loopback`, the `loopback` list of a sandbox
--- policy and of a test policy, and an OIDC provider's http URL all read
--- a host with it. It
--- requires nothing, so the build's policy rules can require it.
---
---     local Loopback = require("cosmic.internal.loopback")
---     assert(Loopback.ipv4("127.0.0.1") and not Loopback.ipv4("127.0.0.01"))

local record Loopback
end

--- Whether `host` is an address of 127/8 as four decimal numbers from 0
--- to 255, none with a leading zero (`127.0.0.1`). A name (`localhost`),
--- a shortened or octal spelling, an IPv6 address or a port is none.
function Loopback.ipv4(host: string): boolean
  local a, b, c = host:match("^127%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil or b == nil or c == nil then return false end
  for _, part in ipairs({ a, b, c }) do
    if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") or assert(math.tointeger(part)) > 255 then
      return false
    end
  end
  return true
end

return Loopback
