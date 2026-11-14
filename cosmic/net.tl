--- Stream sockets listen, accept and connect, then read and write as a
--- [`cosmic.stream`] Reader and Writer. [`Net.resolve`] looks a host name
--- up, as the system's resolver would, and answers every address it has.
---
---     local server <close> = assert(Net.listen(Net.unix(dir .. "/app.sock")))
---     local conn <close> = assert(server:accept())
---     local lines = Stream.lines(conn) -- holds what it read past a line: see `rest`
---     local line = lines:read()
---
--- An address's `kind` selects its fields: "unix" takes a socket file's
--- path; "tcp" and "udp" take a numeric host and port.
---
---     local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
---     local port = server.address.port -- the one the kernel chose
---
--- A connection is one object for both directions; `shutdown("write")`
--- tells the peer the end of what was sent while its answer is still
--- read. That suits a protocol whose request ends at end of file. After a
--- framed request (HTTP, a length prefix) do not half-close: a server may
--- take the half-close as the client closing and answer nothing. HTTP over
--- a unix socket is [`Http.request`] with `via`. The direction is a
--- [`Net.Shutdown`], one of "read", "write" or "both", and any other
--- string does not compile.
---
--- Every wait -- to connect, to accept, to read, to write -- lasts at
--- most the object's timeout (no limit by default; [`set_timeout`]
--- changes it), failing with [`Poll.TIMEOUT`], and ends with
--- "interrupted", within a tenth of a second, when the innermost open
--- [`Signal.guard`] catches SIGINT or SIGTERM, as [`cosmic.http`]'s do.
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
---
--- [`Net.datagram`] binds a UDP socket, which sends and receives whole
--- datagrams, each to or from an address of its own, with no connection
--- and no promise that one arrives.
---
---     local socket <close> = assert(Net.datagram(Net.udp("127.0.0.1", 0)))
---     assert(socket:send("ping", Net.udp("127.0.0.1", 9000)))
---     local packet = socket:receive(Clock.seconds(1))
---
--- A UDP socket takes part in multicast. `join` makes it a member of a
--- group, whose datagrams it then receives at its port, and
--- [`set_multicast`] says how the ones it sends to a group leave. Every such
--- call names an interface the same way, as `via`: one of the interface's
--- IPv4 addresses for IPv4, the interface's index for IPv6, and nil for
--- the interface the system chooses. [`Net.interfaces`] lists both.
---
---     local socket <close> = assert(Net.datagram(Net.udp("0.0.0.0", 5353), { shared = true }))
---     assert(socket:join("224.0.0.251", "192.0.2.7"))
---     assert(socket:set_multicast({ via = "192.0.2.7", hops = 1 }))

local Array = require("cosmic.array")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local errors = require("cosmic.internal.errors")
local Resolv = require("cosmic.internal.relay_resolv")
local Connection = require("cosmic.internal.connection")
local Signal = require("cosmic.signal")
local Leaf = require("cosmic.internal.connector")

--- The raw module behind this one lives under the reserved
--- `cosmic.internal.` namespace, which only cosmic's own tree may require.
local type raw_socket = require("cosmic.internal.socket")

local raw = require("cosmic.internal.socket")

local waited = Connection.waited

-- How a listener is made: a class ([`SocketListener`]) implementing the public
-- interface it answers, so one costs one table and no closure: its methods are
-- defined once, on the class, which an object reaches through `__index`, and
-- its state is in fields. (A connection is the class [`Connection.Conn`] of
-- cosmic/internal/connection.tl.) The note on how an object is made in
-- cosmic/stream.tl says why Teal makes the public types interfaces. One
-- dropped unclosed needs no __gc: its socket, which only the object
-- holds, is closed by the collector.

--- What `address` is called in a failure: its path, or its host and
--- port, an IPv6 host in brackets.
local function named(address: raw_socket.Address): string
  if address.kind == "unix" then
    local path = assert(address.path, "a unix address has the path Net.unix gave it")
    return path
  end
  local host = assert(address.host)
  if host:find(":", 1, true) then host = "[" .. host .. "]" end
  return host .. ":" .. tostring(address.port)
end

--- A socket listening at an address, answered by [`Net.listen`].
local class SocketListener
  --- Where it listens.
  address: raw_socket.Address
  --- Internal: the socket, its descriptor and whether it is open. No caller reads or writes them.
  socket: raw_socket.Socket
  --- Internal: see `socket`.
  fd: integer
  --- Internal: see `socket`.
  mut open: boolean
  -- Set by [`set_timeout`], and given to each connection accepted after.
  -- Nil for no limit.
  mut limit?: integer

  --- Sets how long `accept` waits by default, in nanoseconds, from 0;
  --- nil for no limit. A value no wait can last raises, naming
  --- `timeout_ns`, at the caller. The connections accepted after start
  --- with the same.
  function set_timeout(self, wait_ns: integer?)
    Poll.checked_ns(wait_ns, "net", "timeout_ns", 2)
    self.limit = wait_ns
  end

  --- The next connection, waiting for one as long as `timeout_ns`
  --- (this call's, or the listener's); nil and [`Poll.TIMEOUT`],
  --- "interrupted", "cancelled" (in a task of [`Poll.run`]), or why not.
  function accept(self, wait_ns?: integer): Connection.Conn?, string
    Poll.checked_ns(wait_ns, "net", "timeout_ns", 2)
    if not self.open then return nil, "net: the listener is closed" end
    wait_ns = wait_ns or self.limit
    local fd = self.fd
    while true do
      local connection, why, errno = raw.accept(fd)
      if connection ~= nil then return Connection.new(connection, self.limit), "" end
      if errno ~= raw.EAGAIN then return nil, why end
      local ready, waiting = waited(fd, false, wait_ns)
      if not ready then return nil, waiting end
      if not self.open then return nil, "net: the listener is closed" end
    end
  end

  --- Stops listening. A unix listener removes its socket file too,
  --- unless another file has taken the name since. Safe to call more
  --- than once.
  function close(self): boolean, string
    if not self.open then return true, "" end
    self.open = false
    Poll.closing(self.fd)
    local ok, why = self.socket:close()
    if not ok then return false, named(self.address) .. ": " .. why end
    return true, ""
  end

  function __close(self)
    local _, _ = self:close()
  end
