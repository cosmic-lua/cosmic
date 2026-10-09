--- Stream sockets listen, accept and connect, then read and write as a
--- [`cosmic.stream`] Reader and Writer. UDP sockets send and receive
--- complete datagrams with a numeric destination and sender address.
--- [`Net.resolve`] looks a host name up, as the system's resolver would,
--- and answers every address it has.
---
---     local server <close> = assert(Net.listen(Net.unix(dir .. "/app.sock")))
---     local conn <close> = assert(server:accept())
---     local lines = Stream.lines(conn) -- holds what it read past a line: see `rest`
---     local line = lines:read()
---
--- An address's `kind` selects its fields: "unix" takes a socket file's
--- path; "tcp" and "udp" take a numeric host and port. Stream calls take
--- "unix" and "tcp", while [`Net.datagram`] takes "udp".
---
---     local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
---     local port = server.address.port -- the one the kernel chose
---
--- A connection is one object for both directions; `shutdown("write")`
--- tells the peer the end of what was sent while its answer is still
--- read.
---
--- Every wait -- to connect, to accept, to read, to write -- lasts at
--- most the object's timeout (no limit by default; [`set_timeout`]
--- changes it), failing with [`Poll.TIMEOUT`], and ends with
--- "interrupted", within a tenth of a second, when the innermost open
--- [`Child.guard`] catches SIGINT or SIGTERM, as [`cosmic.http`]'s do.
---
--- In a task of [`Poll.run`] ([`cosmic.poll`]), a wait to connect, to
--- accept, to read or to write waits through the run, so its other
--- tasks go on meanwhile: a server serves each connection in a task of
--- its own. A cancelled task's wait there fails "cancelled", and a
--- signal does not end one. Anywhere else a wait holds the thread until
--- it ends.
---
--- [`Net.serve`] is that server, for any protocol: a function of a
--- connection, run for each one accepted at any of its listeners, whose
--- failure closes that connection alone.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local errors = require("cosmic.internal.errors")
local Relay = require("cosmic.relay")

--- The raw module behind this one lives under the reserved
--- `cosmic.internal.` namespace and arrives as the second argument
--- `require` passes this chunk's loader, as cosmic/http/init.tl's does.
local type raw_socket = require("cosmic.internal.socket")

local extra: any = select(2, ...)
local raw: raw_socket
if type(extra) == "table" then
  raw = extra as raw_socket
else
  raw = require("cosmic.internal.socket")
end

