--- Real UDP packets for tests that need a peer on the wire: a bound
--- loopback socket to watch for a datagram, stand in for a silent DNS
--- server or receive a resolver's query. [`cosmic.net`] has no UDP socket
--- of its own; these few calls go to the raw socket module's instead.

local Poll = require("cosmic.poll")
local type raw_socket = require("cosmic.internal.socket")

local raw = require("cosmic.internal.socket")

--- A UDP socket bound by [`udp_fixture.bind`]. A class, so a `<close>` local holds one.
local class Bound
  --- Where it is bound, with the port the kernel chose for port 0.
  address: raw_socket.Address
  socket: raw_socket.Socket
  fd: integer
  mut open: boolean

  --- Closes it, ending a wait on it. Safe to call more than once.
  function close(self)
    if not self.open then return end
    self.open = false
    Poll.closing(self.fd)
    local _, _ = self.socket:close()
  end

  function __close(self)
    self:close()
  end
end

local record udp_fixture
  type Bound = Bound

  --- What a DNS query asks, as [`udp_fixture.question`] reads it.
  record Asked
    --- The name, its labels joined by dots.
    name: string
    qtype: integer
    --- Where the question ends in the query: the byte before the next section.
    after: integer
  end
end

--- Binds a UDP socket at `host` and `port` (0 for one the kernel chooses),
--- or answers nil and why not: a name is never looked up, which the
--- reason says ("not a numeric"), and a port in use is refused.
function udp_fixture.bind(host: string, port: integer): udp_fixture.Bound?, string
  local socket, why, errno = raw.datagram({ kind = "udp", host = host, port = port })
  if socket == nil then
    if errno == raw.EINVAL then why = why .. " (not a numeric IPv4 or IPv6 address)" end
    return nil, why
  end
  local address, trouble = raw.bound(socket:fd())
  if address == nil then
    local _, _ = socket:close()
    return nil, trouble
  end
  local bound: Bound = { address = address, socket = socket, fd = socket:fd(), open = true }
  return bound, ""
end

--- Sends one datagram from `bound` to `destination`, true or false and why.
function udp_fixture.send(bound: udp_fixture.Bound, data: string,
                          destination: raw_socket.Address): boolean, string
  while true do
    local ok, why, errno = raw.sendto(bound.fd, data, destination)
    if ok then return true, "" end
    if errno ~= raw.EAGAIN then return false, why end
    local ready, waiting = Poll.writable(bound.fd)
    if not ready then return false, waiting end
  end
end

--- Takes one datagram, waiting at most `timeout_ns` (no limit when nil):
--- the packet, or nil and why -- [`Poll.TIMEOUT`] when none came, and
--- a word of its own once `bound` is closed.
function udp_fixture.receive(bound: udp_fixture.Bound, timeout_ns?: integer): raw_socket.Packet?, string
  while true do
    if not bound.open then return nil, "closed" end
    local packet, why, errno = raw.recvfrom(bound.fd, 65535)
    if packet ~= nil then return packet, "" end
    if errno ~= raw.EAGAIN then return nil, why end
    local ready, waiting = Poll.readable(bound.fd, timeout_ns)
    if not ready then return nil, waiting end
  end
end

--- The question of a DNS `query`: its name, its type and where it ends.
--- @param query the bytes of a query of one question
--- @return what it asks
function udp_fixture.question(query: string): udp_fixture.Asked
  local labels: mut {string} = {}
  local at = 13
  while true do
    local size = query:byte(at)
    assert(size ~= nil, "a malformed query")
    if size == 0 then break end
    labels[#labels + 1] = query:sub(at + 1, at + size)
    at = at + size + 1
  end
  local qtype = string.unpack(">I2", query, at + 1)
  return { name = table.concat(labels, "."), qtype = qtype, after = at + 4 }
end

return udp_fixture
