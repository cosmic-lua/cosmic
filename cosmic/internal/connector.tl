--- The native TCP connector's client: it starts the confined connector
--- process the core's `connector_start` makes, or adopts the control
--- stream of one a starter made, and speaks the connector's wire protocol
--- over that stream. [`cosmic.net`] and the relay answer a [`Net.Connector`] over it,
--- [`cosmic.child`] starts the connectors a relay is handed, and
--- [`cosmic.internal.relay_start`] asks one for the connections of a lookup, so
--- the binary protocol (the connector's hello, a tagged request and its
--- tagged reply, and the one socket passed after a success) is spoken here
--- and nowhere else.
---
--- The protocol may change with the core: nothing outside cosmic's own
--- modules may speak it, which is why this module is internal
--- ([`build.positions`]) and the connector a program holds is the opaque
--- [`Net.Connector`].

local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
local type Resolv = require("cosmic.internal.relay_resolv")
local sys = require("cosmic.sys")

local Connection = require("cosmic.internal.connection")

--- The raw process and socket tables, handed together to this chunk's
--- loader as the second argument `require` passes it: the process table
--- starts and reaps the connector, the socket table speaks to it.
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")

local extra: any = select(2, ...)
local raw: raw_socket
local process_raw: raw_process
if type(extra) == "table" then
  raw = extra as raw_socket
  process_raw = extra as raw_process
else
  raw = require("cosmic.internal.socket")
  process_raw = require("cosmic.internal.process")
end

local CONNECTOR_GRACE_NS <const> = Clock.seconds(1)
--- The flights a connector with a table and public lists keeps for each
--- kind of request against the other: a connect may hang for the process's
--- whole wait, and one given up on counts until answered, so neither kind
--- may fill the process and keep the other waiting.
local TABLE_RESERVE <const> = 16

-- The most connections one connector process makes at once.
local CONNECTOR_FLIGHT <const> = raw.CONNECTOR_FLIGHT

--- A native connector process, or the control stream of one: the object
--- that owns the stream's descriptor and, for a connector this process
--- started, reaps it.
local record Process
  --- The control stream's descriptor, nonblocking and the object's to
  --- close, which speaks the protocol the core's `connector_start` says:
  --- the connector's hello first, then a tagged reply to each request,
  --- in the order the connects end. Valid until `close`.
  fd: integer
  --- The connector's process id, which `close` reaps: nil for a stream
  --- adopted or borrowed, whose process is its starter's to end.
  pid: integer | nil
  --- Whether `close` has not been called.
  open: boolean
  --- Whether the descriptor is another's, which `close` leaves open.
  borrowed: boolean
  --- Ends the connector, which holds no state worth finishing, and reaps
  --- it (an adopted one is only disconnected): true, and true again once
  --- closed. A connector dropped unclosed is ended and reaped when it is
  --- collected.
  close: function(Process): boolean
  metamethod __close: function(Process)
end

local end_connector: function(Process, boolean)

local process_mt: metatable<Process> = {
  __index = Process,
  __close = function(self: Process)
    local _ = self:close()
  end,
  __gc = function(self: Process)
    end_connector(self, true)
  end,
}

--- Ends `connector` and reaps it. A process this one adopted may already
--- have been reaped (`collect` takes every child), and its pid may be
--- another process's by now: it is signalled only while it is still this
--- one's unreaped child.
end_connector = function(connector: Process, collecting: boolean)
  if not connector.open then return end
  connector.open = false
  if connector.borrowed then return end
  -- A task parked on the stream is woken, and the descriptor number is
  -- not read again once another file may hold it. A collector must not
  -- touch the run's state.
  if not collecting then Poll.closing(connector.fd) end
  local _, _ = sys.close(connector.fd)
  if connector.pid == nil then return end
  local seen, gone = process_raw.waitpid(connector.pid, true)
  if seen == nil or gone ~= nil and gone ~= "" or seen.pid ~= 0 then return end
  -- Nothing the connector is doing is worth waiting for: it may be in a
  -- connect that would end only at its own timeout.
  local _, _ = sys.kill(connector.pid, sys.SIGKILL)
  local _, _ = process_raw.waitpid(connector.pid, false)
end

--- Ends the connector and reaps it, waking a task waiting on its stream.
function Process:close(): boolean
  end_connector(self, false)
  return true
end