local record Net
  --- Where a socket is, as [`Net.unix`] and [`Net.tcp`] build one: a
  --- `kind` of "unix", with the socket file's `path`, or "tcp" or "udp", with
  --- a numeric `host` and a `port`. It is the raw socket module's own
  --- record; stream calls take "unix" and "tcp", datagrams "udp".
  type Address = raw_socket.Address

  record ListenOptions
    --- How long `accept` waits, in nanoseconds, from 0; nil for no
    --- limit. The connections it accepts start with the same.
    timeout_ns: integer
    --- How many connections may wait to be accepted (64 by default).
    --- A unix connection past it fails at once rather than waiting (see
    --- [`ConnectOptions.timeout_ns`]).
    backlog: integer
  end

  record ConnectOptions
    --- How long connecting, and then any one read or write, waits, in
    --- nanoseconds, from 0; nil for no limit. A TCP connection is
    --- waited on until made or refused. Connecting to a unix one waits
    --- for nothing: a listener whose backlog is full fails it at once,
    --- "Resource temporarily unavailable (the listener is busy: its
    --- backlog is full)" on Linux and "Connection refused" on macOS,
    --- which cannot tell a busy listener from none. A caller that would
    --- wait for room connects again.
    timeout_ns: integer
  end

  --- A socket listening at an address, answered by [`Net.listen`].
  interface Listener
    --- Where it listens.
    address: Address
    --- Sets how long `accept` waits by default, in nanoseconds, from 0;
    --- nil for no limit. A value no wait can last raises, naming
    --- `timeout_ns`, at the caller. The connections accepted after start
    --- with the same.
    set_timeout: function(Listener, timeout_ns: integer | nil)
    --- The next connection, waiting for one as long as `timeout_ns`
    --- (this call's, or the listener's); nil and [`Poll.TIMEOUT`],
    --- "interrupted", "cancelled" (in a task of [`Poll.run`]), or why not.
    accept: function(Listener, timeout_ns?: integer): Conn | nil, string
    --- Stops listening. A unix listener removes its socket file too,
    --- unless another file has taken the name since. Safe to call more
    --- than once.
    close: function(Listener): boolean, string
    metamethod __close: function(Listener)
  end

  --- A connection, answered by `accept` and [`Net.connect`]: a
  --- [`Stream.Reader`] of what the peer sends and a [`Stream.Writer`] to
  --- it.
  interface Conn is Stream.Reader, Stream.Writer
    --- Sets how long a `read` or a `write` waits, in nanoseconds, from 0;
    --- nil for no limit. A connection starts with the `timeout_ns` it
    --- was made with: [`Net.connect`]'s, or its listener's or server's.
    --- A value no wait can last raises, naming `timeout_ns`, at the
    --- caller.
    set_timeout: function(Conn, timeout_ns: integer | nil)
    --- What has arrived, at most `max_bytes` bytes (64 KiB by default), once
    --- something has; nil and "" once the peer has ended what it sends.
    --- nil and [`Poll.TIMEOUT`], "interrupted" or "cancelled" (in a task of
    --- [`Poll.run`]) takes nothing, and a later read may still answer; nil
    --- and any other failure is every read's after. A failed read leaves
    --- writing be. A `max_bytes` below 1 raises.
    read: function(Conn, max_bytes?: integer): string | nil, string
    --- Sends all of `data`, waiting as the peer takes it. False and
    --- [`Poll.TIMEOUT`], "interrupted", "cancelled" (in a task of [`Poll.run`])
    --- or why not may leave part of it sent,
    --- so it is every write's after; reading is left be.
    write: function(Conn, data: string): boolean, string
    --- Ends one direction, or both: after "write" the peer reads the
    --- end of what was sent, and this side can still read its answer.
    --- A `how` that is none of "read", "write" and "both" raises.
    shutdown: function(Conn, how: string): boolean, string
    --- Closes the connection. Safe to call more than once.
    close: function(Conn): boolean, string
    --- The same as `close`: nothing sent can be taken back.
    abort: function(Conn): boolean, string
    metamethod __close: function(Conn)
  end

  --- One numeric endpoint, a DNS server of [`ResolveOptions.servers`] or
  --- one a native connector may reach: a canonical
  --- IPv4 or IPv6 `host` (no name, no scope, no leading zeroes) and a
  --- `port`, 0 for any nonzero port at that host.
  record Endpoint
    --- The numeric address, no name.
    host: string
    --- The port. A DNS server's is 1 to 65535; only a connector's table
    --- takes 0, any nonzero port.
    port: integer
  end

  record ConnectorOptions
    --- The longest the connector process waits to make each connection,
    --- in nanoseconds, from 1 millisecond to 60 seconds (10 seconds by
    --- default). It is fixed when the process starts; a request's own
    --- `timeout_ns`, where shorter, bounds its connect instead (see
    --- [`Connector.connect`]).
    timeout_ns: integer
    --- Makes the connector public: it also connects to an address its
    --- table lacks, judged by the process itself against the lists given
    --- here (see [`Net.connector`]).
    public: PublicOptions
  end

  --- What a public connector refuses, as data its process holds: the
  --- native connector has no list of its own. `deny` is the refused
  --- prefixes as numeric "address/bits" text, at most 128
  --- ([`cosmic.relay`]'s `Address.deny_cidrs` lists the relay's), and `own`
  --- the host's own numeric addresses, at most 256, refused as their own.
  --- An IPv6 address outside 2000::/3 is refused besides, whatever is listed.
  type PublicOptions = Child.ConnectorPublic

  --- Connects to numeric addresses through the sandbox's native connector
  --- process, answered by [`Net.connector`]: a process confined to a
  --- fixed set of endpoints, which connects a socket and passes it back
  --- over a private stream. Tasks of a [`Poll.run`] share one: its
  --- process makes up to [`Net.CONNECTOR_FLIGHT`] connections at once,
  --- answering each as it is made, so a connect that hangs holds up no
  --- other. A connector with a table and public lists keeps 16 of those
  --- for each kind of request against the other (see
  --- [`Connector.connect`]), so a flood of one never keeps the other
  --- waiting.
  interface Connector
    --- Connects to `target` at `port` within `timeout_ns` nanoseconds: the
    --- connection, or nil and why ([`Poll.TIMEOUT`], "Connection
    --- refused", the connector's own refusal of an endpoint not in its
    --- table, ...). `target` is the numeric address as the table wrote
    --- it, or the table's 1-based index of an endpoint; `port` is that
    --- endpoint's, or any nonzero one where its port is 0. The process
    --- connects for at most `timeout_ns` (or its own wait, where shorter),
    --- and its answer is waited for a second more. A request past the
    --- [`Net.CONNECTOR_FLIGHT`] the process is making waits for one of them
    --- to end, within its `timeout_ns`; one given up on still counts until
    --- the process answers it. A connector whose process ended, or whose
    --- stream fell out of step, fails every request waiting on it, and is
    --- started again for the next, unless [`Net.connector_from`] adopted
    --- it. A `timeout_ns` that is no integer from 0 raises, and so does an
    --- address that is no numeric one where the connector has no table. A
    --- public connector (see [`Net.connector`]) also connects to a numeric
    --- `target` its table lacks, unless its process refuses the address
    --- ("net: ... is refused by the connector's deny list"); one with a
    --- table too holds 16 of its [`Net.CONNECTOR_FLIGHT`] back from each
    --- kind for the other, so that neither the table's requests nor the
    --- public ones wait behind the other's that hang: at most 48 of
    --- either are in flight at once.
    connect: function(Connector, target: integer | string, port: integer, timeout_ns: integer): Conn | nil, string
    --- The connector as the relay takes one, `address, port, timeout_ns`
    --- to a connection or nil and why: [`Connector.connect`] over a
    --- numeric address, and no more.
    as_function: function(Connector): function(address: string, port: integer, timeout_ns: integer): Conn | nil, string
    --- Whether the connector serves no request any more: it is closed, or
    --- its process, one [`Net.connector_from`] adopted, has ended or its
    --- stream fell out of step, so it cannot be started again.
    ended: function(Connector): boolean
    --- Ends the connector process and reaps it: the connections it made
    --- are theirs and stay open. Safe to call more than once; a connector
    --- dropped unclosed is ended when it is collected.
    close: function(Connector): boolean, string
    metamethod __close: function(Connector)
  end

  --- One complete UDP datagram and its sender's numeric address.
  type Packet = raw_socket.Packet

  record DatagramOptions
    --- How long any one send or receive waits, in nanoseconds, from 0;
    --- nil for no limit.
    timeout_ns: integer
  end

  --- A bound UDP socket, answered by [`Net.datagram`]. Empty datagrams
  --- are packets too, and each send and receive preserves its boundary.
  interface Datagram
    --- Where the socket is bound, including the port the kernel chose.
    address: Address
    --- Sets the wait limit, in nanoseconds, from 0; nil for no limit.
    set_timeout: function(Datagram, timeout_ns: integer | nil)
    --- Sends one complete packet to a numeric UDP address. A failure
    --- sends none and leaves later sends and receives available.
    send: function(Datagram, data: string, destination: Address): boolean, string
    --- Takes one complete packet, at most max_bytes (65535 by default).
    --- One larger is consumed and refused, never returned cut short.
    --- A timeout, cancellation or signal takes no packet. An allocation
    --- failure after receipt consumes that packet.
    receive: function(Datagram, max_bytes?: integer): Packet | nil, string
    --- Closes the socket. Safe to call more than once.
    close: function(Datagram): boolean, string
    metamethod __close: function(Datagram)
  end

  --- One address a name resolves to, answered by [`Net.resolve`]: its
  --- numeric form (four decimal octets for IPv4, `inet_ntop`'s for IPv6)
  --- and its `family`, "ipv4" or "ipv6".
  type Resolved = raw_socket.Resolved

  record ResolveOptions
    --- How long the lookup waits in all, in nanoseconds, from 0; nil for
    --- no limit beyond the resolver's own retries.
    timeout_ns: integer
    --- Name servers to ask in place of the system's: one or more
    --- numeric [`Net.Endpoint`]s, such as [`Net.nameservers`] lists.
    servers: {Endpoint}
    --- A hosts file to read in place of the system's.
    hosts_file: string
    --- Resolves over TCP alone, every socket of the lookup made by this
    --- connector, one [`Net.connector`] or [`Net.connector_from`] made with
    --- a table, and no datagram sent: the servers asked are `servers`, or
    --- the system's ([`Net.nameservers`]), each of which the
    --- connector's table must hold at its port. A connector built from
    --- those alone reaches nothing else, so the lookup's
    --- sockets reach nothing but the name servers. The lookup asks
    --- one connection at a time, sharing the connector's stream with
    --- any other request, each in its place by tag. Linux only, as the
    --- connector is.
    connector: Connector
  end

  --- The most connections one [`Net.Connector`]'s process makes at once
  --- (64).
  CONNECTOR_FLIGHT: integer


  --- What [`Net.serve`] serves, and how. A field of the wrong shape, or
  --- one not named here, raises, naming it.
  record ServeSpec
    --- Where to listen, one address or more: each is listened at, and
    --- each listener closed, by the server, which so owns every socket
    --- file it makes and removes it on stopping.
    listeners: {Address}
    --- The protocol: run once for each connection accepted, in a task of
    --- its own, which closes the connection once it returns or raises.
    --- What it raises goes to [`Net.ServeSpec.on_error`], and the server goes
    --- on.
    serve: function(conn: Conn)
    --- What a server takes on at most.
    record Limits
      --- The most connections open at once, from 1; nil for no limit.
      --- At the limit no listener accepts: a connection that comes waits
      --- in its listener's backlog until one open closes, and a unix one
      --- past the backlog fails at once (see
      --- [`ConnectOptions.timeout_ns`]).
      connections: integer
    end
    --- Bounds on what the server takes on; nil for none.
    limits: Limits
    --- Each connection's `timeout_ns`: how long any one read or write of
    --- it waits, from 0; nil for no limit.
    timeout_ns: integer
    --- On stopping, how long open connections have to finish, from 0,
    --- before they are closed and their tasks killed
    --- ([`Poll.Task.kill`]); nil to wait for every one.
    grace_ns: integer
    --- Called once every listener listens, in a task of the server's
    --- run, with where each listens -- a port the kernel chose for one
    --- at port 0 included -- in the order of `listeners`, and the
    --- server, to stop it by. It may spawn tasks of its own there, which
    --- [`Net.serve`] waits for too. What it raises, [`Net.serve`] raises,
    --- having closed every listener.
    on_ready: function(addresses: {Address}, server: Server)
    --- Called once, as the server begins to stop -- at [`Server.stop`],
    --- or at a SIGINT or SIGTERM its guard caught -- in a task of the
    --- server's run, with the server, once every listener is closed;
    --- never where the server fails or raises before it stops. It is
    --- where a protocol ends what need not finish, closing the idle
    --- connections it tracks, so a client holding one idle does not
    --- hold the drain for all of `grace_ns`, or for ever where it is
    --- nil. It is to close, not to wait: the drain, and `grace_ns`,
    --- begin once it returns, and a wait it makes holds them. A second
    --- signal cancels its wait ([`Poll.Task.cancel`]) as it ends the
    --- grace, though not the wait of a task it spawned, which
    --- [`Net.serve`] waits for too. What it raises goes to
    --- [`Net.ServeSpec.on_error`], with its stack, and the server stops all
    --- the same.
    on_stop: function(server: Server)
    --- Given what the protocol raised for a connection, with its stack,
    --- or why a listener failed to accept; nil to write each to stderr.
    --- What it raises, [`Net.serve`] raises, having closed every listener
    --- and connection, as an error in [`Poll.run`] ends it.
    on_error: function(trouble: string)
  end

  --- A server [`Net.serve`] runs, handed to its [`Net.ServeSpec.on_ready`]
  --- and [`Net.ServeSpec.on_stop`].
  record Server
    --- Where each listener listens, as [`Net.ServeSpec.on_ready`] was given.
    addresses: {Address}
    --- Stops the server, from any task of its run: every listener is
    --- closed at once, [`Net.ServeSpec.on_stop`] is called in a task of its
    --- own, and [`Net.serve`] returns once every task of its run has
    --- ended, the connections still open after `grace_ns` closed and
    --- their tasks killed. Stopping a server that is stopping does
    --- nothing.
    stop: function(Server)
  end
end

local DEFAULT_READ <const> = 64 * 1024
local DEFAULT_BACKLOG <const> = 64

--- The address of the socket file at `path`.
function Net.unix(path: string): Net.Address
  return { kind = "unix", path = path }
end

--- The address of TCP `port` at `host`, a numeric IPv4 or IPv6 address.
function Net.tcp(host: string, port: integer): Net.Address
  return { kind = "tcp", host = host, port = port }
end

--- A numeric destination or binding for a datagram socket. UDP never
--- resolves `host`: pass an IPv4 or IPv6 literal and a `port` from 0 to
--- 65535; 0 binds a port chosen by the kernel.
function Net.udp(host: string, port: integer): Net.Address
  return { kind = "udp", host = host, port = port }
end

--- What a failed call says: its own words for a deadline or a signal,
--- the bound a name too long ran past, what a host must be, and why a
--- unix listener answered EAGAIN, which errno's words leave unsaid.
local function said(trouble: string, errno: integer, address?: Net.Address): string
  if errno == raw.ETIMEDOUT then return Poll.TIMEOUT end
  if errno == raw.EINTR then return "interrupted" end
  if errno == raw.ENAMETOOLONG then
    return trouble .. " (a socket file's own name may be at most " ..
      raw.SOCKET_NAME_MAX .. " bytes here)"
  end
  if errno == raw.EAGAIN and address ~= nil and address.kind == "unix" then
    return trouble .. " (the listener is busy: its backlog is full)"
  end
  if errno == raw.EINVAL and address ~= nil and address.kind ~= "unix" then
    return trouble .. " (not a numeric IPv4 or IPv6 address: a name is not looked up, " ..
      "nor an IPv6 scope read)"
  end
  return trouble
end

--- Waits for `fd` to be readable, or writable, at most `timeout_ns`, which
--- the caller has held to what a wait can last: in a
--- task of a run, through it; anywhere else, in the raw wait, which
--- also ends at a signal the innermost [`Child.guard`] caught.
local function waited(fd: integer, writable: boolean, timeout_ns: integer | nil): boolean, string
  -- TODO: wait through Poll.wait alone, and in `connection` too, once
  -- cosmic.poll has what the raw wait outside a task has: a core binding
  -- that gives it the core's cosmic_signal_caught (only core/socket.c's
  -- waits and sys.flock read it today), a fourth shared answer word for
  -- a wait a signal interrupted, and a loop in Poll.wait outside a task
  -- that polls in slices to look for one. A Conn's read and write are
  -- then Stream.from_fd and Stream.to_fd (see the TODO at [`SocketConn:read`]).
  if Poll.in_task() then
    return Poll.wait(fd, writable and sys.POLLOUT or sys.POLLIN, timeout_ns)
  end
  local ok, trouble, errno = raw.wait(fd, writable, Poll.milliseconds(timeout_ns))
  if ok then return true, "" end
  return false, said(trouble, errno)
end

-- How a connection or a listener is made. Each is a record of its own
-- ([`SocketConn`], [`SocketListener`]) implementing the public interface it
-- answers, so one costs one table and no closure: its methods are defined
-- once, on the record, which an object reaches through `__index`, and its
-- state is in fields. The note on how an object is made in
-- cosmic/stream.tl says why Teal makes the public types interfaces. One
-- dropped unclosed needs no __gc: its socket, which only the object
-- holds, is closed by the collector.