end

--- The most bytes one UDP datagram holds.
local DATAGRAM_MAX <const> = 65535

--- The largest index [`checked_via`] takes: what the system's `int` holds.
local INDEX_MAX <const> = 2147483647

--- How a [`Net.Datagram`] sends to a multicast group, given to its
--- [`set_multicast`]. A field left nil leaves that setting as it is.
local record Multicast
  --- The interface the datagrams leave by: one of its IPv4 addresses
  --- for a socket bound to an IPv4 address, its index for one bound to an
  --- IPv6 address ([`Net.interfaces`] lists both).
  via?: string | integer
  --- How many hops a datagram lives, from 0 to 255 (IPv4's TTL, IPv6's
  --- hop limit): 1, the system's default, keeps it on the interface's own
  --- network, and 0 on this machine.
  hops?: integer
  --- Whether this machine's own members of the group receive the
  --- datagrams too, this socket among them if it joined. They do by the
  --- system's default.
  loop?: boolean
end

--- Raises, `level` above the caller, for a `via` that names no interface
--- as its family does: an index for IPv6, an address for IPv4.
local function checked_via(via: (string | integer)?, ipv6: boolean, level: integer)
  if via == nil then return end
  if ipv6 then
    if not via is integer or via < 1 or via > INDEX_MAX then
      error("net: via must be an interface's index, an integer from 1, for IPv6", level + 1)
    end
  elseif not via is string then
    error("net: via must be one of an interface's IPv4 addresses, a string, for IPv4", level + 1)
  end
end

--- What a refused membership says: errno's words, and for EINVAL what
--- they leave unsaid.
local function membership_trouble(group: string, why: string, errno: integer): string
  if errno == raw.EINVAL then
    return group .. ": " .. why .. " (the group must be a numeric IPv4 or IPv6 multicast address, " ..
      "and an IPv4 interface a numeric address)"
  end
  return group .. ": " .. why
end

--- A bound UDP socket, answered by [`Net.datagram`]. A class, so a
--- `<close>` local holds one. One dropped unclosed needs no __gc: its
--- socket, which only the object holds, is closed by the collector.
local class UdpSocket
  --- Where it is bound, with the port the kernel chose for port 0.
  address: raw_socket.Address
  --- Internal: the socket, its descriptor and whether it is open. No caller reads or writes them.
  socket: raw_socket.Socket
  --- Internal: see `socket`.
  fd: integer
  --- Internal: see `socket`.
  mut open: boolean
  -- Set by [`set_timeout`]. Nil for no limit.
  mut limit?: integer

  --- Sets how long `send` and `receive` wait by default, in nanoseconds,
  --- from 0; nil for no limit. A value no wait can last raises, naming
  --- `timeout_ns`, at the caller.
  function set_timeout(self, wait_ns: integer?)
    Poll.checked_ns(wait_ns, "net", "timeout_ns", 2)
    self.limit = wait_ns
  end

  --- Sends `data`, possibly empty, as one datagram to `to`, a
  --- [`Net.udp`] address: true once the system has taken it whole, which
  --- says nothing of its arrival. False and [`Poll.TIMEOUT`],
  --- "interrupted", "cancelled" (in a task of [`Poll.run`]) or why not
  --- sends none of it. Raises on `data` over 65535 bytes and on an
  --- address of another kind or with a port past 65535.
  function send(self, data: string, to: raw_socket.Address): boolean, string
    if #data > DATAGRAM_MAX then
      error("net: a datagram holds at most " .. tostring(DATAGRAM_MAX) .. " bytes", 2)
    end
    local host, port = to.host, to.port
    if to.kind ~= "udp" or not host is string or math.type(port) ~= "integer" or port == nil or
        port < 0 or port > 65535 then
      error("net: a datagram is sent to a udp address, from Net.udp, whose host is a string and " ..
          "port an integer from 0 to 65535", 2)
    end
    if not self.open then return false, "net: the socket is closed" end
    local fd = self.fd
    while true do
      local ok, why, errno = raw.sendto(fd, data, to)
      if ok then return true, "" end
      if errno == raw.EINVAL then
        return false, why .. " (not a numeric IPv4 or IPv6 address: a name is not looked up, " ..
          "nor an IPv6 scope read)"
      end
      if errno ~= raw.EAGAIN then return false, why end
      local ready, waiting = waited(fd, true, self.limit)
      if not ready then return false, waiting end
      if not self.open then return false, "net: the socket is closed" end
    end
  end

  --- The next datagram whole, with the address it came from, waiting for
  --- one as long as `timeout_ns` (this call's, or the socket's); nil and
  --- [`Poll.TIMEOUT`], "interrupted", "cancelled" (in a task of
  --- [`Poll.run`]), or why not. Datagrams arrive in no promised order,
  --- and one the network or a full buffer dropped never does.
  function receive(self, wait_ns?: integer): raw_socket.Packet?, string
    Poll.checked_ns(wait_ns, "net", "timeout_ns", 2)
    if not self.open then return nil, "net: the socket is closed" end
    wait_ns = wait_ns or self.limit
    local fd = self.fd
    while true do
      local packet, why, errno = raw.recvfrom(fd, DATAGRAM_MAX)
      if packet ~= nil then return packet, "" end
      if errno ~= raw.EAGAIN then return nil, why end
      local ready, waiting = waited(fd, false, wait_ns)
      if not ready then return nil, waiting end
      if not self.open then return nil, "net: the socket is closed" end
    end
  end

  --- Joins the multicast `group`, a numeric IPv4 or IPv6 address, on the
  --- interface `via` names (see [`cosmic.net`]; nil for the one the
  --- system chooses), so that the socket receives the datagrams sent to
  --- the group at its port. To receive them the socket is bound to the
  --- wildcard host ("0.0.0.0" or "::") or to the group itself, not to an
  --- address of the machine. A socket may join many groups, and one group
  --- on several interfaces; closing it leaves them all. False and why
  --- where it cannot: a group that is no multicast address, one already
  --- joined there ("Address in use"), or no such interface. Raises on a
  --- `via` of the wrong form for the group's family.
  function join(self, group: string, via?: string | integer): boolean, string
    checked_via(via, group:find(":", 1, true) ~= nil, 2)
    if not self.open then return false, "net: the socket is closed" end
    local ok, why, errno = raw.membership(self.fd, group, via, true)
    if not ok then return false, membership_trouble(group, why, errno) end
    return true, ""
  end

  --- Leaves `group` on the interface `via` names, as it was given to
  --- `join`. False and why where the socket is no member of it there.
  --- Raises as `join` does.
  function leave(self, group: string, via?: string | integer): boolean, string
    checked_via(via, group:find(":", 1, true) ~= nil, 2)
    if not self.open then return false, "net: the socket is closed" end
    local ok, why, errno = raw.membership(self.fd, group, via, false)
    if not ok then return false, membership_trouble(group, why, errno) end
    return true, ""
  end

  --- Sets how the datagrams this socket sends to a multicast group
  --- leave: each field of `opts` that is not nil, in the order `via`,
  --- `hops`, `loop`. False and why at the first the system refuses, such
  --- as a `via` that is no interface of the machine; the ones before it
  --- stay set. Raises on a `via` of the wrong form for the family of the
  --- socket's address, and on `hops` outside 0 to 255.
  function set_multicast(self, opts: Multicast): boolean, string
    local via, hops, loop = opts.via, opts.hops, opts.loop
    checked_via(via, assert(self.address.host):find(":", 1, true) ~= nil, 2)
    if hops ~= nil and (hops < 0 or hops > 255) then error("net: hops must be from 0 to 255", 2) end
    if not self.open then return false, "net: the socket is closed" end
    if via ~= nil then
      local ok, why = raw.multicast_interface(self.fd, via)
      if not ok then return false, "via " .. tostring(via) .. ": " .. why end
    end
    if hops ~= nil then
      local ok, why = raw.multicast_hops(self.fd, hops)
      if not ok then return false, "hops: " .. why end
    end
    if loop ~= nil then
      local ok, why = raw.multicast_loop(self.fd, loop)
      if not ok then return false, "loop: " .. why end
    end
    return true, ""
  end

  --- Closes the socket, ending a task's wait on it. Safe to call more
  --- than once.
  function close(self): boolean, string
    if not self.open then return true, "" end
    self.open = false
    Poll.closing(self.fd)
    local ok, why = self.socket:close()
    if not ok then return false, named(self.address) .. ": " .. why end
    return true, ""
  end

  function __close(self)
    local _, _ = self:close()
  end