--- Waits for `fd` to be readable, or writable, at most `timeout_ns`, which
--- the caller has held to what a wait can last: in a
--- task of a run, through it; anywhere else, in the raw wait, which
--- also ends at a signal the innermost [`Signal.guard`] caught.
local function waited(fd: integer, writable: boolean, timeout_ns: integer | nil): boolean, string
  -- TODO: wait through Poll.wait alone, and in `connection` too, once
  -- cosmic.poll has what the raw wait outside a task has: a core binding
  -- that gives it the core's cosmic_signal_caught (only core/socket.c's
  -- waits and sys.flock read it today), a fourth shared answer word for
  -- a wait a signal interrupted, and a loop in Poll.wait outside a task
  -- that polls in slices to look for one. A Conn's read and write are
  -- then Stream.from_fd and Stream.to_fd (see the TODO at SocketConn:read
  -- in cosmic/net.tl).
  if Poll.in_task() then
    return Poll.wait(fd, writable and sys.POLLOUT or sys.POLLIN, timeout_ns)
  end
  local ok, trouble, errno = raw.wait(fd, writable, Poll.milliseconds(timeout_ns))
  if ok then return true, "" end
  if errno == raw.ETIMEDOUT then return false, Poll.TIMEOUT end
  if errno == raw.EINTR then return false, "interrupted" end
  return false, trouble
end

--- What a host and port are called in a failure, an IPv6 host in brackets.
local function named(host: string, port: integer): string
  if host:find(":", 1, true) then host = "[" .. host .. "]" end
  return host .. ":" .. tostring(port)
end

--- A request sent on a connector's stream whose reply has not been
--- taken: what it asked for, so its socket is checked, and, once
--- answered, the connection or why not. One its caller gave up on is
--- still answered, its socket closed, so the stream stays in step.
local record Pending
  host: string
  port: integer
  -- What a refusal by the connector's lists says.
  refusal: string
  given_up: boolean
  done: boolean
  socket: raw_socket.Socket
  why: string
  -- Whether its caller took `socket`: one answered but left behind is closed.
  taken: boolean
  -- On a connector with a table and public lists, which kind it is,
  -- "table" or "public", counted in its channel's table_count or
  -- public_count until answered; "" on any other.
  kind: string
end

--- One connector process's control stream, which every request to it
--- shares: each request is tagged, and whichever caller finds the stream
--- readable reads what replies there are, a part at a time as the stream
--- has them, and hands each to the request its tag names. A reply is read
--- as its header (the tag and the errno, eight bytes) and, after a
--- success, the marker with its socket, never more than that at once: a
--- read past the header would take the marker and drop its socket.
local record Channel
  process: Process
  -- Whether the connector's CONNECTOR_HELLO has been read and matched;
  -- `hello` holds what of it has been read until then.
  greeted: boolean
  hello: string
  -- The tag the next request takes, from 1, wrapping at 2^32.
  next_tag: integer
  -- Each request sent whose reply has not been taken, by tag, those
  -- given up on among them, and how many there are.
  pending: {integer: Pending}
  count: integer
  -- Of `count`, the table and the public requests of a connector with both,
  -- which each hold at most CONNECTOR_FLIGHT less TABLE_RESERVE flights.
  table_count: integer
  public_count: integer
  -- What of a reply's header has been read.
  header: string
  -- The request whose socket comes next, its header read, and its tag;
  -- nil for none.
  passing: Pending
  passing_tag: integer
  -- Why the stream is out of step or gone; nil while it is in step. Once
  -- set, the process's descriptor is closed and its number is never used
  -- again: every predicate a caller waits on before it writes or hands
  -- the stream on requires this nil.
  lost: string
  -- How many times a read changed what a waiter looks at (the hello read,
  -- a request answered), so a reader knows to wake the others.
  progress: integer
end

local function channel_of(process: Process): Channel
  return { process = process, greeted = false, hello = "", next_tag = 1, pending = {}, count = 0, table_count = 0, public_count = 0,
    header = "", progress = 0 }
end

--- Gives the stream of `channel` up, `why` it is lost: every request
--- waiting on it fails so, and its process is closed, which wakes a task
--- waiting on the stream.
local function lose(channel: Channel, why: string)
  if channel.lost ~= nil then return end
  channel.lost = why
  for _, pending in pairs(channel.pending) do
    if not pending.done then pending.done, pending.why = true, why end
  end
  channel.pending, channel.count, channel.table_count, channel.public_count, channel.passing =
    {}, 0, 0, 0, nil
  local _ = channel.process:close()
end

--- Answers `pending`, the request of `tag`, with `socket` or why not; one
--- given up on has its socket closed.
local function answer(channel: Channel, tag: integer, pending: Pending, socket: raw_socket.Socket, why: string)
  channel.pending[tag] = nil
  channel.count = channel.count - 1
  if pending.kind == "table" then
    channel.table_count = channel.table_count - 1
  elseif pending.kind == "public" then
    channel.public_count = channel.public_count - 1
  end
  channel.progress = channel.progress + 1
  if pending.given_up then
    if socket ~= nil then local _, _ = socket:close() end
    return
  end
  pending.done, pending.socket, pending.why = true, socket, why