local record SocketConn is Net.Conn
  socket: raw_socket.Socket
  fd: integer
  open: boolean
  -- Set by [`set_timeout`], and read by each wait, so a change reaches a
  -- wait the next read or write starts.
  limit: integer
  -- Each direction's sticky failure, "" until one: once a read or a
  -- write fails for good, every later one of it says so.
  read_failure: string
  write_failure: string
  set_timeout: function(SocketConn, wait_ns: integer | nil)
  read: function(SocketConn, max_bytes?: integer): string | nil, string
  write: function(SocketConn, data: string): boolean, string
  shutdown: function(SocketConn, how: string): boolean, string
  close: function(SocketConn): boolean, string
  abort: function(SocketConn): boolean, string
end

local socket_conn_mt: metatable<SocketConn> = {
  __index = SocketConn,
  __close = function(self: SocketConn)
    local _, _ = self:close()
  end,
}

function SocketConn:set_timeout(wait_ns: integer | nil)
  Poll.checked_ns(wait_ns, "net", "timeout_ns", 2)
  self.limit = wait_ns
end

-- TODO: make a Conn's `read` and `write` the Reader and Writer
-- Stream.from_fd and Stream.to_fd answer over the socket
-- ({ nonblocking = true, timeout_ns }), collapsing the write loop here into
-- theirs, once the TODO in `waited` is done: a wait outside a task here
-- ends at a signal a Child.guard caught ("interrupted", which net_test's
-- cases hold), which Poll.wait cannot see. Their `wait` option could
-- carry `waited`, but `write` also sends through raw.send, which never
-- raises SIGPIPE where sys.write may, and reads the timeout [`set_timeout`]
-- changes on every call, which an option fixes when the object is made.
function SocketConn:read(max_bytes?: integer): string | nil, string
  if max_bytes ~= nil and max_bytes <= 0 then error("net: read's max_bytes must be positive", 2) end
  if not self.open then return nil, "net: the connection is closed" end
  if self.read_failure ~= "" then return nil, self.read_failure end
  local fd = self.fd
  while true do
    local data, why, errno = sys.read(fd, max_bytes or DEFAULT_READ)
    if data == "" then return nil, "" end
    if data ~= nil then return data, "" end
    if errno ~= raw.EAGAIN then
      self.read_failure = why
      return nil, why
    end
    -- Nothing was taken: a deadline or a signal leaves the next
    -- read to try again.
    local ready, waiting = waited(fd, false, self.limit)
    if not ready then return nil, waiting end
    -- Another task may have closed the connection while this one
    -- waited in a run, and its descriptor gone to another socket.
    if not self.open then return nil, "net: the connection is closed" end
  end
end

function SocketConn:write(data: string): boolean, string
  if not self.open then return false, "net: the connection is closed" end
  if self.write_failure ~= "" then return false, self.write_failure end
  local fd = self.fd
  local from = 1
  while from <= #data do
    local sent, why, errno = raw.send(fd, data, from)
    if sent ~= nil then
      from = from + sent
    elseif errno ~= raw.EAGAIN then
      self.write_failure = why
      return false, why
    else
      local ready, waiting = waited(fd, true, self.limit)
      if not ready then
        self.write_failure = waiting
        return false, waiting
      end
      if not self.open then return false, "net: the connection is closed" end
    end
  end
  return true, ""
end

function SocketConn:shutdown(how: string): boolean, string
  if how ~= "read" and how ~= "write" and how ~= "both" then
    error("net: how must be \"read\", \"write\" or \"both\"", 2)
  end
  if not self.open then return false, "net: the connection is closed" end
  local ok, why = raw.shutdown(self.fd, how)
  if not ok then return false, why end
  return true, ""
end

function SocketConn:close(): boolean, string
  if not self.open then return true, "" end
  self.open = false
  Poll.closing(self.fd)
  local ok, why = self.socket:close()
  if not ok then return false, why end
  return true, ""
end

function SocketConn:abort(): boolean, string
  return self:close()
end

--- The connection over `socket`.
local function new_conn(socket: raw_socket.Socket, timeout_ns: integer | nil): SocketConn
  local conn: SocketConn = setmetatable({
    socket = socket, fd = socket:fd(), open = true, limit = timeout_ns,
    read_failure = "", write_failure = "" }, socket_conn_mt)
  return conn
end

--- What `address` is called in a failure: its path, or its host and
--- port, an IPv6 host in brackets.
local function named(address: Net.Address): string
  if address.kind ~= "tcp" then return address.path end
  local host = address.host
  if host:find(":", 1, true) then host = "[" .. host .. "]" end
  return host .. ":" .. tostring(address.port)
end

--- A listener and its descriptor, which [`Net.serve`] waits on itself
--- so as to take a connection only while under its limit.
local record Opened
  listener: Net.Listener
  fd: integer
end

local record SocketListener is Net.Listener
  socket: raw_socket.Socket
  fd: integer
  open: boolean
  -- Set by [`set_timeout`], and given to each connection accepted after.
  limit: integer
  set_timeout: function(SocketListener, wait_ns: integer | nil)
  accept: function(SocketListener, wait_ns?: integer): Net.Conn | nil, string
  close: function(SocketListener): boolean, string
end

local socket_listener_mt: metatable<SocketListener> = {
  __index = SocketListener,
  __close = function(self: SocketListener)
    local _, _ = self:close()
  end,
}

function SocketListener:set_timeout(wait_ns: integer | nil)
  Poll.checked_ns(wait_ns, "net", "timeout_ns", 2)
  self.limit = wait_ns
end

function SocketListener:accept(wait_ns?: integer): Net.Conn | nil, string
  Poll.checked_ns(wait_ns, "net", "timeout_ns", 2)
  if not self.open then return nil, "net: the listener is closed" end
  wait_ns = wait_ns or self.limit
  local fd = self.fd
  while true do
    local connection, why, errno = raw.accept(fd)
    if connection ~= nil then return new_conn(connection, self.limit), "" end
    if errno ~= raw.EAGAIN then return nil, why end
    local ready, waiting = waited(fd, false, wait_ns)
    if not ready then return nil, waiting end
    if not self.open then return nil, "net: the listener is closed" end
  end
end

function SocketListener:close(): boolean, string
  if not self.open then return true, "" end
  self.open = false
  Poll.closing(self.fd)
  local ok, why = self.socket:close()
  if not ok then return false, named(self.address) .. ": " .. why end
  return true, ""
end

--- The listener over `socket`, at `address`.
local function new_listener(socket: raw_socket.Socket, address: Net.Address,
                            timeout_ns: integer | nil): Opened
  local fd = socket:fd()
  local listener: SocketListener = setmetatable({
    address = address, socket = socket, fd = fd, open = true, limit = timeout_ns },
    socket_listener_mt)
  return { listener = listener, fd = fd }
end

--- What [`connection`] made: the socket, or, where there is none, what
--- went wrong and its errno, which `said` words. `errno` is 0 for a
--- wait's own [`Poll.TIMEOUT`] or "cancelled" in a task.
local record Attempt
  socket: raw_socket.Socket
  trouble: string
  errno: integer
end

--- A socket being connected in a task, closed when the task leaves it
--- unclaimed -- a run torn down while it waits included -- rather than
--- left to the collector.
local record Connecting
  socket: raw_socket.Socket
  metamethod __close: function(Connecting)
end

local connecting_mt: metatable<Connecting> = {
  __close = function(self: Connecting)
    if self.socket ~= nil then local _, _ = self.socket:close() end
  end,
}

--- Why `address` is no [`Net.Address`] a listener can take, or "".
local function address_trouble(address: any): string
  if not address is {any: any} then return "an address, from Net.unix or Net.tcp" end
  local kind, path, host, port = address.kind, address.path, address.host, address.port
  if kind == "unix" then
    if path is string and path ~= "" then return "" end
    return "a unix address whose path is a string of at least one byte"
  end
  if kind == "tcp" then
    if host is string and port is integer and port >= 0 and port <= 65535 then return "" end
    return "a tcp address whose host is a string and port an integer from 0 to 65535"
  end
  return "an address, from Net.unix or Net.tcp"
end

--- Holds a datagram address to the numeric host and port contract.
local function checked_datagram_address(address: any, level: integer)
  if address is {any: any} then
    local kind, host, port = address.kind, address.host, address.port
    if kind == "udp" and host is string and port is integer and port >= 0 and port <= 65535 then
      return
    end
  end
  error("net: address must be a udp address from Net.udp", level + 1)
end

local record SocketDatagram is Net.Datagram
  socket: raw_socket.Socket
  fd: integer
  open: boolean
  limit: integer
  set_timeout: function(SocketDatagram, timeout_ns: integer | nil)
  send: function(SocketDatagram, data: string, destination: Net.Address): boolean, string
  receive: function(SocketDatagram, max_bytes?: integer): Net.Packet | nil, string
  close: function(SocketDatagram): boolean, string
end

local socket_datagram_mt: metatable<SocketDatagram> = {
  __index = SocketDatagram,
  __close = function(self: SocketDatagram)
    local _, _ = self:close()
  end,
}

function SocketDatagram:set_timeout(timeout_ns: integer | nil)
  Poll.checked_ns(timeout_ns, "net", "timeout_ns", 2)
  self.limit = timeout_ns
end

function SocketDatagram:send(data: string, destination: Net.Address): boolean, string
  checked_datagram_address(destination, 2)
  if #data > 65535 then error("net: datagram must be at most 65535 bytes", 2) end
  if not self.open then return false, "net: the datagram socket is closed" end
  while true do
    local ok, why, errno = raw.sendto(self.fd, data, destination)
    if ok then return true, "" end
    if errno ~= raw.EAGAIN then return false, said(why, errno, destination) end
    local ready, waiting = waited(self.fd, true, self.limit)
    if not ready then return false, waiting end
    if not self.open then return false, "net: the datagram socket is closed" end
  end
