--- Whether an IPv4 address can only be a machine near this one: what
--- [`cosmic.mdns`]'s responder asks of a query's source before it
--- responds to it by unicast, so a query that names a far address as its
--- own draws no response to it.

local record Nearby
  --- Where a responder bound at a port sends its response to a query:
  --- to the group, to the query's source alone, or nowhere.
  enum Reply
    "group"
    "source"
    "none"
  end
end

--- Whether `host`, a numeric IPv4 address, is on the loopback
--- (127.0.0.0/8), link-local (169.254.0.0/16) or private (10.0.0.0/8,
--- 172.16.0.0/12, 192.168.0.0/16): an address the internet does not
--- route. False for anything else, and for a spelling that is not four
--- decimal octets.
local function near(host: string): boolean
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil or b == nil or c == nil or d == nil then return false end
  local octets: mut {integer} = {}
  for at, octet in ipairs({ a, b, c, d }) do
    if #octet > 3 or (#octet > 1 and octet:sub(1, 1) == "0") then return false end
    local value = assert(math.tointeger(octet))
    if value > 255 then return false end
    octets[at] = value
  end
  local first, second = assert(octets[1]), assert(octets[2])
  return first == 127 or first == 10 or (first == 169 and second == 254) or
    (first == 172 and second >= 16 and second <= 31) or (first == 192 and second == 168)
end

--- Where [`cosmic.mdns`]'s responder, bound at `port`, sends its response
--- to a query from `host` and `from_port` (RFC 6762 section 6.7): a query
--- from its own port is a member's, its response sent to the group; one
--- from another port is a program's, its response sent to its source
--- alone, and only where that source is a loopback, link-local or
--- private IPv4 address. A host that is nil is none.
function Nearby.reply(host: string?, from_port: integer?, port: integer): Nearby.Reply
  if from_port == port then return "group" end
  if host ~= nil and near(host) then return "source" end
  return "none"
end

return Nearby