end

--- Whether the numeric hosts `a` and `b` are one address, however
--- each is spelled.
local function same_host(a: string, b: string): boolean
  if a == b then return true end
  local x, y = Relay.Address.parse(a), Relay.Address.parse(b)
  return x ~= nil and y ~= nil and table.concat(x, ",") == table.concat(y, ",")
end

--- What a reply's errno `status` says for `pending`.
local function refused_why(status: integer, pending: Pending): string
  if status == raw.ETIMEDOUT then return Poll.TIMEOUT end
  if status == raw.CONNECTOR_DENIED and pending.refusal ~= "" then return pending.refusal end
  if status == raw.CONNECTOR_BUSY then
    return "net: the connector is busy: it makes at most " .. CONNECTOR_FLIGHT .. " connections at once"
  end
  return sys.errno_message(status)
end

--- Takes the socket `channel.passing` waits for, if it has come. The
--- socket is taken only if it is a stream connected to that very host and
--- port. One connected to nothing (the far side reset it as it was made)
--- fails that request alone; one connected elsewhere, or a descriptor
--- that is no stream socket, is no reply a connector that works gives,
--- so the stream is given up as one that misbehaves. False where the
--- socket has not come yet or the stream is lost.
local function take_socket(channel: Channel, tag: integer): boolean
  local pending = channel.passing
  local received, because, failure = raw.recvfds(channel.process.fd, 1)
  if received == nil then
    if failure ~= raw.EAGAIN then lose(channel, because) end
    return false
  end
  channel.passing = nil
  local socket = received[1]
  local peer, peer_why, peer_errno = raw.peer(socket:fd())
  local wanted = named(pending.host, pending.port)
  if peer == nil then
    local _, _ = socket:close()
    -- macOS answers EINVAL for a socket its far side reset, Linux ENOTCONN.
    if peer_errno == raw.ENOTCONN or peer_errno == raw.EINVAL then
      answer(channel, tag, pending, nil, "net: the connection to " .. wanted .. " ended as it was made")
      return true
    end
    lose(channel, "net: the connector passed a descriptor that is no connected stream socket (" .. peer_why .. ")")
    return false
  end
  if peer.port ~= pending.port or not same_host(peer.host, pending.host) then
    local _, _ = socket:close()
    lose(channel, "net: the connector passed a socket connected to " .. named(peer.host, peer.port) .. ", not " .. wanted)
    return false
  end
  answer(channel, tag, pending, socket, "")
  return true
end

--- Reads what the stream of `channel` holds now, without waiting: its
--- CONNECTOR_HELLO first, then replies, each handed to its request. It
--- stops where the stream has nothing more, or is lost.
-- TODO: read the replies to requests given up on as they come, so that an
-- idle connector's stream holds none of their connections (up to
-- CONNECTOR_FLIGHT) until the next request reads it, once cosmic.poll has
-- a task a run does not wait for: a task spawned to read them would hold
-- Poll.run open for the connector's whole wait.
local function read_replies(channel: Channel)
  while channel.lost == nil do
    if not channel.process.open then
      lose(channel, "net: the connector is closed")
      return
    end
    if channel.passing ~= nil then
      if not take_socket(channel, channel.passing_tag) then return end
    else
      local want = channel.greeted and 8 - #channel.header or 4 - #channel.hello
      local data, why, errno = sys.read(channel.process.fd, want)
      if data == "" then
        lose(channel, "net: the connector has ended")
        return
      elseif data == nil then
        if errno ~= raw.EAGAIN then lose(channel, why) end
        return
      elseif not channel.greeted then
        channel.hello = channel.hello .. data
        if #channel.hello == 4 then
          local said_first = string.unpack(">I4", channel.hello)
          if said_first ~= raw.CONNECTOR_HELLO then
            lose(channel, ("net: the connector speaks another protocol than this program's: it said 0x%08x, " ..
              "not 0x%08x"):format(said_first, raw.CONNECTOR_HELLO))
            return
          end
          channel.greeted = true
          channel.progress = channel.progress + 1
        end
      else
        channel.header = channel.header .. data
        if #channel.header == 8 then
          local tag, status = string.unpack(">I4I4", channel.header)
          channel.header = ""
          local pending = channel.pending[tag]
          if pending == nil then
            lose(channel, "net: the connector replied to a request it was not asked (tag " .. tag .. ")")
            return
          end
          if status ~= 0 then
            answer(channel, tag, pending, nil, refused_why(status, pending))
          else
            channel.passing, channel.passing_tag = pending, tag
          end
        end
      end
    end
  end