end

function SocketDatagram:receive(max_bytes?: integer): Net.Packet | nil, string
  max_bytes = max_bytes or 65535
  if max_bytes < 1 or max_bytes > 65535 then error("net: max_bytes must be from 1 to 65535", 2) end
  if not self.open then return nil, "net: the datagram socket is closed" end
  while true do
    local packet, why, errno = raw.recvfrom(self.fd, max_bytes)
    if packet ~= nil then return packet, "" end
    if errno ~= raw.EAGAIN then return nil, why end
    local ready, waiting = waited(self.fd, false, self.limit)
    if not ready then return nil, waiting end
    if not self.open then return nil, "net: the datagram socket is closed" end
  end
end

function SocketDatagram:close(): boolean, string
  if not self.open then return true, "" end
  self.open = false
  Poll.closing(self.fd)
  local ok, why = self.socket:close()
  if not ok then return false, why end
  return true, ""
end

--- Binds a UDP socket at a numeric address. Port 0 lets the kernel
--- choose its port, which the socket's `address` then holds. A name is
--- never resolved, and a taken port is refused rather than shared.
function Net.datagram(address: Net.Address, opts?: Net.DatagramOptions): Net.Datagram | nil, string
  checked_datagram_address(address, 2)
  opts = opts or {}
  Poll.checked_ns(opts.timeout_ns, "net", "timeout_ns", 2)
  local socket, why, errno = raw.datagram(address)
  if socket == nil then return nil, said(why, errno, address) end
  local bound, trouble = raw.bound(socket:fd())
  if bound == nil then
    local _, _ = socket:close()
    return nil, trouble
  end
  local datagram: SocketDatagram = setmetatable({
    socket = socket, fd = socket:fd(), open = true, address = bound, limit = opts.timeout_ns,
  }, socket_datagram_mt)
  return datagram, ""
end

--- [`Net.resolve`] through `opts.connector`, defined with the connector.
local resolved_through: function(name: string, opts: Net.ResolveOptions): {Net.Resolved} | nil, string