end

local record Net
  --- Where a socket is, as [`Net.unix`] and [`Net.tcp`] build one: a
  --- `kind` of "unix", with the socket file's `path`, or "tcp" or "udp",
  --- with a numeric `host` and a `port`. It is the raw socket module's own
  --- record.
  type Address = raw_socket.Address

  --- A bound UDP socket, answered by [`Net.datagram`]. A class, so a
  --- `<close>` local holds one.
  type Datagram = UdpSocket

  --- One datagram a [`Datagram`]'s `receive` answers: its `data`, whole
  --- and possibly empty, and the "udp" `address` it came from.
  type Packet = raw_socket.Packet

  record DatagramOptions
    --- How long `send` and `receive` wait, in nanoseconds, from 0; nil
    --- for no limit.
    timeout_ns?: integer
    --- Lets other sockets, of this process or another, bind the same
    --- address and port, where each of them asks the same: how several
    --- programs receive one multicast group at its port. Each member
    --- gets every datagram sent to the group. A datagram sent to the
    --- port alone, not to a group, goes to one of the sockets, whichever
    --- the system picks.
    shared?: boolean
  end

  --- How a [`Datagram`] sends to a multicast group, given to its
  --- [`set_multicast`].
  type MulticastOptions = Multicast

  --- One network interface of the machine, as [`Net.interfaces`] lists
  --- them.
  record Interface
    --- Its name: "lo", "en0".
    name: string
    --- Its index, from 1: what names it as the `via` of an IPv6 group.
    index: integer
    --- Whether it is up.
    up: boolean
    --- Whether it is a loopback interface.
    loopback: boolean
    --- Whether it carries multicast.
    multicast: boolean
    --- Its IPv4 and IPv6 addresses, numeric, a link-local IPv6 one
    --- without its zone; none for an interface that has no address. An
    --- IPv4 one names the interface as the `via` of an IPv4 group.
    addresses: {Resolved}
  end

  --- A connection, answered by `accept` and [`Net.connect`]: a
  --- [`Stream.Reader`] of what the peer sends and a [`Stream.Writer`] to
  --- it.
  type Conn = Connection.Conn

  --- The direction a [`Conn`]'s `shutdown` ends: "read", "write" or "both".
  type Shutdown = Connection.Shutdown

  --- What [`Net.connect`] and a [`Connector`]'s `connect` take.
  type ConnectOptions = Connection.ConnectOptions

  --- Connects to numeric TCP addresses through the sandbox's native
  --- connector process, answered by [`Net.connector`]: a process confined
  --- to the endpoints it was given and, if so made, to a public list,
  --- which connects a socket and passes it back over a private stream.
  type Connector = Leaf.Served

  record ListenOptions
    --- How long `accept` waits, in nanoseconds, from 0; nil for no
    --- limit. The connections it accepts start with the same.
    timeout_ns?: integer
    --- How many connections may wait to be accepted (64 by default).
    --- A unix connection past it fails at once rather than waiting (see
    --- [`ConnectOptions.timeout_ns`]).
    backlog?: integer
  end

  --- A socket listening at an address, answered by [`Net.listen`]. A class,
  --- so a `<close>` local holds one.
  type Listener = SocketListener

  --- One numeric endpoint, a DNS server of [`ResolveOptions.servers`] or
  --- one a native connector may reach: a canonical
  --- IPv4 or IPv6 `host` (no name, no scope, no leading zeroes) and a
  --- `port`, 0 for any nonzero port at that host.
  record Endpoint
    --- The numeric address, no name.
    mut host: string
    --- The port. A DNS server's is 1 to 65535; only a connector's table
    --- takes 0, any nonzero port.
    port: integer
  end

  record ConnectorOptions
    --- The ceiling on how long any one connect waits, in nanoseconds, from
    --- 1 millisecond to 60 seconds (10 seconds by default), fixed when the
    --- process starts. A connect waits `min(opts.timeout_ns, ceiling)`
    --- ([`ConnectOptions.timeout_ns`] of the call), and a call with no
    --- `timeout_ns` waits the ceiling.
    timeout_ns?: integer
    --- Makes the connector public: it also connects to an address its
    --- endpoints lack, judged by the process itself against the lists given
    --- here (see [`Net.connector`]). Without it, the endpoints are the
    --- connector's whole authority.
    public?: PublicOptions
  end

  --- What a public connector refuses, as data its process holds: the
  --- native connector has no list of its own. `deny` is the refused
  --- prefixes as numeric "address/bits" text, at most 128
  --- ([`cosmic.relay.address`]'s `deny_cidrs` lists the relay's), and `own`
  --- the host's own numeric addresses, at most 256, refused as their own.
  --- An IPv6 address outside 2000::/3 is refused besides, whatever is listed.
  record PublicOptions
    --- The refused prefixes, numeric "address/bits" text.
    deny: {string}
    --- The host's own numeric addresses, refused as their own.
    own?: {string}
  end

  --- One address a name resolves to, answered by [`Net.resolve`]: its
  --- numeric form (four decimal octets for IPv4, `inet_ntop`'s for IPv6)
  --- and its `family`, "ipv4" or "ipv6".
  type Resolved = raw_socket.Resolved

  record ResolveOptions
    --- How long the lookup waits in all, in nanoseconds, from 0; nil for
    --- no limit beyond the resolver's own retries.
    timeout_ns?: integer
    --- Name servers to ask in place of the system's: one or more
    --- numeric [`Net.Endpoint`]s, such as [`Net.nameservers`] lists.
    mut servers?: {Endpoint}
    --- A hosts file to read in place of the system's.
    mut hosts_file?: string
    --- Resolves over TCP alone, every socket of the lookup made by this
    --- connector, one [`Net.connector`] made with
    --- a table, and no datagram sent: the servers asked are `servers`, or
    --- the system's ([`Net.nameservers`]), each of which the
    --- connector's table must hold at its port. A connector built from
    --- those alone reaches nothing else, so the lookup's
    --- sockets reach nothing but the name servers. The lookup asks
    --- one connection at a time, sharing the connector's stream with
    --- any other request, each in its place by tag. Linux only, as the
    --- connector is.
    mut connector?: Connector
  end

  --- What [`Net.serve`] serves, and how. A value out of range (no
  --- listener, an address no listener can take, a limit under 1, a
  --- timeout out of range) raises, naming the field.
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
      connections?: integer
    end
    --- Bounds on what the server takes on; nil for none.
    limits?: Limits
    --- Each connection's `timeout_ns`: how long any one read or write of
    --- it waits, from 0; nil for no limit.
    timeout_ns?: integer
    --- On stopping, how long open connections have to finish, from 0,
    --- before they are closed and their tasks killed
    --- ([`Poll.Task.kill`]); nil to wait for every one.
    grace_ns?: integer
    --- Called once every listener listens, in a task of the server's
    --- run, with where each listens -- a port the kernel chose for one
    --- at port 0 included -- in the order of `listeners`, and the
    --- server, to stop it by. It may spawn tasks of its own there, which
    --- [`Net.serve`] waits for too. What it raises, [`Net.serve`] raises,
    --- having closed every listener.
    on_ready?: function(addresses: {Address}, server: Server)
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
    mut on_stop?: function(server: Server)
    --- Given what the protocol raised for a connection, with its stack,
    --- or why a listener failed to accept; nil to write each to stderr.
    --- What it raises, [`Net.serve`] raises, having closed every listener
    --- and connection, as an error in [`Poll.run`] ends it.
    on_error?: function(trouble: string)
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

local DEFAULT_BACKLOG <const> = 64

--- The address of the socket file at `path`.
function Net.unix(path: string): Net.Address
  return { kind = "unix", path = path }
end

--- The address of TCP `port` at `host`, a numeric IPv4 or IPv6 address.
function Net.tcp(host: string, port: integer): Net.Address
  return { kind = "tcp", host = host, port = port }
end

--- Where a [`Net.datagram`] binds or a datagram goes: UDP `port` at
--- `host`, numeric as [`Net.tcp`]'s is.
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
      tostring(raw.SOCKET_NAME_MAX) .. " bytes here)"
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

--- A listener and its descriptor, which [`Net.serve`] waits on itself
--- so as to take a connection only while under its limit.
local record Opened
  listener: Net.Listener
  fd: integer
end

--- The listener over `socket`, at `address`.
local function new_listener(socket: raw_socket.Socket, address: Net.Address,
                            timeout_ns: integer?): Opened
  local fd = socket:fd()
  local listener: SocketListener = {
    address = address, socket = socket, fd = fd, open = true, limit = timeout_ns }
  return { listener = listener, fd = fd }
end

--- What [`connection`] made: the socket, or, where there is none, what
--- went wrong and its errno, which `said` words. `errno` is 0 for a
--- wait's own [`Poll.TIMEOUT`] or "cancelled" in a task.
local record Attempt
  socket?: raw_socket.Socket
  trouble?: string
  errno?: integer
end

--- A socket being connected in a task, closed when the task leaves it
--- unclaimed -- a run torn down while it waits included -- rather than
--- left to the collector.
local record Connecting
  --- Nil once the task has handed the socket on.
  socket?: raw_socket.Socket
  __close: function(Connecting)
end

local connecting_mt: metatable<Connecting> = { -- checked: literal_missing
  __close = function(self: Connecting)
    local socket = self.socket
    if socket ~= nil then local _, _ = socket:close() end
  end,
}

--- Why `address` is no [`Net.Address`] a listener can take, or "".
local function address_trouble(address: Net.Address): string
  local kind, path, host, port = address.kind, address.path, address.host, address.port
  if kind == "unix" then
    if path ~= nil and path ~= "" then return "" end
    return "a unix address whose path is a string of at least one byte"
  end
  if kind == "tcp" then
    if host ~= nil and port ~= nil and port >= 0 and port <= 65535 then return "" end
    return "a tcp address whose host is a string and port an integer from 0 to 65535"
  end
  return "an address, from Net.unix or Net.tcp"
end

--- Why `address` is no [`Net.udp`] address, or "".
local function datagram_trouble(address: Net.Address): string
  local host, port = address.host, address.port
  if address.kind == "udp" and host is string and math.type(port) == "integer" and port ~= nil and
      port >= 0 and port <= 65535 then
    return ""
  end
  return "a udp address, from Net.udp, whose host is a string and port an integer from 0 to 65535"
end

--- [`Net.resolve`] through `opts.connector`, defined with the connector.
local resolved_through: function(name: string, opts: Net.ResolveOptions): {Net.Resolved}?, string

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
--- [`Poll.TIMEOUT`], "interrupted" (an open [`Signal.guard`] caught a
--- signal), or the system's words ("Connection refused" where every
--- server refuses). A `name` that is empty, over 254 bytes or holds a
--- NUL or a "%", and a `servers` list or `hosts_file` the resolver
--- refuses, fail "Invalid argument". In a task of [`Poll.run`] the call
--- waits through the run, so only that task waits for the answer, and a
--- task cancelled in it ends the lookup and fails "cancelled"; anywhere
--- else it holds the thread until it answers. A `timeout_ns` out of range,
--- an empty `servers` list or a server port outside 1 to 65535 raises.
function Net.resolve(name: string, opts?: Net.ResolveOptions): {Net.Resolved}?, string -- checked: not_assigned
  opts = opts or {}
  Poll.checked_ns(opts.timeout_ns, "net", "timeout_ns", 2)
  local hosts_file = opts.hosts_file
  local servers: string?
  local opts_servers = opts.servers
  if opts_servers ~= nil then
    local listed = opts_servers
    if #listed == 0 then
      error("net: servers must be a list of endpoints", 2)
    end
    local parts: mut {string} = {}
    for _, endpoint in ipairs(listed) do
      local host, port = endpoint.host, endpoint.port
      if port < 1 or port > 65535 then
        error("net: a server must be an endpoint with a port from 1 to 65535", 2)
      end
      -- Only a host that holds none of the list's own punctuation may
      -- reach it, so one server cannot name another; the resolver
      -- refuses what is not an address.
      if host:find("[^%x:.]") then return nil, "Invalid argument" end
      parts[#parts + 1] = if host:find(":", 1, true) then ("[" .. host .. "]:" .. tostring(port)) else
        (host .. ":" .. tostring(port)) end
    end
    servers = table.concat(parts, ",")
  end
  if opts.connector ~= nil then return resolved_through(name, opts) end
  return Resolv.lookup(name, { timeout_ns = opts.timeout_ns, servers = servers, hosts = hosts_file })
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
function Net.nameservers(): {Net.Endpoint}?, string
  local listed, why = Resolv.nameservers()
  if listed == nil then return nil, why end
  local out: mut {Net.Endpoint} = {}
  for i, server in ipairs(listed) do out[i] = { host = server.host, port = server.port } end
  return out, ""
end

--- A socket connected to `address`, waiting at most `timeout_ns`: in a
--- task of [`Poll.run`], through the run; anywhere else, holding the
--- thread.
local function connection(address: Net.Address, timeout_ns: integer?): Attempt
  -- TODO: connect through raw.start, Poll.wait and raw.connected alone
  -- outside a task too, as the TODO in cosmic/internal/connector.tl's `waited` says: raw.connect, which
  -- waits in the core and ends at a caught signal, is what that
  -- replaces.
  Poll.checked_ns(timeout_ns, "net", "timeout_ns", 3)
  if not Poll.in_task() then
    local socket, trouble, errno = raw.connect(address, Poll.milliseconds(timeout_ns))
    return { socket = socket, trouble = trouble, errno = errno }
  end
  local socket, trouble, errno = raw.start(address)
  if socket == nil then return { trouble = trouble, errno = errno } end
  local holder: Connecting = { socket = socket } -- checked: literal_missing
  local held <close> = setmetatable(holder, connecting_mt) -- checked: setmetatable_call -- untyped: call
  local ready, why = Poll.writable(socket:fd(), timeout_ns)
  if not ready then return { trouble = why, errno = 0 } end
  local made, refused, number = raw.connected(socket:fd())
  if not made then return { trouble = refused, errno = number } end
  held.socket = nil
  return { socket = socket }
end

--- What [`Net.listen`] opens, with its descriptor; it raises at `level`
--- above its caller.
local function listening(address: Net.Address, opts: Net.ListenOptions,
                         level: integer): Opened?, string
  local unusable = address_trouble(address)
  if unusable ~= "" then error("net: address must be " .. unusable, level + 1) end
  local backlog = opts.backlog or DEFAULT_BACKLOG
  if backlog < 1 then error("net: backlog must be at least 1", level + 1) end
  Poll.checked_ns(opts.timeout_ns, "net", "timeout_ns", level + 1)
  local socket, trouble, errno = raw.listen(address, backlog)
  if socket == nil then return nil, named(address) .. ": " .. said(trouble, errno, address) end
  if address.kind ~= "tcp" then
    return new_listener(socket, Net.unix(assert(address.path)), opts.timeout_ns), ""
  end
  local bound, why = raw.bound(socket:fd())
  if bound == nil then
    local _, _ = socket:close()
    return nil, named(address) .. ": " .. why
  end
  return new_listener(socket, Net.tcp(assert(bound.host), assert(bound.port)), opts.timeout_ns), ""
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
function Net.listen(address: Net.Address, opts?: Net.ListenOptions): Net.Listener?, string
  local opened, why = listening(address, opts or {}, 2)
  if opened == nil then return nil, why end
  return opened.listener, ""
end

--- Binds a UDP socket at `address`, a [`Net.udp`] one: port 0 takes a
--- port the kernel chooses, which the socket's `address` then names, and
--- the host "0.0.0.0" or "::" takes datagrams at every address of the
--- machine. Nil and why where it cannot be bound: a port in use, or a
--- host that is no numeric address. With `shared`, a port in use by
--- sockets that are all `shared` is bound all the same
--- ([`DatagramOptions.shared`]). Raises on an address of another
--- kind or with a port past 65535, and on a `timeout_ns` no wait can last.
function Net.datagram(address: Net.Address, opts?: Net.DatagramOptions): Net.Datagram?, string
  local trouble = datagram_trouble(address)
  if trouble ~= "" then error("net: address must be " .. trouble, 2) end
  local timeout_ns = if opts ~= nil then opts.timeout_ns else nil end
  Poll.checked_ns(timeout_ns, "net", "timeout_ns", 2)
  local socket, why, errno = raw.datagram(address, opts ~= nil and opts.shared == true)
  if socket == nil then return nil, named(address) .. ": " .. said(why, errno, address) end
  local fd = socket:fd()
  local bound, bound_trouble = raw.bound(fd)
  if bound == nil then
    local _, _ = socket:close()
    return nil, named(address) .. ": " .. bound_trouble
  end
  local made: UdpSocket = { address = bound, socket = socket, fd = fd, open = true, limit = timeout_ns }
  return made, ""
end

--- The machine's network interfaces, each once with every IPv4 and IPv6
--- address it has, in the system's order: what a caller picks the `via`
--- of a multicast call from. An interface with no address is listed with
--- none. Nil and why where the system does not say. On Linux it is asked
--- over a netlink socket, which a sandbox ([`cosmic.sandbox`]) refuses, so
--- the call fails in one.
function Net.interfaces(): {Net.Interface}?, string
  -- TODO: list the interfaces in a Linux sandbox too, once its filter
  -- (core/promises.c) lets a process ask the kernel for them: today
  -- getifaddrs's netlink socket is refused there.
  local entries, why = raw.interfaces()
  if entries == nil then return nil, "net: interfaces: " .. why end
  local listed: mut {Net.Interface} = {}
  local by_name: mut {string: mut {Net.Resolved}} = {}
  for _, entry in ipairs(entries) do
    local known = by_name[entry.name]
    local addresses: mut {Net.Resolved} = known or {}
    if known == nil then
      by_name[entry.name] = addresses
      listed[#listed + 1] = {
        name = entry.name, index = entry.index, up = entry.up, loopback = entry.loopback,
        multicast = entry.multicast, addresses = addresses,
      }
    end
    local address, family = entry.address, entry.family
    if address ~= nil and family ~= nil then
      addresses[#addresses + 1] = { address = address, family = family }
    end
  end
  return listed, ""
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
function Net.listener_from(fd: integer, opts?: Net.ListenOptions): Net.Listener?, string
  if math.type(fd) ~= "integer" or fd < 0 then
    error("net: fd must be an integer from 0", 2)
  end
  Poll.checked_ns(if opts ~= nil then opts.timeout_ns else nil end, "net", "timeout_ns", 2)
  local socket, why, errno = raw.adopt(fd)
  if socket == nil then
    local reason = why
    if errno == raw.EINVAL then reason = "it is not listening" end
    return nil, "net: descriptor " .. tostring(fd) .. " is no listening TCP socket: " .. reason
  end
  local bound, trouble = raw.bound(socket:fd())
  if bound == nil then
    local _, _ = socket:close()
    return nil, "net: descriptor " .. tostring(fd) .. ": " .. trouble
  end
  return new_listener(socket, Net.tcp(assert(bound.host), assert(bound.port)),
    if opts ~= nil then opts.timeout_ns else nil end).listener, ""
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
-- Child.start binds the listeners itself (cosmic.child can require
-- cosmic.internal.socket now that the raw tables are plain modules): until
-- then the relay's process receives them itself, so that Child only moves
-- the channel.
--- @param channel integer The descriptor of the channel's receiving end
--- @param opts? Net.ListenOptions The listeners' options
--- @return {Net.Listener}|nil The listeners
--- @return string Why there are none, "" otherwise
function Net.receive_listeners(channel: integer, opts?: Net.ListenOptions): {Net.Listener}?, string
  if math.type(channel) ~= "integer" or channel < 0 then
    error("net: channel must be an integer from 0", 2)
  end
  Poll.checked_ns(if opts ~= nil then opts.timeout_ns else nil end, "net", "timeout_ns", 2)
  local received, why = raw.recvfds(channel, 2)
  if received == nil then return nil, "net: descriptor " .. tostring(channel) .. ": " .. why end
  local listeners: mut {Net.Listener} = {}
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
function Net.connect(address: Net.Address, opts?: Net.ConnectOptions): Net.Conn?, string
  local unusable = address_trouble(address)
  if unusable ~= "" then error("net: address must be " .. unusable, 2) end
  local timeout_ns = if opts ~= nil then opts.timeout_ns else nil end
  local attempt = connection(address, timeout_ns)
  local socket = attempt.socket
  if socket == nil then
    return nil, named(address) .. ": " .. said(assert(attempt.trouble), assert(attempt.errno), address)
  end
  return Connection.new(socket, timeout_ns), ""
end

resolved_through = function(name: string, opts: Net.ResolveOptions): {Net.Resolved}?, string
  local served = Leaf.served(opts.connector)
  if served == nil then
    error("net: connector must be one Net.connector made", 3)
  end
  if not served.open then return nil, "net: the connector is closed" end
  local listed: mut {Net.Endpoint} = {}
  local opts_servers = opts.servers
  if opts_servers ~= nil then
    for i, server in ipairs(opts_servers) do
      listed[i] = { host = server.host, port = server.port }
    end
  else
    local system, why = Resolv.nameservers()
    if system == nil then return nil, why end
    for i, server in ipairs(system) do listed[i] = { host = server.host, port = server.port } end
  end
  if #listed > Leaf.MAX_ENDPOINTS then
    return nil, string.format("net: a lookup through a connector takes name servers, at most %d, not %d",
      Leaf.MAX_ENDPOINTS, #listed)
  end
  local servers: mut {raw_socket.ThroughServer} = {}
  for _, server in ipairs(listed) do
    local index = Leaf.find(served, server.host, server.port)
    if index == nil then
      return nil, "net: the name server " .. named(Net.tcp(server.host, server.port)) ..
        " is not in the connector's table"
    end
    -- [`Leaf.find`] answered an index of `served.endpoints`.
    local endpoint = Array.at(served.endpoints, index)
    servers[#servers + 1] = { host = endpoint.host, port = server.port, index = index }
  end
  local found, trouble = Resolv.lookup(name, {
    timeout_ns = opts.timeout_ns,
    hosts = opts.hosts_file,
    through = servers,
    connect = function(index: integer, port: integer, deadline: integer?):
      Resolv.Connection?, string
      local socket, why = Leaf.through(served, index, port, deadline)
      if socket == nil then return nil, why end
      return { fd = socket:fd(), release = function() local _, _ = socket:close() end }, ""
    end,
  })
  if found == nil then
    -- A stream given up fails every connect after it: its words say why.
    return nil, Leaf.lost(served) or trouble
  end
  return found, ""
end

--- A copy of the public lists `public`.
local function checked_public(public: Net.PublicOptions): Leaf.Public
  local deny: mut {string} = {}
  local own: mut {string} = {}
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
--- Authority is explicit. `endpoints`, at most 128 [`Net.Endpoint`], is the
--- fixed set of addresses the process may reach, such as a relay whose
--- grants are numeric; it may be empty only with `opts.public`. With
--- neither endpoints nor `opts.public` the call raises, as it does for an
--- endpoint that is no numeric address or a table that is too long. One
--- process is started now and serves every request of the connector, many
--- at once. An endpoint at port 0 stands for every port,
--- and its slots take 1 MiB of the table if the address is IPv4 and 2 MiB
--- if IPv6: the port tables of all the endpoints are at most 32 MiB, so at
--- most 32 IPv4 or 16 IPv6 addresses at port 0 in a table of those alone.
--- Fixed-port endpoints (16 bytes if IPv4, 32 if IPv6, and each IPv6 range
--- starts at a 32-byte boundary) and a mix of the two change that count; a
--- table past the limit raises.
---
--- With `opts.public` the process also connects to any numeric address
--- the endpoints lack, which a [`Connector`]'s `connect` asks it for by address
--- and port: public-only with no endpoints, mixed with some. The process
--- judges the address itself, with the lists
--- `public` carries -- `deny`, the numeric "address/bits" prefixes it
--- refuses (at most 128; [`cosmic.relay.address`]'s `deny_cidrs` is the
--- relay's list), and `own`, the host's own addresses (at most 256) --
--- and refuses every IPv6 address outside 2000::/3 whatever the lists
--- say, so IPv4-mapped and NAT64 forms are never decoded. It is the
--- check that stands if the caller's own is wrong, and the caller keeps
--- its own as well. A refused address answers "net: ... is refused by the
--- connector's deny list".
function Net.connector(endpoints: {Net.Endpoint}, opts?: Net.ConnectorOptions): Net.Connector?, string
  local timeout_ms = Leaf.checked_timeout_ms(if opts ~= nil then opts.timeout_ns else nil end, 2)
  local public: Leaf.Public?
  local given_public = opts and opts.public
  if given_public ~= nil then public = checked_public(given_public) end
  if public == nil and #endpoints == 0 then
    error("net: a connector needs endpoints, opts.public, or both", 2)
  end
  local listed: mut {Leaf.Endpoint} = {}
  for i, endpoint in ipairs(endpoints) do
    listed[i] = { host = endpoint.host, port = endpoint.port }
  end
  return Leaf.connector(Leaf.checked_endpoints(listed, public ~= nil, 2), timeout_ms, public)
end

Leaf.register(address_trouble)

--- Raises for the spec's `field`, at the caller of [`Net.serve`].
local function spec_error(field: string, must: string): never
  error("net: spec." .. field .. " must be " .. must, 4)
end

--- Raises, naming the field, where `spec` holds a value the server cannot take.
local function checked_spec(spec: Net.ServeSpec)
  local listeners = spec.listeners
  if #listeners == 0 then
    spec_error("listeners", "a list of one address or more")
  end
  for i, address in ipairs(listeners) do
    local trouble = address_trouble(address)
    if trouble ~= "" then spec_error("listeners[" .. tostring(i) .. "]", trouble) end
  end
  local limits = spec.limits
  if limits ~= nil then
    local most = limits.connections
    if most ~= nil and most < 1 then
      spec_error("limits.connections", "nil or an integer from 1")
    end
  end
  Poll.checked_ns(spec.timeout_ns, "net", "spec.timeout_ns", 3)
  Poll.checked_ns(spec.grace_ns, "net", "spec.grace_ns", 3)
end

--- A listener a server accepts at, and the task accepting there while
--- there is one: none at the server's limit, or once it stops.
local record Accepting
  listener: Net.Listener
  fd: integer
  mut task?: Poll.Task
  --- The errno the last accept failed with, reported once until another
  --- answer comes; 0 after one that did not fail.
  mut failing: integer
end

--- A server's state for the length of its run. Closing it closes every
--- listener and connection, so a run that raises -- [`on_ready`] or
--- [`on_error`] did -- leaves no socket file behind, and no connection
--- to a task that never started open.
local record Serving
  spec: Net.ServeSpec
  --- The most connections open at once.
  most: integer
  mut open: integer
  mut stopping: boolean
  accepts: {Accepting}
  --- Each connection open, by the task serving it.
  conns: mut {Poll.Task: Net.Conn}
  --- Waits for `stop` to cancel it.
  waiter?: Poll.Task
  --- Holds SIGINT and SIGTERM for the run.
  guard?: Signal.Guard
  --- Waits on `guard`: its first signal stops the server, and the next
  --- ends the grace.
  watcher?: Poll.Task
  --- Waits for `waiter` to end, then runs [`on_stop`].
  stopper?: Poll.Task
  --- Waits out the grace while the server drains.
  mut grace?: Poll.Task
  --- Set once a signal has ended the grace.
  mut hurried: boolean
  --- Set once a signal `guard` caught has stopped the server: only
  --- then has the server acted on what the guard holds.
  mut signalled: boolean
  __close: function(Serving)
end

local serving_mt: metatable<Serving> = { -- checked: literal_missing
  __close = function(self: Serving)
    for _, accepting in ipairs(self.accepts) do local _, _ = accepting.listener:close() end
    for _, conn in pairs(self.conns) do local _, _ = conn:close() end
    local guard = self.guard
    -- Closed, so a signal caught is delivered as it would be without
    -- the server's guard: this runs as the run raises, or after
    -- `serving` has closed or released the guard itself, when closing
    -- again does nothing.
    if guard ~= nil then local _, _ = guard:close() end
  end,
}

--- How long a listener waits after an accept failed -- out of
--- descriptors, say -- before it tries again, so a failure that lasts is
--- not retried, and reported, without pause.
local ACCEPT_PAUSE_NS <const> = Clock.ms(100)

--- Gives `trouble` to the spec's [`Net.ServeSpec.on_error`], or stderr.
local function report(s: Serving, trouble: string)
  local on_error = s.spec.on_error
  if on_error ~= nil then
    on_error(trouble)
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
local function serve_conn(s: Serving, conn: Net.Conn) -- checked: not_assigned
  s.open = s.open + 1
  local task: Poll.Task?
  task = Poll.spawn(function()
    local held <close> = conn
    local ok, trouble: boolean, any = xpcall(s.spec.serve, traced, held) -- checked: any_use
    local _, _ = held:close()
    s.open = s.open - 1
    -- [`Poll.spawn`] runs this once serve_conn waits, after it set `task`.
    local mine = assert(task, "serve_conn: the task runs before Poll.spawn returned it")
    s.conns[mine] = nil
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
      serve_conn(s, Connection.new(socket, s.spec.timeout_ns))
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
  local stopper = s.stopper
  if stopper ~= nil then local _, _ = stopper:join() end
  if not s.hurried then
    local grace = s.spec.grace_ns
    local deadline = if grace ~= nil then Clock.monotonic_ns() + grace else nil end
    -- A task of its own, so a signal can end the grace by cancelling it.
    local grace_task = Poll.spawn(function()
      while true do
        local task = next(s.conns)
        if task == nil then return end
        local left: integer? = nil
        if deadline ~= nil then left = math.max(deadline - Clock.monotonic_ns(), 0) end
        local ended, _ = task:join(left)
        if not ended then return end
      end
    end)
    s.grace = grace_task
    local _, _ = grace_task:join()
  end
  local left: mut {Poll.Task} = {}
  for task in pairs(s.conns) do left[#left + 1] = task end
  for _, task in ipairs(left) do
    -- Closed before the kill, so a `<close>` handler that reads or
    -- writes it fails at once rather than wait; and done here, as a
    -- killed task is not resumed to do what serve_conn does after the
    -- protocol returns.
    -- `left` was listed from `s.conns` above; only a task's own exit or this loop removes its entry.
    local conn = assert(s.conns[task], "serve_conn: a listed task lost its connection")
    local _, _ = conn:close()
    local killed, trouble: boolean, any = pcall(task.kill, task) -- checked: interface_method_value
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
    local task = a.task
    if task ~= nil then task:cancel() end
  end
  assert(s.waiter):cancel()
end

--- Stops `s` at the first signal its guard takes, and ends its grace at
--- the next, until the task is cancelled.
local function watch(s: Serving)
  local guard = assert(s.guard)
  while true do
    local signal, _ = guard:wait()
    if signal == 0 then return end
    if not s.stopping then
      s.signalled = true
      stop(s)
    else
      s.hurried = true
      local stopper = s.stopper
      if stopper ~= nil then stopper:cancel() end
      local grace = s.grace
      if grace ~= nil then grace:cancel() end
    end
  end
end

--- The body of [`Net.serve`]'s run, over listeners of its own.
local function serving(spec: Net.ServeSpec): boolean, string
  local limits = spec.limits
  local state: Serving = { -- checked: literal_missing
    spec = spec, most = limits and limits.connections or math.maxinteger,
    open = 0, stopping = false, accepts = {}, conns = {}, hurried = false,
    signalled = false,
  }
  local s <close> = setmetatable(state, serving_mt) -- checked: setmetatable_call -- untyped: call
  local guard, guard_trouble = Signal.guard()
  if guard == nil then return false, "net: signal guard: " .. guard_trouble end
  s.guard = guard
  local addresses: mut {Net.Address} = {}
  for i, address in ipairs(spec.listeners) do
    local opened, trouble = listening(address, {}, 1)
    if opened == nil then return false, trouble end
    s.accepts[i] = { listener = opened.listener, fd = opened.fd, failing = 0 } -- checked: arms_differ
    addresses[i] = opened.listener.address
  end
  local server: Net.Server = {
    addresses = addresses,
    stop = function(_self: Net.Server) stop(s) end,
  }
  local waiter = Poll.spawn(function()
    while not s.stopping do local _, _ = Poll.delay(Poll.MOST_NS) end
  end)
  s.waiter = waiter
  local on_stop = spec.on_stop
  if on_stop ~= nil then
    -- Spawned here, not by `stop`, which may be called from a coroutine
    -- a task made, where Poll.spawn raises. A task of its own, so the
    -- watcher stays free to cancel a wait it makes at a second signal,
    -- and what it raises is not taken for the failure of a connection
    -- whose protocol called `stop`.
    s.stopper = Poll.spawn(function()
      local _, _ = waiter:join()
      local ok, trouble: boolean, any = xpcall(on_stop, traced, server) -- checked: any_use
      if not ok then report(s, tostring(trouble)) end
    end)
  end
  resume_accepting(s)
  local watcher = Poll.spawn(function() watch(s) end)
  s.watcher = watcher
  if spec.on_ready ~= nil then spec.on_ready(addresses, server) end
  local _, _ = waiter:join()
  drain(s)
  watcher:cancel()
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
--- a [`Signal.guard`] for its run, and the first signal of either kind
--- stops it. One more while it drains ends `grace_ns` at once, the
--- connections still open killed and closed. Where a signal stopped
--- it, the guard is released, not closed, so Net.serve returns true
--- without the signal delivered again; a caller that would know of it,
--- or die of it, holds a [`Signal.guard`] of its own around the call,
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
  local served = { ok = true, why = "" } -- checked: arms_differ
  Poll.run(function() served.ok, served.why = serving(spec) end)
  if not served.ok then return false, served.why end
  return true, ""
end

return Net