end

--- [`read_replies`], and then, where what it read answers another
--- task's request or makes room, wakes every task waiting on the stream
--- to look again: a task parked in its wait would otherwise sleep on until
--- more bytes came, or its deadline. A stream lost was woken by its
--- closing.
-- TODO: wake only the tasks whose request was answered, and one waiting
-- for room for each slot freed, with a wakeup of each request's own: every
-- waiter looks again at each reply, so n waiting cost n looks a reply.
local function pump(channel: Channel)
  local before = channel.progress
  read_replies(channel)
  if channel.lost == nil and channel.progress ~= before then Poll.wake(channel.process.fd) end
end

--- Waits on the stream of `channel` until `ready` holds, reading what
--- comes meanwhile, by `deadline` (nil for none): true, or false and why
--- not, the stream's loss among them, and a cancel's [`Poll.CANCELLED`]
--- before it. With `late`, `ready` is looked at once more after a wait
--- fails, as another task may have answered it meanwhile: for an answer
--- already come, never for leave to act, which a caller that has timed
--- out or been cancelled no longer has.
local function await(channel: Channel, deadline: integer | nil, late: boolean,
                     ready: function(): boolean): boolean, string
  while true do
    pump(channel)
    if ready() then return true, "" end
    if channel.lost ~= nil then return false, channel.lost end
    local left = deadline ~= nil and math.max(0, deadline - Clock.monotonic_ns()) or nil
    local woke, why = waited(channel.process.fd, false, left)
    if not woke then
      if late then
        pump(channel)
        if ready() then return true, "" end
      end
      if why == Poll.CANCELLED then return false, why end
      return false, channel.lost or why
    end
  end
end

--- Marks a request given up on where its caller leaves before its reply,
--- however it leaves, a task killed in its wait included, and closes a
--- connection answered but not taken.
local record Asking
  pending: Pending
  metamethod __close: function(Asking)
end

local asking_mt: metatable<Asking> = {
  __close = function(self: Asking)
    local pending = self.pending
    if not pending.done then
      pending.given_up = true
    elseif pending.socket ~= nil and not pending.taken then
      local _, _ = pending.socket:close()
    end
  end,
}

--- Asks the connector of `channel` with `body`, a request less its tag,
--- for a socket connected to `host` at `port` by `deadline`, once its hello has
--- been read and fewer than CONNECTOR_FLIGHT requests are pending (and,
--- for a `kind` of "table" or "public", fewer than CONNECTOR_FLIGHT less
--- TABLE_RESERVE of its kind): the socket, or nil and why. A request given up on
--- stays pending until its reply comes, which the connector sends within
--- the request's wait.
local function ask(channel: Channel, body: string, host: string, port: integer, deadline: integer,
                   refusal: string, kind: string): raw_socket.Socket | nil, string
  local room, waiting = await(channel, deadline, false, function(): boolean
    return channel.lost == nil and channel.greeted and channel.count < CONNECTOR_FLIGHT and
      (kind ~= "table" or channel.table_count < CONNECTOR_FLIGHT - TABLE_RESERVE) and
      (kind ~= "public" or channel.public_count < CONNECTOR_FLIGHT - TABLE_RESERVE)
  end)
  if not room then return nil, waiting end
  local tag = channel.next_tag
  while channel.pending[tag] ~= nil do tag = tag % 0xffffffff + 1 end
  channel.next_tag = tag % 0xffffffff + 1
  local request = string.pack(">I4", tag) .. body
  -- send, not write: a connector that has ended is EPIPE, never SIGPIPE.
  local sent, wrote = raw.send(channel.process.fd, request)
  if sent ~= #request then
    -- A request half sent leaves the stream out of step.
    lose(channel, "net: could not ask the connector: " .. tostring(wrote))
    return nil, channel.lost
  end
  local pending: Pending = { host = host, port = port, refusal = refusal,
    given_up = false, done = false, kind = kind }
  channel.pending[tag] = pending
  channel.count = channel.count + 1
  if kind == "table" then
    channel.table_count = channel.table_count + 1
  elseif kind == "public" then
    channel.public_count = channel.public_count + 1
  end
  local asking: Asking = setmetatable({ pending = pending }, asking_mt)
  local _held <close> = asking
  local answered, why = await(channel, deadline, true, function(): boolean return pending.done end)
  if not answered then return nil, why end
  if pending.socket == nil then return nil, pending.why end
  pending.taken = true
  return pending.socket, ""
