--- Real UDP packets for tests that need a peer on the wire: a bound
--- loopback socket to watch for a datagram, stand in for a silent DNS
--- server or receive a resolver's query. [`cosmic.net`] has no UDP socket
--- of its own; these few calls go to the raw socket module's instead.

local _ = require("cosmic.net") -- in the closure: [`raw_table`] searches for it by hand
local Poll = require("cosmic.poll")
local type raw_socket = require("cosmic.internal.socket")

local type Searcher = function(string): any, any

--- The raw socket table the store's searcher hands [`cosmic.net`]'s
--- loader, which carries the UDP calls [`cosmic.net`] itself does not.
local function raw_table(): raw_socket
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.net")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_socket -- cast: the table core/socket.h declares
    end
  end
  error("cosmic.net is handed no raw table")
end

local raw = raw_table()

local record udp_fixture
  --- A UDP socket bound by [`udp_fixture.bind`].
  record Bound
    --- Where it is bound, with the port the kernel chose for port 0.
    address: raw_socket.Address
    socket: raw_socket.Socket
    fd: integer
    open: boolean
    metamethod __close: function(Bound)
  end
end

--- Closes `bound`, ending a wait on it. Safe to call more than once.
function udp_fixture.close(bound: udp_fixture.Bound)
  if not bound.open then return end
  bound.open = false
  Poll.closing(bound.fd)
  local _, _ = bound.socket:close()
end

local bound_mt: metatable<udp_fixture.Bound> = { __close = udp_fixture.close }

--- Binds a UDP socket at `host` and `port` (0 for one the kernel chooses),
--- or answers nil and why not: a name is never looked up, which the
--- reason says ("not a numeric"), and a port in use is refused.
function udp_fixture.bind(host: string, port: integer): udp_fixture.Bound | nil, string
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
  local bound: udp_fixture.Bound = setmetatable({
    address = address, socket = socket, fd = socket:fd(), open = true,
  }, bound_mt)
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
function udp_fixture.receive(bound: udp_fixture.Bound, timeout_ns?: integer): raw_socket.Packet | nil, string
  while true do
    if not bound.open then return nil, "closed" end
    local packet, why, errno = raw.recvfrom(bound.fd, 65535)
    if packet ~= nil then return packet, "" end
    if errno ~= raw.EAGAIN then return nil, why end
    local ready, waiting = Poll.readable(bound.fd, timeout_ns)
    if not ready then return nil, waiting end
  end
end

return udp_fixture
