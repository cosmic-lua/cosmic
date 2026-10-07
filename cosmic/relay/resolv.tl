--- The name servers the system's resolver configuration names, as
--- numeric endpoints a connector's table takes: what [`Net.resolve`]
--- asks through a connector when its caller names none, and what the
--- relay's starter hands the relay a connector of. A member of
--- cosmic.relay, reached outside it as [`cosmic.relay`]'s `nameservers`.

local relay_address = require("cosmic.relay.address")

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

local record resolv
  --- One numeric endpoint of a connector's table: a numeric `host` and a
  --- `port` ([`Net.Endpoint`]).
  type Endpoint = raw_process.ConnectorEndpoint
end

--- One entry of c-ares's server list: the numeric host and the TCP port,
--- or nil for an entry of none of the list's forms or a link-local server
--- written with its interface (a "%" and its name), which a connector's
--- endpoint cannot carry.
local function nameserver_of(entry: string): resolv.Endpoint | nil
  local host, port, rest: string, string, string
  local uri = entry:match("^dns://(.*)$")
  if uri ~= nil then
    local tcp = uri:match("[?&]tcpport=(%d+)")
    host, port, rest = uri:match("^%[([%x:%.]+)%]:(%d+)(.*)$")
    if host == nil then host, port, rest = uri:match("^([%d%.]+):(%d+)(.*)$") end
    if rest ~= nil and rest:sub(1, 1) == "?" then rest = "" end
    port = tcp or port
  else
    host, port, rest = entry:match("^%[([%x:%.]+)%]:(%d+)(.*)$")
    if host == nil then host, port, rest = entry:match("^([%d%.]+):(%d+)(.*)$") end
  end
  if host == nil or rest ~= "" then return nil end
  local number = math.tointeger(tonumber(port))
  if number == nil or number < 1 or number > 65535 or relay_address.parse(host) == nil then
    return nil
  end
  return { host = host, port = number }
end

--- The name servers the system's configuration names, as [`Net.resolve`]
--- reads it (resolv.conf; on macOS, the system's DNS configuration
--- first), each a numeric endpoint at its TCP port, 53 for every server
--- resolv.conf names: the table of a connector for
--- [`Net.ResolveOptions.connector`] that reaches nothing else. With none
--- configured, the resolver's default, 127.0.0.1 at 53. A link-local
--- server written with its interface is left out, as no connector reaches
--- one; where every server is, the answer is nil and why.
--- Nil and why where they cannot be listed: the system's words where the
--- configuration cannot be read.
--- @param resolv_conf string|nil A resolv.conf to read in place of the system's
--- @return {Endpoint}|nil The servers
--- @return string Why there are none, "" otherwise
-- TODO: reach a link-local name server (fe80::1%eth0) through a connector
-- once a connector's endpoint carries an interface: it is left out today.
function resolv.nameservers(resolv_conf?: string): {resolv.Endpoint} | nil, string
  local listed, trouble = raw.nameservers(resolv_conf)
  if listed == nil then return nil, trouble end
  local servers: {resolv.Endpoint} = {}
  local skipped = ""
  for entry in listed:gmatch("[^,]+") do
    local server = nameserver_of(entry)
    if server ~= nil then
      servers[#servers + 1] = server
    elseif entry:find("%", 1, true) ~= nil then
      skipped = "net: the name server " .. entry .. " is scoped to an interface, which a connector cannot reach"
    else
      return nil, "net: the resolver lists a server as " .. entry
    end
  end
  if #servers == 0 then
    return nil, skipped ~= "" and skipped or "net: the resolver lists no name server"
  end
  return servers, ""
end

return resolv