end

--- A request's body, past its tag: `index` and `port`, then the wait in
--- milliseconds `timeout_ns` asks (at least 1, so 0 is never the
--- connector's own), and, for a public one, the family and the address
--- `bytes` in 16 bytes.
local function request_body(index: integer, port: integer, timeout_ns: integer, bytes?: {integer}): string
  local wait = math.max(1, math.min(0xffffffff, (timeout_ns + 999999) // 1000000))
  if bytes == nil then
    return string.pack(">I4I4I4I4", index, port, wait, 0) .. string.rep("\0", 16)
  end
  return string.pack(">I4I4I4I4", index, port, wait, #bytes == 4 and 4 or 6) ..
    string.char(table.unpack(bytes)) .. string.rep("\0", 16 - #bytes)
end

--- Whether `entry` allows `port` at its host.
local function endpoint_allows(entry: raw_process.ConnectorEndpoint, port: integer): boolean
  if entry.port ~= 0 then return entry.port == port end
  return port >= 1 and port <= 65535
end

--- The wait word 0 of a table request asks for the connector's own wait
--- to connect.
local function own_wait_body(index: integer, port: integer): string
  return string.pack(">I4I4I4I4", index, port, 0, 0) .. string.rep("\0", 16)
end

local CONNECTOR_DEFAULT_NS <const> = Clock.seconds(10)

--- A connector over a [`Process`]'s control stream, which is what a
--- [`Net.Connector`] is: it asks the process for the sockets it passes and
--- answers them as connections.
local record Served is Connection.Connector
  -- The endpoints the process is confined to, in order; empty for a
  -- public-only connector.
  endpoints: {raw_process.ConnectorEndpoint}
  -- The connector's wait to connect, in milliseconds.
  timeout_ms: integer
  -- What a public process refuses, kept to start it again; nil for a
  -- connector whose process is not public.
  public: raw_process.ConnectorPublic
  -- Whether the process serves an inherited stream, which is never started
  -- again.
  inherited: boolean
  -- Whether its process takes public requests.
  accepts_public: boolean
  -- The stream of the process serving a table, nil before its first
  -- start; one lost is replaced at the next request where the process is
  -- this one's to start.
  channel: Channel
  open: boolean

  connect: function(Served, address: Connection.Address, opts?: Connection.ConnectOptions):
    Connection.Conn | nil, string
  ended: function(Served): boolean
  close: function(Served): boolean, string
  --- The 1-based index of the table's first endpoint that allows `port`
  --- at `host`, or nil for none.
  find: function(Served, host: string, port: integer): integer | nil
  --- A socket connected to the table's endpoint `index` at `port`, by
  --- `deadline` (nil for the connector's wait and a second more).
  through: function(Served, index: integer, port: integer, deadline: integer | nil):
    raw_socket.Socket | nil, string
  --- Why the stream is lost, or nil while it is in step or not started.
  lost: function(Served): string | nil
end

local served_mt: metatable<Served> = {
  __index = Served,
  __close = function(self: Served)
    local _, _ = self:close()
  end,
}

-- How [`cosmic.net`] makes a connection of a socket and judges an address,
-- which it hands over as it loads.
local make_conn: function(socket: raw_socket.Socket, timeout_ns: integer | nil): Connection.Conn
local address_trouble: function(address: any): string

-- Every connector this module made, held weakly: what a lookup through a
-- connector finds its [`Served`] by.
local made: {Connection.Connector: Served} = setmetatable({}, { __mode = "k" })

local record Leaf
  type Process = Process
  type Endpoint = raw_process.ConnectorEndpoint
  type Public = raw_process.ConnectorPublic
  type Served = Served

  --- The most endpoints a connector's table holds.
  MAX_ENDPOINTS: integer

  register: function(make: function(socket: raw_socket.Socket, timeout_ns: integer | nil): Connection.Conn,
    trouble: function(address: any): string)
  checked_endpoints: function(endpoints: any, empty: boolean, level: integer): {raw_process.ConnectorEndpoint}
  checked_timeout_ms: function(timeout_ns: integer | nil, level: integer): integer
  start: function(endpoints: {raw_process.ConnectorEndpoint}, timeout_ms: integer,
    public?: raw_process.ConnectorPublic): Process | nil, string
  connector: function(endpoints: {raw_process.ConnectorEndpoint}, timeout_ms: integer,
    public?: raw_process.ConnectorPublic): Connection.Connector | nil, string
  adopted: function(fd: integer, held?: {raw_process.ConnectorEndpoint}, public?: boolean, timeout_ns?: integer):
    Connection.Connector | nil, string
  served: function(connector: Connection.Connector): Served | nil
  connects: function(fd: integer, servers: {raw_socket.ThroughServer}, reply_ns: integer):
    function(index: integer, port: integer, deadline: integer | nil): Resolv.Connection | nil, string
  waited: function(fd: integer, writable: boolean, timeout_ns: integer | nil): boolean, string
end

Leaf.MAX_ENDPOINTS = 128
Leaf.waited = waited

--- Hands this module how [`cosmic.net`] makes a connection of a connected
--- `socket` (waiting `timeout_ns` on its reads and writes) and judges an
--- `address`, as it loads: a connector is used only once cosmic.net is
--- loaded, for [`Net.connector`] is how a program gets one.
function Leaf.register(make: function(socket: raw_socket.Socket, timeout_ns: integer | nil): Connection.Conn,
                       trouble: function(address: any): string)
  make_conn, address_trouble = make, trouble
end

--- `endpoints` as a copy, so the caller's later changes to its table reach
--- neither the checks here nor a process started again; it raises, at
--- `level` above the caller, for one that is no list of 1 through 128
--- endpoints (0 where `empty`).
function Leaf.checked_endpoints(endpoints: any, empty: boolean, level: integer): {raw_process.ConnectorEndpoint}
  local least = empty and 0 or 1
  if not endpoints is {any} or #endpoints < least or #endpoints > Leaf.MAX_ENDPOINTS then
    error("net: endpoints must be from " .. least .. " to " .. Leaf.MAX_ENDPOINTS ..
        " numeric endpoints", level + 1)
  end
  local kept: {raw_process.ConnectorEndpoint} = {}
  for i, entry in ipairs(endpoints) do
    local host, port: any, any
    if entry is {string: any} then host, port = entry.host, entry.port end
    if not host is string or not port is integer or port < 0 or port > 65535 then
      error("net: endpoints[" .. i .. "] must be a host and a port from 0 to 65535", level + 1)
    end
    kept[i] = { host = host, port = port }
  end
  return kept
end

--- A connector's wait to connect in milliseconds, from `timeout_ns` (nil
--- for 10 seconds), raising at `level` above the caller for one out of
--- range.
function Leaf.checked_timeout_ms(timeout_ns: integer | nil, level: integer): integer
  local chosen = timeout_ns or CONNECTOR_DEFAULT_NS
  if math.type(chosen) ~= "integer" or chosen < 1000000 or chosen > 60000000000 then
    error("net: timeout_ns must be an integer from 1 millisecond to 60 seconds", level + 1)
  end
  return (chosen + 999999) // 1000000
end

--- Starts the sandbox's native TCP connector, confined to the numeric
--- `endpoints` (at most 128, each a canonical IPv4 or IPv6 `host` and a
--- `port`, 0 for any nonzero port at that address) and to nothing else:
--- no file, no exec, no other address. It connects, within `timeout_ms`
--- milliseconds (1 to 60000) each, to one endpoint a request names and
--- passes the connected socket back over its control stream; one
--- connector serves any number of requests, several at once, until it is
--- closed. It answers nil and why where this host cannot confine one:
--- Linux on x86_64 and aarch64 only. An `endpoints` that is no table of
--- such endpoints, or a `timeout_ms` outside 1 to 60000, raises.
---
--- With `public` (`deny`, the numeric "address/bits" prefixes it refuses,
--- and `own`, the host's own addresses), the connector also connects to
--- an address its table lacks, once it has judged the address against
--- those lists itself, and `endpoints` may be empty.
-- TODO: confine the connector on macOS with Seatbelt's numeric remote rules:
-- core/connector.c's connector_start answers ENOSYS there.
--- @param endpoints {raw_process.ConnectorEndpoint} The addresses the connector may reach
--- @param timeout_ms integer Its wait to connect, 1 to 60000
--- @param public raw_process.ConnectorPublic|nil The lists of a public connector
--- @return Process|nil The connector
--- @return string Why not, when it is nil
function Leaf.start(endpoints: {raw_process.ConnectorEndpoint}, timeout_ms: integer,
                    public?: raw_process.ConnectorPublic): Process | nil, string
  local pair, why = process_raw.connector_pair()
  if pair == nil then return nil, "child: " .. why end
  local called, pid, trouble, errno = pcall(process_raw.connector_start, endpoints, pair[2], timeout_ms, public)
  local _, _ = sys.close(pair[2])
  if not called then
    -- A table or a timeout the core refuses: the pair is not leaked by it.
    local _, _ = sys.close(pair[1])
    error(pid, 0)
  end
  if pid == nil then
    local _, _ = sys.close(pair[1])
    if errno == sys.ENOSYS or errno == sys.EOPNOTSUPP then
      return nil, "child: the native connector is Linux only (x86_64 and aarch64): " .. trouble
    end
    return nil, "child: could not start the connector: " .. trouble
  end
  local ok, nonblocking = sys.set_nonblocking(pair[1], true)
  if not ok then
    local _, _ = sys.kill(pid, sys.SIGKILL)
    local _, _ = process_raw.waitpid(pid, false)
    local _, _ = sys.close(pair[1])
    return nil, "child: " .. nonblocking
  end
  local started: Process = setmetatable({ fd = pair[1], pid = pid, open = true }, process_mt)
  return started, ""
end

--- The stream of `self`'s process, started where it has none or lost
--- its last and the process is this one's to start: nil and why where
--- it cannot be.
local function channel_of_served(self: Served): Channel | nil, string
  local channel = self.channel
  if channel ~= nil and channel.lost == nil then return channel, "" end
  if self.inherited then return nil, "net: the connector has ended" end
  local started, why = Leaf.start(self.endpoints, self.timeout_ms, self.public)
  if started == nil then return nil, why end
  self.channel = channel_of(started)
  return self.channel, ""
end

--- Starts a connector of the table `endpoints` (and `public`'s lists, if
--- given) that waits `timeout_ms` to connect: the [`Net.Connector`] over
--- its process, or nil and why where the process cannot be started. The
--- caller has checked its arguments.
function Leaf.connector(endpoints: {raw_process.ConnectorEndpoint}, timeout_ms: integer,
                        public?: raw_process.ConnectorPublic): Connection.Connector | nil, string
  local connector: Served = setmetatable({
    timeout_ms = timeout_ms, open = true, public = public, accepts_public = public ~= nil, endpoints = endpoints,
  }, served_mt)
  local started, why = Leaf.start(endpoints, timeout_ms, public)
  if started == nil then return nil, why end
  connector.channel = channel_of(started)
  made[connector] = connector
  return connector, ""
end

--- A [`Net.Connector`] over the control stream `fd` of a process this one
--- did not start (it was inherited, its starter keeping the process): the
--- connector owns `fd`, made nonblocking, and `close` closes it and
--- signals and waits for nothing. `held` is the table the process was
--- started with, in order, which lets `connect` match endpoints as
--- [`Net.connector`]'s does; `public` says it was started in public mode,
--- so that it may be asked for an address the table lacks; `timeout_ns` is
--- its wait to connect (10 seconds by default), which a lookup through it
--- waits out for each reply. Neither is checked against the process, which
--- holds its own table and lists: a request it refuses is answered as its
--- refusal. The stream is the process's own from its start: what it says
--- first, which names its protocol, is read before the first request, and
--- a process of another program's protocol fails it ("net: the connector
--- speaks another protocol than this program's"). A process that ends, or
--- whose stream falls out of step, is not started again: the connector
--- answers "net: the connector has ended" from then on. An `fd` that is
--- no descriptor, a `held` that is not a list of at most 128 endpoints,
--- or a `timeout_ns` out of range raises; nil and why where the stream
--- cannot be made nonblocking, and `fd` is the caller's then.
function Leaf.adopted(fd: integer, held?: {raw_process.ConnectorEndpoint}, public?: boolean, timeout_ns?: integer):
    Connection.Connector | nil, string
  if math.type(fd) ~= "integer" or fd < 0 then error("net: fd must be a descriptor", 2) end
  local kept: {raw_process.ConnectorEndpoint} = {}
  if held ~= nil then kept = Leaf.checked_endpoints(held, true, 2) end
  local timeout_ms = Leaf.checked_timeout_ms(timeout_ns, 2)
  local ok, nonblocking = sys.set_nonblocking(fd, true)
  if not ok then return nil, "child: " .. nonblocking end
  local adopted: Process = setmetatable({ fd = fd, open = true }, process_mt)
  local connector: Served = setmetatable({
    timeout_ms = timeout_ms, open = true, endpoints = kept,
    channel = channel_of(adopted), inherited = true, accepts_public = public == true,
  }, served_mt)
  made[connector] = connector
  return connector, ""
end

--- The [`Served`] behind `connector`, or nil for one this module did not
--- make.
function Leaf.served(connector: Connection.Connector): Served | nil
  return made[connector]
end

function Served:find(host: string, port: integer): integer | nil
  for i, entry in ipairs(self.endpoints) do
    if same_host(entry.host, host) and endpoint_allows(entry, port) then return i end
  end
  return nil
end

function Served:connect(address: Connection.Address, opts?: Connection.ConnectOptions):
    Connection.Conn | nil, string
  local unusable = address_trouble(address)
  if unusable ~= "" then error("net: address must be " .. unusable, 2) end
  if address.kind ~= "tcp" then error("net: a connector connects tcp addresses", 2) end
  local conn_ns = opts ~= nil and opts.timeout_ns or nil
  if conn_ns ~= nil and (math.type(conn_ns) ~= "integer" or conn_ns < 0) then
    error("net: timeout_ns must be an integer from 0", 2)
  end
  if not self.open then return nil, "net: the connector is closed" end
  local target, port = address.host, address.port
  -- The process holds the ceiling too; this wait is the one it is asked for.
  local ceiling_ns = Clock.ms(self.timeout_ms)
  local wait_ns = math.min(conn_ns or ceiling_ns, ceiling_ns)
  local deadline = Clock.monotonic_ns() + wait_ns + CONNECTOR_GRACE_NS
  local host = target
  local body: string
  local refusal = ""
  local kind = ""
  local index = self:find(target, port)
  if index ~= nil then
    host = self.endpoints[index].host
    if self.accepts_public then kind = "table" end
  else
    if not self.accepts_public then
      return nil, "net: " .. target .. ":" .. port .. " is not in the connector's table"
    end
    local bytes = Relay.Address.parse(target)
    if bytes == nil then return nil, "net: " .. target .. " is not a numeric address" end
    if port < 1 or port > 65535 then return nil, "net: port must be from 1 to 65535" end
    -- The public index, 4294967295.
    body = request_body(0xffffffff, port, wait_ns, bytes)
    if #self.endpoints > 0 then kind = "public" end
    refusal = "net: " .. target .. " is refused by the connector's deny list"
  end
  body = body or request_body(index, port, wait_ns)
  local channel, why = channel_of_served(self)
  if channel == nil then return nil, why end
  local socket, asked = ask(channel, body, host, port, deadline, refusal, kind)
  if socket == nil then return nil, asked end
  return make_conn(socket, conn_ns), ""
end

function Served:through(index: integer, port: integer, deadline: integer | nil): raw_socket.Socket | nil, string
  local channel, why = channel_of_served(self)
  if channel == nil then return nil, why end
  -- The lookup gives each connect until its deadline; one given up on is
  -- still answered, its socket closed, so the stream stays in step.
  return ask(channel, own_wait_body(index, port), self.endpoints[index].host, port,
    deadline or Clock.monotonic_ns() + Clock.ms(self.timeout_ms) + CONNECTOR_GRACE_NS, "", "")
end

function Served:lost(): string | nil
  return self.channel ~= nil and self.channel.lost or nil
end

function Served:ended(): boolean
  if not self.open then return true end
  local channel = self.channel
  return self.inherited and (channel == nil or channel.lost ~= nil or not channel.process.open)
end

function Served:close(): boolean, string
  if not self.open then return true, "" end
  self.open = false
  if self.channel ~= nil then lose(self.channel, "net: the connector is closed") end
  return true, ""
end

--- The connects of a lookup through the connector whose control stream is
--- `fd`, nothing yet read from it and the stream the caller's to close:
--- each asks the connector for the table entry `index`, whose address is
--- `servers[index]`, and answers the connection or why not. The connector
--- gets until `deadline` (nil for `reply_ns` from the ask) and at least
--- `reply_ns`.
--- @param fd integer The connector's control stream
--- @param servers {raw_socket.ThroughServer} The table's entries, by index
--- @param reply_ns integer The least a connect is waited for, in nanoseconds
--- @return function The connect a lookup takes
function Leaf.connects(fd: integer, servers: {raw_socket.ThroughServer}, reply_ns: integer):
    function(index: integer, port: integer, deadline: integer | nil): Resolv.Connection | nil, string
  local borrowed: Process = setmetatable({ fd = fd, open = true, borrowed = true }, process_mt)
  local channel = channel_of(borrowed)
  return function(index: integer, port: integer, deadline: integer | nil): Resolv.Connection | nil, string
    local until_ns = Clock.monotonic_ns() + reply_ns
    if deadline ~= nil and deadline > until_ns then until_ns = deadline end
    local socket, why = ask(channel, own_wait_body(index, port), servers[index].host, port, until_ns, "", "")
    if socket == nil then return nil, why end
    return { fd = socket:fd(), release = function() local _, _ = socket:close() end }, ""
  end
end

return Leaf