--- Resolves `name` with c-ares and answers every address it has, IPv4
--- and IPv6, as the system's configuration (resolv.conf and hosts; on
--- macOS also the system's DNS configuration) makes it: none is dropped
--- or filtered, so a caller that refuses some address can refuse the
--- name. The answer is every address received: where one family fails
--- and the other answers, nothing says so, so a caller that checks
--- addresses connects only to those returned and never looks the name up
--- again. A numeric IPv4 or IPv6 address, as [`Net.tcp`] takes one, answers
--- itself without a query. `HOSTALIASES` is ignored. Where one family's
--- lookup fails and the other's answers, the answer holds the one that
--- did. A name with fewer dots than resolv.conf's ndots may be tried
--- under its `search` domains first, so a single-label name may resolve
--- under one. `servers` and `hosts_file` are for tests and trusted
--- callers, never for values a sandboxed program chose. With
--- `connector`, the lookup goes over TCP alone, each connection made by
--- the connector ([`ResolveOptions.connector`]), and each server is tried
--- once: a server that does not answer its connect costs the connector's
--- `timeout_ns` and the next server is asked, so a connector for lookups
--- waits well under the lookup's time for each. Once `timeout_ns` here
--- has passed the call ends, whatever the connector has yet to answer. A server its
--- table lacks fails the call before anything is asked; a lookup no
--- server answered for want of time fails [`Poll.TIMEOUT`], and one
--- every server was refused a connection for fails "Connection refused".
---
---     local found = assert(Net.resolve("localhost", { timeout_ns = Clock.seconds(5) }))
---     for _, resolved in ipairs(found) do print(resolved.address, resolved.family) end
---
--- Fails with "name not found" (no such name), "name has no address",
--- "name server failed" (an error or malformed answer),
--- [`Poll.TIMEOUT`], "interrupted" (an open [`Child.guard`] caught a
--- signal), or the system's words ("Connection refused" where every
--- server refuses). A `name` that is empty, over 254 bytes or holds a
--- NUL or a "%", and a `servers` list or `hosts_file` the resolver
--- refuses, fail "Invalid argument". In a task of [`Poll.run`] the call
--- waits through the run, so only that task waits for the answer, and a
--- task cancelled in it ends the lookup and fails "cancelled"; anywhere
--- else it holds the thread until it answers. A `name` that is no string
--- or an option of the wrong shape raises.
function Net.resolve(name: string, opts?: Net.ResolveOptions): {Net.Resolved} | nil, string
  if not (name is string) then error("net: name must be a string", 2) end
  opts = opts or {}
  if type(opts) ~= "table" then error("net: options must be a table", 2) end
  Poll.checked_ns(opts.timeout_ns, "net", "timeout_ns", 2)
  local hosts_file = opts.hosts_file
  if hosts_file ~= nil and not (hosts_file is string) then
    error("net: hosts_file must be a string", 2)
  end
  local servers: string
  if opts.servers ~= nil then
    local listed = opts.servers
    if type(listed) ~= "table" or #listed == 0 then
      error("net: servers must be a list of endpoints", 2)
    end
    local parts: {string} = {}
    for _, endpoint in ipairs(listed) do
      if type(endpoint) ~= "table" then error("net: a server must be an endpoint", 2) end
      local host, port = endpoint.host, endpoint.port
      if not (host is string and port is integer and port >= 1 and port <= 65535) then
        error("net: a server must be an endpoint with a string host and an integer port from 1 to 65535", 2)
      end
      -- Only a host that holds none of the list's own punctuation may
      -- reach it, so one server cannot name another; the resolver
      -- refuses what is not an address.
      if host:find("[^%x:.]") then return nil, "Invalid argument" end
      parts[#parts + 1] = host:find(":", 1, true) and ("[" .. host .. "]:" .. port) or
        (host .. ":" .. port)
    end
    servers = table.concat(parts, ",")
  end
  if opts.connector ~= nil then return resolved_through(name, opts) end
  return Relay.lookup(name, { timeout_ns = opts.timeout_ns, servers = servers, hosts = hosts_file })
end

--- The system's DNS servers, each at port 53, as [`ResolveOptions.servers`]
--- takes them and a connector's table holds them: as the system's resolver
--- configuration gives them (resolv.conf on Linux, the system's DNS
--- configuration on macOS). Where none is configured the resolver's
--- default, 127.0.0.1, stands. A server written with an interface
--- (`fe80::1%eth0`) is left out; the call fails where every server is.
---
---     local servers = assert(Net.nameservers())
---     local found = assert(Net.resolve("localhost", { servers = servers }))
---
--- @return {Net.Endpoint}|nil The servers
--- @return string Why there are none, "" otherwise
function Net.nameservers(): {Net.Endpoint} | nil, string
  local listed, why = Relay.nameservers()
  if listed == nil then return nil, why end
  local out: {Net.Endpoint} = {}
  for i, server in ipairs(listed) do out[i] = { host = server.host, port = server.port } end
  return out, ""
end

--- A socket connected to `address`, waiting at most `timeout_ns`: in a
--- task of [`Poll.run`], through the run; anywhere else, holding the
--- thread.
local function connection(address: Net.Address, timeout_ns: integer | nil): Attempt
  -- TODO: connect through raw.start, Poll.wait and raw.connected alone
  -- outside a task too, as `waited`'s TODO says: raw.connect, which
  -- waits in the core and ends at a caught signal, is what that
  -- replaces.
  Poll.checked_ns(timeout_ns, "net", "timeout_ns", 3)
  if not Poll.in_task() then
    local socket, trouble, errno = raw.connect(address, Poll.milliseconds(timeout_ns))
    return { socket = socket, trouble = trouble, errno = errno }
  end
  local socket, trouble, errno = raw.start(address)
  if socket == nil then return { trouble = trouble, errno = errno } end
  local holder: Connecting = { socket = socket }
  local held <close> = setmetatable(holder, connecting_mt)
  local ready, why = Poll.writable(socket:fd(), timeout_ns)
  if not ready then return { trouble = why, errno = 0 } end
  local made, refused, number = raw.connected(socket:fd())
  if not made then return { trouble = refused, errno = number } end
  held.socket = nil
  return { socket = socket }
end

--- Whether `opts` sets `reclaim`, which no listen takes any more: a typed
--- table cannot say so, but a program written for it can.
local function sets_reclaim(opts: any): boolean
  return opts is {string: any} and opts.reclaim ~= nil
end

--- What [`Net.listen`] opens, with its descriptor; it raises at `level`
--- above its caller.
local function listening(address: Net.Address, opts: Net.ListenOptions,
                         level: integer): Opened | nil, string
  if sets_reclaim(opts) then
    error("net: ListenOptions.reclaim is gone: remove the socket file a listener left " ..
        "behind (Fs.remove) once connecting to it is refused, then listen", level + 1)
  end
  local unusable = address_trouble(address)
  if unusable ~= "" then error("net: address must be " .. unusable, level + 1) end
  local backlog = opts.backlog or DEFAULT_BACKLOG
  if backlog < 1 then error("net: backlog must be at least 1", level + 1) end
  Poll.checked_ns(opts.timeout_ns, "net", "timeout_ns", level + 1)
  local socket, trouble, errno = raw.listen(address, backlog)
  if socket == nil then return nil, named(address) .. ": " .. said(trouble, errno, address) end
  if address.kind ~= "tcp" then
    return new_listener(socket, Net.unix(address.path), opts.timeout_ns), ""
  end
  local bound, why = raw.bound(socket:fd())
  if bound == nil then
    local _, _ = socket:close()
    return nil, named(address) .. ": " .. why
  end
  return new_listener(socket, Net.tcp(bound.host, bound.port), opts.timeout_ns), ""
end

--- Listens at `address`. A unix one makes its socket file, and fails
--- where the path is already there -- a socket file left behind by a
--- listener that did not close included -- rather than take the name
--- from whatever holds it. A TCP one fails "Address in use" at a port
--- another listens at; its `address` names the port it has.
--- A unix path too long to bind whole is bound from its directory,
--- and raises where the process cannot return to its working directory
--- after. An `address` that is no [`Net.Address`] (a unix one with an
--- empty path, a TCP port past 65535) raises, as does a `backlog` below 1.
function Net.listen(address: Net.Address, opts?: Net.ListenOptions): Net.Listener | nil, string
  local opened, why = listening(address, opts or {}, 2)
  if opened == nil then return nil, why end
  return opened.listener, ""
end

--- The listener over a listening TCP socket this process already holds:
--- one it inherited, or one received over a Unix socket with
--- `sendfds`/`recvfds`. It takes a copy of `fd`, so closing the listener
--- never closes `fd`, which stays its holder's to close, and the
--- listener then behaves as one [`Net.listen`] answered: its `address` is
--- the socket's own, and `accept`, [`set_timeout`] and `close` are the same.
--- The copy shares `fd`'s open file description, so adopting makes `fd`
--- nonblocking, as every listener here is, for whoever else holds it.
--- Anything but a listening stream socket of IPv4 or IPv6 -- a file, a
--- pipe, a datagram or unconnected socket, a unix listener -- fails nil
--- and why, naming `fd`. A descriptor the runtime retains raises, as it does
--- anywhere; so does an `fd` that is no integer from 0, or a
--- `timeout_ns` no wait can last.
-- TODO: take a unix listener too, once a use needs one: its Net.Address
-- would come from raw.bound, but the adopted Socket would not own the
-- socket file, which removing is the binder's.
function Net.listener_from(fd: integer, opts?: Net.ListenOptions): Net.Listener | nil, string
  if math.type(fd) ~= "integer" or fd < 0 then
    error("net: fd must be an integer from 0", 2)
  end
  Poll.checked_ns(opts ~= nil and opts.timeout_ns or nil, "net", "timeout_ns", 2)
  local socket, why, errno = raw.adopt(fd)
  if socket == nil then
    local reason = why
    if errno == raw.EINVAL then reason = "it is not listening" end
    return nil, "net: descriptor " .. fd .. " is no listening TCP socket: " .. reason
  end
  local bound, trouble = raw.bound(socket:fd())
  if bound == nil then
    local _, _ = socket:close()
    return nil, "net: descriptor " .. fd .. ": " .. trouble
  end
  return new_listener(socket, Net.tcp(bound.host, bound.port),
    opts ~= nil and opts.timeout_ns or nil).listener, ""
end

--- The two listeners a sandbox's relay channel carries: the TCP sockets a
--- child bound in a network namespace of its own and sent over `channel`,
--- a descriptor this process holds, in the order they were sent. Each is
--- adopted as [`Net.listener_from`] does, and the descriptors received
--- are closed. A channel that carries no such pair, or sockets that are no
--- listening TCP, fails nil and why; `channel` is left open for its holder
--- to close. The child sends both in one message before it runs its
--- program, so a channel whose start has answered holds them already and
--- this does not wait; a `timeout_ns` no wait can last raises.
-- TODO: receive the pair in the process that started the child, and hand
-- the relay's process the listeners as descriptors of their own, once
-- cosmic.child can reach the raw socket table (core/store.c's `raw_modules`
-- gives each wrapper module one): until then the relay's process receives
-- them itself, so that Child only moves the channel.
--- @param channel integer The descriptor of the channel's receiving end
--- @param opts? Net.ListenOptions The listeners' options
--- @return {Net.Listener}|nil The listeners
--- @return string Why there are none, "" otherwise
function Net.receive_listeners(channel: integer, opts?: Net.ListenOptions): {Net.Listener} | nil, string
  if math.type(channel) ~= "integer" or channel < 0 then
    error("net: channel must be an integer from 0", 2)
  end
  Poll.checked_ns(opts ~= nil and opts.timeout_ns or nil, "net", "timeout_ns", 2)
  local received, why = raw.recvfds(channel, 2)
  if received == nil then return nil, "net: descriptor " .. channel .. ": " .. why end
  local listeners: {Net.Listener} = {}
  local failure = ""
  for _, owned in ipairs(received) do
    if failure == "" then
      local listener, trouble = Net.listener_from(owned:fd(), opts)
      if listener == nil then
        failure = trouble
      else
        listeners[#listeners + 1] = listener
      end
    end
    local _, _ = owned:close()
  end
  if failure ~= "" then
    for _, listener in ipairs(listeners) do local _, _ = listener:close() end
    return nil, failure
  end
  return listeners, ""
end

--- Connects to `address`. A unix one fails "No such file or directory"
--- where there is no socket file and "Connection refused" where nothing
--- listens at it, and fails at once at a listener whose backlog is
--- full (see [`ConnectOptions.timeout_ns`]). A TCP one waits
--- for the connection to be made, and fails "Connection refused" where
--- nothing listens at the port.
--- A unix path too long to connect to whole is connected to from its
--- directory, and raises where the process cannot return to its working
--- directory after. An `address` that is no [`Net.Address`] raises.
function Net.connect(address: Net.Address, opts?: Net.ConnectOptions): Net.Conn | nil, string
  local unusable = address_trouble(address)
  if unusable ~= "" then error("net: address must be " .. unusable, 2) end
  local timeout_ns = opts ~= nil and opts.timeout_ns or nil
  local attempt = connection(address, timeout_ns)
  if attempt.socket == nil then
    return nil, named(address) .. ": " .. said(attempt.trouble, attempt.errno, address)
  end
  return new_conn(attempt.socket, timeout_ns), ""
end

local CONNECTOR_DEFAULT_NS <const> = Clock.seconds(10)
local CONNECTOR_GRACE_NS <const> = Clock.seconds(1)
--- The flights a connector with a table and public lists keeps for each
--- kind of request against the other: a connect may hang for the process's
--- whole wait, and one given up on counts until answered, so neither kind
--- may fill the process and keep the other waiting.
local TABLE_RESERVE <const> = 16
local CONNECTOR_MAX_ENDPOINTS <const> = 128

Net.CONNECTOR_FLIGHT = raw.CONNECTOR_FLIGHT

--- A request sent on a connector's stream whose reply has not been
--- taken: what it asked for, so its socket is checked, and, once
--- answered, the connection or why not. One its caller gave up on is
--- still answered, its socket closed, so the stream stays in step.
local record Pending
  host: string
  port: integer
  timeout_ns: integer
  -- What a refusal by the connector's lists says.
  refusal: string
  given_up: boolean
  done: boolean
  conn: SocketConn
  why: string
  -- Whether its caller took `conn`: one answered but left behind is closed.
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
  process: Child.ConnectorProcess
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

local record SocketConnector is Net.Connector
  -- The endpoints the process is confined to, in order; nil where each
  -- connection starts a process of its own for the one endpoint it asks.
  endpoints: {Net.Endpoint}
  -- The connector's wait to connect, in milliseconds.
  timeout_ms: integer
  -- What a public process refuses, kept to start it again; nil for a
  -- connector whose process is not public.
  public: Net.PublicOptions
  -- Whether the process serves an inherited stream: a connector made by
  -- [`Net.connector_from`] is never started again.
  inherited: boolean
  -- Whether its process takes public requests.
  accepts_public: boolean
  -- The stream of the process serving a table, nil before its first
  -- start; one lost is replaced at the next request where the process is
  -- this one's to start.
  channel: Channel
  open: boolean
  connect: function(SocketConnector, target: integer | string, port: integer, timeout_ns: integer): Net.Conn | nil, string
  as_function: function(SocketConnector): function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
  ended: function(SocketConnector): boolean
  close: function(SocketConnector): boolean, string
end

local socket_connector_mt: metatable<SocketConnector> = {
  __index = SocketConnector,
  __close = function(self: SocketConnector)
    local _, _ = self:close()
  end,
}

local function channel_of(process: Child.ConnectorProcess): Channel
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

--- Answers `pending`, the request of `tag`, with `conn` or why not; one
--- given up on has its connection closed.
local function answer(channel: Channel, tag: integer, pending: Pending, conn: SocketConn, why: string)
  channel.pending[tag] = nil
  channel.count = channel.count - 1
  if pending.kind == "table" then
    channel.table_count = channel.table_count - 1
  elseif pending.kind == "public" then
    channel.public_count = channel.public_count - 1
  end
  channel.progress = channel.progress + 1
  if pending.given_up then
    if conn ~= nil then local _, _ = conn:close() end
    return
  end
  pending.done, pending.conn, pending.why = true, conn, why
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
    return "net: the connector is busy: it makes at most " .. raw.CONNECTOR_FLIGHT .. " connections at once"
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
  local wanted = named(Net.tcp(pending.host, pending.port))
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
    lose(channel, "net: the connector passed a socket connected to " .. named(peer) .. ", not " .. wanted)
    return false
  end
  answer(channel, tag, pending, new_conn(socket, pending.timeout_ns), "")
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
    elseif pending.conn ~= nil and not pending.taken then
      local _, _ = pending.conn:close()
    end
  end,
}

--- Asks the connector of `channel` with `body`, a request less its tag,
--- for a connection to `host` at `port` by `deadline`, once its hello has
--- been read and fewer than CONNECTOR_FLIGHT requests are pending (and,
--- for a `kind` of "table" or "public", fewer than CONNECTOR_FLIGHT less
--- TABLE_RESERVE of its kind): the connection, or nil and why. A request given up on
--- stays pending until its reply comes, which the connector sends within
--- the request's wait.
local function ask(channel: Channel, body: string, host: string, port: integer, deadline: integer,
                   timeout_ns: integer, refusal: string, kind: string): SocketConn | nil, string
  local room, waiting = await(channel, deadline, false, function(): boolean
    return channel.lost == nil and channel.greeted and channel.count < raw.CONNECTOR_FLIGHT and
      (kind ~= "table" or channel.table_count < raw.CONNECTOR_FLIGHT - TABLE_RESERVE) and
      (kind ~= "public" or channel.public_count < raw.CONNECTOR_FLIGHT - TABLE_RESERVE)
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
  local pending: Pending = { host = host, port = port, timeout_ns = timeout_ns, refusal = refusal,
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
  if pending.conn == nil then return nil, pending.why end
  pending.taken = true
  return pending.conn, ""
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
local function endpoint_allows(entry: Net.Endpoint, port: integer): boolean
  if entry.port ~= 0 then return entry.port == port end
  return port >= 1 and port <= 65535
end

--- `endpoints` as the rows the core's connector takes.
local function core_endpoints(endpoints: {Net.Endpoint}): {Child.ConnectorEndpoint}
  local rows: {Child.ConnectorEndpoint} = {}
  for i, entry in ipairs(endpoints) do rows[i] = { host = entry.host, port = entry.port } end
  return rows
end

--- The stream of `self`'s process, started where it has none or lost
--- its last and the process is this one's to start: nil and why where
--- it cannot be.
local function served(self: SocketConnector): Channel | nil, string
  local channel = self.channel
  if channel ~= nil and channel.lost == nil then return channel, "" end
  if self.inherited then return nil, "net: the connector has ended" end
  local started, why = Child.start_connector(core_endpoints(self.endpoints), self.timeout_ms, self.public)
  if started == nil then return nil, why end
  self.channel = channel_of(started)
  return self.channel, ""
end

function SocketConnector:connect(target: integer | string, port: integer, timeout_ns: integer): Net.Conn | nil, string
  if math.type(timeout_ns) ~= "integer" or timeout_ns < 0 then
    error("net: timeout_ns must be an integer from 0", 2)
  end
  if math.type(port) ~= "integer" then error("net: port must be an integer", 2) end
  if not self.open then return nil, "net: the connector is closed" end
  local deadline = Clock.monotonic_ns() + timeout_ns + CONNECTOR_GRACE_NS
  if self.endpoints == nil then
    -- A process for this connection alone, confined to this one endpoint.
    if type(target) ~= "string" then
      return nil, "net: a connector with no table connects to a numeric address"
    end
    if port < 1 or port > 65535 then return nil, "net: port must be from 1 to 65535" end
    local ms = math.max(1, math.min(60000, (timeout_ns + 999999) // 1000000))
    -- The core raises for a host that is no numeric address: a refusal here.
    local called, started, why = pcall(Child.start_connector, { { host = target, port = port } }, ms)
    if not called then return nil, "net: " .. target .. " is not a numeric address" end
    if started == nil then return nil, why end
    local alone <close> = started
    return ask(channel_of(alone), request_body(1, port, timeout_ns), target, port, deadline, timeout_ns, "", "")
  end
  local index: integer
  local host: string
  local body: string
  local refusal = ""
  local kind = ""
  if type(target) == "number" then
    index = target
    local entry = math.type(index) == "integer" and self.endpoints[index] or nil
    if entry == nil then
      return nil, "net: the connector has no endpoint " .. tostring(target)
    end
    if not endpoint_allows(entry, port) then
      return nil, "net: port " .. port .. " is not endpoint " .. index .. "'s"
    end
    host = entry.host
  else
    for i, entry in ipairs(self.endpoints) do
      if same_host(entry.host, target) and endpoint_allows(entry, port) then
        index = i
        host = entry.host
        break
      end
    end
    if index == nil then
      if not self.accepts_public then
        return nil, "net: " .. target .. ":" .. port .. " is not in the connector's table"
      end
      local bytes = Relay.Address.parse(target)
      if bytes == nil then return nil, "net: " .. target .. " is not a numeric address" end
      if port < 1 or port > 65535 then return nil, "net: port must be from 1 to 65535" end
      host = target
      -- The public index, 4294967295.
      body = request_body(0xffffffff, port, timeout_ns, bytes)
      if #self.endpoints > 0 then kind = "public" end
      refusal = "net: " .. target .. " is refused by the connector's deny list"
    end
  end
  if index ~= nil and self.accepts_public then kind = "table" end
  body = body or request_body(index, port, timeout_ns)
  local channel, why = served(self)
  if channel == nil then return nil, why end
  return ask(channel, body, host, port, deadline, timeout_ns, refusal, kind)
end

function SocketConnector:as_function(): function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
  return function(address: string, port: integer, timeout_ns: integer): Net.Conn | nil, string
    return self:connect(address, port, timeout_ns)
  end
end

function SocketConnector:ended(): boolean
  if not self.open then return true end
  local channel = self.channel
  return self.inherited and (channel == nil or channel.lost ~= nil or not channel.process.open)
end

function SocketConnector:close(): boolean, string
  if not self.open then return true, "" end
  self.open = false
  if self.channel ~= nil then lose(self.channel, "net: the connector is closed") end
  return true, ""
end

--- Every connector this module made, by itself, held weakly: what
--- [`ResolveOptions.connector`] takes.
local connectors_made: {Net.Connector: SocketConnector} = setmetatable({}, { __mode = "k" })

resolved_through = function(name: string, opts: Net.ResolveOptions): {Net.Resolved} | nil, string
  local through = connectors_made[opts.connector]
  if through == nil then
    error("net: connector must be one Net.connector or Net.connector_from made", 3)
  end
  if not through.open then return nil, "net: the connector is closed" end
  if through.endpoints == nil then
    return nil, "net: a lookup goes through a connector with a table of the name servers"
  end
  local listed: {Net.Endpoint} = {}
  if opts.servers ~= nil then
    for i, server in ipairs(opts.servers) do
      listed[i] = { host = server.host, port = server.port }
    end
  else
    local system, why = Relay.nameservers()
    if system == nil then return nil, why end
    for i, server in ipairs(system) do listed[i] = { host = server.host, port = server.port } end
  end
  if #listed > CONNECTOR_MAX_ENDPOINTS then
    return nil, "net: a lookup through a connector asks at most " .. CONNECTOR_MAX_ENDPOINTS ..
      " name servers, not " .. #listed
  end
  local servers: {raw_socket.ThroughServer} = {}
  for _, server in ipairs(listed) do
    local index: integer
    for i, entry in ipairs(through.endpoints) do
      if same_host(entry.host, server.host) and endpoint_allows(entry, server.port) then
        index = i
        break
      end
    end
    if index == nil then
      return nil, "net: the name server " .. named(Net.tcp(server.host, server.port)) ..
        " is not in the connector's table"
    end
    servers[#servers + 1] = { host = through.endpoints[index].host, port = server.port, index = index }
  end
  -- A request's wait word 0 is the connector's own wait to connect. The
  -- lookup gives each connect until its deadline; one given up on is still
  -- answered, its socket closed, so the stream stays in step.
  local reply_ns = Clock.ms(through.timeout_ms) + CONNECTOR_GRACE_NS
  local found, trouble = Relay.lookup(name, {
    timeout_ns = opts.timeout_ns,
    hosts = opts.hosts_file,
    through = servers,
    connect = function(index: integer, port: integer, deadline: integer | nil):
      Relay.Connection | nil, string
      local channel, why = served(through)
      if channel == nil then return nil, why end
      local body = string.pack(">I4I4I4I4", index, port, 0, 0) .. string.rep("\0", 16)
      local conn, because = ask(channel, body, through.endpoints[index].host, port,
        deadline or Clock.monotonic_ns() + reply_ns, Clock.ms(through.timeout_ms), "", "")
      if conn == nil then return nil, because end
      return { fd = conn.fd, release = function() local _, _ = conn:close() end }, ""
    end,
  })
  if found == nil then
    -- A stream given up fails every connect after it: its words say why.
    local lost = through.channel ~= nil and through.channel.lost or nil
    return nil, lost or trouble
  end
  return found, ""
end

--- The endpoints `endpoints` as a copy, so the caller's later changes to
--- its table reach neither the checks here nor a process started again;
--- it raises for one that is no list of 1 through 128 endpoints (0 where
--- `empty`).
local function copied_endpoints(endpoints: {Net.Endpoint}, empty: boolean): {Net.Endpoint}
  if type(endpoints) ~= "table" or #endpoints < (empty and 0 or 1) or #endpoints > CONNECTOR_MAX_ENDPOINTS then
    error("net: endpoints must be from " .. (empty and 0 or 1) .. " to " .. CONNECTOR_MAX_ENDPOINTS ..
        " numeric endpoints", 3)
  end
  local kept: {Net.Endpoint} = {}
  for i, entry in ipairs(endpoints) do
    if type(entry) ~= "table" or type(entry.host) ~= "string" or
        math.type(entry.port) ~= "integer" or entry.port < 0 or entry.port > 65535 then
      error("net: endpoints[" .. i .. "] must be a host and a port from 0 to 65535", 3)
    end
    kept[i] = { host = entry.host, port = entry.port }
  end
  return kept
end

--- A connector's wait to connect in milliseconds, from `timeout_ns` (nil
--- for the default), raising at `level` above the caller for one out of
--- range.
local function connector_timeout_ms(timeout_ns: integer | nil, level: integer): integer
  local chosen = timeout_ns or CONNECTOR_DEFAULT_NS
  if math.type(chosen) ~= "integer" or chosen < 1000000 or chosen > 60000000000 then
    error("net: timeout_ns must be an integer from 1 millisecond to 60 seconds", level + 1)
  end
  return (chosen + 999999) // 1000000
end

--- A copy of the public lists `public`, raising for one the process would
--- refuse to start with.
local function checked_public(public: Net.PublicOptions): Net.PublicOptions
  if type(public) ~= "table" or type(public.deny) ~= "table" or
      (public.own ~= nil and type(public.own) ~= "table") then
    error("net: public must hold a deny list and optionally an own list", 3)
  end
  local deny: {string} = {}
  local own: {string} = {}
  for i, cidr in ipairs(public.deny) do deny[i] = cidr end
  for i, address in ipairs(public.own or {}) do own[i] = address end
  return { deny = deny, own = own }
end

--- Starts the confined native connector, which connects TCP sockets to
--- numeric addresses and nothing else, and answers a [`Net.Connector`]
--- over it. The process can reach only what its kernel filter and an
--- immutable address table allow, hold no file and run no program, so a
--- host that runs the relay need not trust its own connecting code with
--- the network. Linux on x86_64 and aarch64 only: elsewhere it answers
--- nil and why.
---
--- With `endpoints`, a table of at most 128 [`Net.Endpoint`], one process
--- is started now and serves every request of the connector, up to
--- [`Net.CONNECTOR_FLIGHT`] at once: it suits a fixed set of addresses,
--- such as a relay whose grants are numeric. An endpoint that is no numeric address or a table that is
--- empty or too long raises. An endpoint at port 0 stands for every port,
--- and its slots take 1 MiB of the table if the address is IPv4 and 2 MiB
--- if IPv6: the port tables of all the endpoints are at most 32 MiB, so at
--- most 32 IPv4 or 16 IPv6 addresses at port 0 in a table of those alone.
--- Fixed-port endpoints (16 bytes if IPv4, 32 if IPv6, and each IPv6 range
--- starts at a 32-byte boundary) and a mix of the two change that count; a
--- table past the limit raises.
---
--- With none, every [`Connector.connect`] starts a process of its own,
--- confined to the one address and port it is asked for, and ends it
--- with the connection made: the way for a connector whose addresses are
--- known only when it connects. Its cost is a process for each
--- connection, and what it confines is the process alone: the caller
--- chooses the endpoint.
---
--- With `opts.public`, one process is started now (with an empty table if
--- there are no `endpoints`) that also connects to any numeric address
--- its table lacks, which [`Connector.connect`] asks it for by address
--- and port. The process judges the address itself, with the lists
--- `public` carries -- `deny`, the numeric "address/bits" prefixes it
--- refuses (at most 128; [`cosmic.relay`]'s `Address.deny_cidrs` is the
--- relay's list), and `own`, the host's own addresses (at most 256) --
--- and refuses every IPv6 address outside 2000::/3 whatever the lists
--- say, so IPv4-mapped and NAT64 forms are never decoded. It is the
--- check that stands if the caller's own is wrong, and the caller keeps
--- its own as well. A refused address answers "net: ... is refused by the
--- connector's deny list".
function Net.connector(endpoints?: {Net.Endpoint}, opts?: Net.ConnectorOptions): Net.Connector | nil, string
  local timeout_ms = connector_timeout_ms(opts ~= nil and opts.timeout_ns or nil, 2)
  local public = opts ~= nil and opts.public or nil
  if public ~= nil then public = checked_public(public) end
  local made: SocketConnector = setmetatable({
    timeout_ms = timeout_ms, open = true, public = public, accepts_public = public ~= nil,
  }, socket_connector_mt)
  connectors_made[made] = made
  if endpoints == nil and public == nil then return made, "" end
  local kept: {Net.Endpoint} = {}
  if endpoints ~= nil then kept = copied_endpoints(endpoints, public ~= nil) end
  made.endpoints = kept
  local started, why = Child.start_connector(core_endpoints(kept), timeout_ms, public)
  if started == nil then return nil, why end
  made.channel = channel_of(started)
  return made, ""
end

--- Answers a connector served by a process this one did not start: the
--- control stream `fd` it was handed (a socket pair's end, inherited
--- across a spawn), which the connector then owns and `close` closes,
--- and no process is signalled or waited for. `held`, the endpoints of
--- the table the process was started with, in order, lets
--- [`Connector.connect`] name them by address or index as [`Net.connector`]'s
--- does; `public` says the process was started in public mode, so that
--- it may be asked for an address the table lacks. Neither is
--- checked against the process, which holds its own table and lists:
--- a request the process refuses is answered as its refusal. The
--- stream is the process's own from its start: what it says first, which
--- names its protocol, is read before the first request, and a process
--- of another program's protocol fails it ("net: the connector speaks
--- another protocol than this program's"). A process that ends, or
--- whose stream falls out of step, is not started again: the connector
--- answers "net: the connector has ended" from then on. `fd` that is no descriptor, or a
--- `held` that is not a list of at most 128 endpoints, or a `timeout_ns`
--- out of [`ConnectorOptions.timeout_ns`]'s range, raises; nil and why
--- where the stream cannot be made nonblocking.
--- @param fd integer The inherited Unix stream the connector answers on
--- @param held {Net.Endpoint}|nil The process's table, if it has one
--- @param public boolean|nil Whether the process takes public requests
--- @param timeout_ns integer|nil The process's wait to connect, as it was started with (10 seconds by default), which a lookup through it waits out for each reply
--- @return Net.Connector|nil The connector
--- @return string Why not, when it is nil
function Net.connector_from(fd: integer, held?: {Net.Endpoint}, public?: boolean, timeout_ns?: integer):
    Net.Connector | nil, string
  if math.type(fd) ~= "integer" or fd < 0 then error("net: fd must be a descriptor", 2) end
  local kept: {Net.Endpoint} = {}
  if held ~= nil then kept = copied_endpoints(held, true) end
  local timeout_ms = connector_timeout_ms(timeout_ns, 2)
  local adopted, why = Child.adopt_connector(fd)
  if adopted == nil then return nil, why end
  local made: SocketConnector = setmetatable({
    timeout_ms = timeout_ms, open = true, endpoints = kept,
    channel = channel_of(adopted), inherited = true, accepts_public = public == true,
  }, socket_connector_mt)
  connectors_made[made] = made
  return made, ""
end

--- The fields a [`Net.ServeSpec`] may hold, so a misspelt one raises
--- rather than being ignored.
local SPEC_FIELDS <const>: {string: boolean} = {
  listeners = true, serve = true, limits = true, timeout_ns = true, grace_ns = true,
  on_ready = true, on_error = true, on_stop = true,
}

--- A field a spec once held, and what to do instead, so a program that
--- still sets one is told rather than only that the field is unknown.
local REMOVED_FIELDS <const>: {string: string} = {
  workers = "a server runs in one process, which workers = 0 asked for and is now " ..
    "the default, so drop the key; to serve in several, start each " ..
    "(Proc.relaunch gives the command, Child.start runs it), each listening at an " ..
    "address of its own",
}

--- Raises for the spec's `field`, at the caller of [`Net.serve`].
local function spec_error(field: string, must: string)
  error("net: spec." .. field .. " must be " .. must, 4)
end

--- Raises, naming the field, where `spec` is no [`Net.ServeSpec`].
local function checked_spec(spec: any)
  if not spec is {any: any} then error("net: serve takes a spec table", 3) end
  for key in pairs(spec) do
    if not (key is string and SPEC_FIELDS[key]) then
      local gone = key is string and REMOVED_FIELDS[key] or nil
      error("net: spec has no field " .. tostring(key) ..
          (gone ~= nil and ": " .. gone or ""), 3)
    end
  end
  local listeners = spec.listeners
  if not listeners is {any} or #listeners == 0 then
    spec_error("listeners", "a list of one address or more")
  end
  if listeners is {any} then
    for i, address in ipairs(listeners) do
      local trouble = address_trouble(address)
      if trouble ~= "" then spec_error("listeners[" .. i .. "]", trouble) end
    end
  end
  if type(spec.serve) ~= "function" then spec_error("serve", "a function of a connection") end
  local limits = spec.limits
  if limits ~= nil then
    if not limits is {any: any} then
      spec_error("limits", "a table")
    else
      for key in pairs(limits) do
        if key ~= "connections" then
          error("net: spec.limits has no field " .. tostring(key), 3)
        end
      end
      local most = limits.connections
      if most ~= nil and not (most is integer and most >= 1) then
        spec_error("limits.connections", "nil or an integer from 1")
      end
    end
  end
  for _, field in ipairs({ "timeout_ns", "grace_ns" }) do
    Poll.checked_ns(spec[field], "net", "spec." .. field, 3)
  end
  for _, field in ipairs({ "on_ready", "on_error", "on_stop" }) do
    local fn = spec[field]
    if fn ~= nil and type(fn) ~= "function" then spec_error(field, "nil or a function") end
  end
end

--- A listener a server accepts at, and the task accepting there while
--- there is one: none at the server's limit, or once it stops.
local record Accepting
  listener: Net.Listener
  fd: integer
  task: Poll.Task
  --- The errno the last accept failed with, reported once until another
  --- answer comes; 0 after one that did not fail.
  failing: integer
end

--- A server's state for the length of its run. Closing it closes every
--- listener and connection, so a run that raises -- [`on_ready`] or
--- [`on_error`] did -- leaves no socket file behind, and no connection
--- to a task that never started open.
local record Serving
  spec: Net.ServeSpec
  --- The most connections open at once.
  most: integer
  open: integer
  stopping: boolean
  accepts: {Accepting}
  --- Each connection open, by the task serving it.
  conns: {Poll.Task: Net.Conn}
  --- Waits for `stop` to cancel it.
  waiter: Poll.Task
  --- Holds SIGINT and SIGTERM for the run.
  guard: Child.Guard
  --- Waits on `guard`: its first signal stops the server, and the next
  --- ends the grace.
  watcher: Poll.Task
  --- Waits for `waiter` to end, then runs [`on_stop`].
  stopper: Poll.Task
  --- Waits out the grace while the server drains.
  grace: Poll.Task
  --- Set once a signal has ended the grace.
  hurried: boolean
  --- Set once a signal `guard` caught has stopped the server: only
  --- then has the server acted on what the guard holds.
  signalled: boolean
  metamethod __close: function(Serving)
end

local serving_mt: metatable<Serving> = {
  __close = function(self: Serving)
    for _, accepting in ipairs(self.accepts) do local _, _ = accepting.listener:close() end
    for _, conn in pairs(self.conns) do local _, _ = conn:close() end
    -- Closed, so a signal caught is delivered as it would be without
    -- the server's guard: this runs as the run raises, or after
    -- `serving` has closed or released the guard itself, when closing
    -- again does nothing.
    if self.guard ~= nil then local _, _ = self.guard:close() end
  end,
}

--- How long a listener waits after an accept failed -- out of
--- descriptors, say -- before it tries again, so a failure that lasts is
--- not retried, and reported, without pause.
local ACCEPT_PAUSE_NS <const> = Clock.ms(100)

--- Gives `trouble` to the spec's [`Net.ServeSpec.on_error`], or stderr.
local function report(s: Serving, trouble: string)
  if s.spec.on_error ~= nil then
    s.spec.on_error(trouble)
    return
  end
  local _, _ = Fs.put(Fs.stderr, "net: " .. trouble .. "\n")
end

--- What a protocol raised, with the stack it raised from, which is gone
--- once xpcall returns.
local function traced(err: any): string
  return errors.trace(tostring(err), 2)
end

local resume_accepting: function(s: Serving)

--- Serves `conn` in a task of its own, counted open until the protocol
--- is done with it.
local function serve_conn(s: Serving, conn: Net.Conn)
  s.open = s.open + 1
  local task: Poll.Task
  task = Poll.spawn(function()
    local held <close> = conn
    local ok, trouble: boolean, any = xpcall(s.spec.serve, traced, held)
    local _, _ = held:close()
    s.open = s.open - 1
    s.conns[task] = nil
    resume_accepting(s)
    if not ok then report(s, tostring(trouble)) end
  end)
  s.conns[task] = conn
end

--- Accepts at `a` while the server is under its limit and not stopping.
--- The limit is checked before each accept with no wait between, so a
--- connection past it is never taken, only left in the backlog.
local function accept_loop(s: Serving, a: Accepting)
  while not s.stopping and s.open < s.most do
    local socket, why, errno = raw.accept(a.fd)
    if socket ~= nil then
      a.failing = 0
      serve_conn(s, new_conn(socket, s.spec.timeout_ns))
    elseif errno == raw.EAGAIN then
      a.failing = 0
      -- `stop` cancels this wait, as it does the pause below.
      local _, _ = Poll.readable(a.fd)
    else
      -- raw.accept has retried EINTR and passed over a pending
      -- connection that failed, so this failure is the listener's.
      if errno ~= a.failing then
        a.failing = errno
        report(s, "accepting at " .. named(a.listener.address) .. ": " .. why)
      end
      local _, _ = Poll.delay(ACCEPT_PAUSE_NS)
    end
  end
  a.task = nil
end

resume_accepting = function(s: Serving)
  if s.stopping or s.open >= s.most then return end
  for _, a in ipairs(s.accepts) do
    if a.task == nil then a.task = Poll.spawn(function() accept_loop(s, a) end) end
  end
end

--- Waits for every connection open to finish. The tasks of those left
--- once `grace_ns` has passed, or a signal has ended the grace, are
--- killed where they wait, their connections closed first.
local function drain(s: Serving)
  if s.stopper ~= nil then local _, _ = s.stopper:join() end
  if not s.hurried then
    local grace = s.spec.grace_ns
    local deadline = grace ~= nil and Clock.monotonic_ns() + grace or nil
    -- A task of its own, so a signal can end the grace by cancelling it.
    s.grace = Poll.spawn(function()
      while true do
        local task = next(s.conns)
        if task == nil then return end
        local left: integer = nil
        if deadline ~= nil then left = math.max(deadline - Clock.monotonic_ns(), 0) end
        local ended, _ = task:join(left)
        if not ended then return end
      end
    end)
    local _, _ = s.grace:join()
  end
  local left: {Poll.Task} = {}
  for task in pairs(s.conns) do left[#left + 1] = task end
  for _, task in ipairs(left) do
    -- Closed before the kill, so a `<close>` handler that reads or
    -- writes it fails at once rather than wait; and done here, as a
    -- killed task is not resumed to do what serve_conn does after the
    -- protocol returns.
    local _, _ = s.conns[task]:close()
    local killed, trouble: boolean, any = pcall(task.kill, task)
    s.conns[task] = nil
    s.open = s.open - 1
    -- Without its stack: the handler raised as its coroutine closed,
    -- past any handler that could have traced it.
    if not killed then report(s, tostring(trouble)) end
  end
end

--- Stops `s`, as [`Server.stop`] does.
local function stop(s: Serving)
  if s.stopping then return end
  s.stopping = true
  for _, a in ipairs(s.accepts) do
    local closed, why = a.listener:close()
    if not closed then report(s, why) end
    if a.task ~= nil then a.task:cancel() end
  end
  s.waiter:cancel()
end

--- Stops `s` at the first signal its guard takes, and ends its grace at
--- the next, until the task is cancelled.
local function watch(s: Serving)
  while true do
    local signal, _ = s.guard:wait()
    if signal == 0 then return end
    if not s.stopping then
      s.signalled = true
      stop(s)
    else
      s.hurried = true
      if s.stopper ~= nil then s.stopper:cancel() end
      if s.grace ~= nil then s.grace:cancel() end
    end
  end
end

--- The body of [`Net.serve`]'s run, over listeners of its own.
local function serving(spec: Net.ServeSpec): boolean, string
  local state: Serving = {
    spec = spec, most = spec.limits and spec.limits.connections or math.maxinteger,
    open = 0, stopping = false, accepts = {}, conns = {}, hurried = false,
    signalled = false,
  }
  local s <close> = setmetatable(state, serving_mt)
  local guard, guard_trouble = Child.guard()
  if guard == nil then return false, "net: signal guard: " .. guard_trouble end
  s.guard = guard
  local addresses: {Net.Address} = {}
  for i, address in ipairs(spec.listeners) do
    local opened, trouble = listening(address, {}, 1)
    if opened == nil then return false, trouble end
    s.accepts[i] = { listener = opened.listener, fd = opened.fd, failing = 0 }
    addresses[i] = opened.listener.address
  end
  local server: Net.Server = {
    addresses = addresses,
    stop = function(_self: Net.Server) stop(s) end,
  }
  s.waiter = Poll.spawn(function()
    while not s.stopping do local _, _ = Poll.delay(Poll.MOST_NS) end
  end)
  local on_stop = spec.on_stop
  if on_stop ~= nil then
    -- Spawned here, not by `stop`, which may be called from a coroutine
    -- a task made, where Poll.spawn raises. A task of its own, so the
    -- watcher stays free to cancel a wait it makes at a second signal,
    -- and what it raises is not taken for the failure of a connection
    -- whose protocol called `stop`.
    s.stopper = Poll.spawn(function()
      local _, _ = s.waiter:join()
      local ok, trouble: boolean, any = xpcall(on_stop, traced, server)
      if not ok then report(s, tostring(trouble)) end
    end)
  end
  resume_accepting(s)
  s.watcher = Poll.spawn(function() watch(s) end)
  if spec.on_ready ~= nil then spec.on_ready(addresses, server) end
  local _, _ = s.waiter:join()
  drain(s)
  s.watcher:cancel()
  -- Released where a signal stopped the server, which has acted on it;
  -- closed otherwise, so one caught in a drain that `stop` began is
  -- delivered as it would be without this guard.
  local restore_trouble: string
  if s.signalled then
    local _, trouble = guard:release()
    restore_trouble = trouble
  else
    local _, trouble = guard:close()
    restore_trouble = trouble
  end
  if restore_trouble ~= "" then return false, "net: signal restore: " .. restore_trouble end
  return true, ""
end

--- Serves `spec.serve` at each of `spec.listeners`, each connection in a
--- task of its own, in a [`Poll.run`] of its own: so it cannot be called
--- in a task of another. It returns true once [`Server.stop`] has been
--- called, or a signal has stopped it, and every task of the run has
--- ended -- each connection's, and any [`Net.ServeSpec.on_ready`] or
--- [`Net.ServeSpec.on_stop`] spawned -- and false and why, having called
--- nothing, where a listener cannot listen or its signal guard cannot
--- be opened, or, having served, where the guard cannot restore the
--- dispositions it found. What
--- [`Net.ServeSpec.on_ready`] or [`Net.ServeSpec.on_error`] raises, it raises,
--- having closed every listener and connection.
---
--- One connection's failure is its own: what its protocol raises is
--- given to [`Net.ServeSpec.on_error`], the connection is closed, and the
--- rest are served on. A connection still open `grace_ns` after the
--- stop is closed, and its task killed where it waits
--- ([`Poll.Task.kill`]): the protocol is not resumed, but its `<close>`
--- variables are closed -- where a read or write of the connection
--- fails at once, and any other wait raises -- and what one of them
--- raises is reported the same way, without its stack.
--- A protocol that loops without waiting -- calling read after
--- "net: the connection is closed", which fails without waiting, or computing
--- without end -- cannot be killed: it holds the thread, and so every
--- task of the run and Net.serve's return, until it waits.
---
--- SIGINT and SIGTERM stop the server as [`Server.stop`] does: it holds
--- a [`Child.guard`] for its run, and the first signal of either kind
--- stops it. One more while it drains ends `grace_ns` at once, the
--- connections still open killed and closed. Where a signal stopped
--- it, the guard is released, not closed, so Net.serve returns true
--- without the signal delivered again; a caller that would know of it,
--- or die of it, holds a [`Child.guard`] of its own around the call,
--- which sees it too. A signal the server did not stop on, one in a
--- drain [`Server.stop`] began, is delivered again as the guard closes,
--- as it would be without it; so is any signal caught where a listener
--- cannot listen or [`Net.ServeSpec.on_ready`] or [`Net.ServeSpec.on_error`]
--- raises. A
--- [`Child.run`] in a protocol holds a guard inside the server's, so a
--- signal ends its child as it would anywhere, and a run begun after
--- the signal runs to its end. A wait that holds the thread rather than
--- waiting through the run ([`Http.get`]'s, `h:wait` on a child a
--- protocol started) reads the server's guard, and ends at a signal.
function Net.serve(spec: Net.ServeSpec): boolean, string
  checked_spec(spec)
  if Poll.in_task() then
    error("net: serve runs a Poll.run of its own, and cannot be called in a task of another", 2)
  end
  local ok, why = true, ""
  Poll.run(function() ok, why = serving(spec) end)
  if not ok then return false, why end
  return true, ""
end

return Net
